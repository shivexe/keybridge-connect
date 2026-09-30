import Foundation
import NIO
import NIOHTTP1
import NIOSSL

final class TLSServer {
  typealias Route = (String, Data) async -> (Int, Object)
  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let context: NIOSSLContext
  private let route: Route
  private var listener: Channel?
  private let lock = NSLock()
  private var children: [ObjectIdentifier: Channel] = [:]
  init(certificate: Data, privateKey: String, route: @escaping Route) throws {
    let cert = try NIOSSLCertificate(bytes: Array(certificate), format: .der)
    let key = try NIOSSLPrivateKey(bytes: Array(privateKey.utf8), format: .pem)
    var config = TLSConfiguration.makeServerConfiguration(
      certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
    config.minimumTLSVersion = .tlsv12
    context = try NIOSSLContext(configuration: config)
    self.route = route
  }
  func start(ip: String, port: Int) async throws {
    let bootstrap = ServerBootstrap(group: group).serverChannelOption(
      ChannelOptions.backlog, value: 16
    ).childChannelInitializer { channel in
      self.lock.lock()
      let allowed = self.children.count < 16
      if allowed { self.children[ObjectIdentifier(channel)] = channel }
      self.lock.unlock()
      guard allowed else { return channel.close() }
      channel.closeFuture.whenComplete { _ in
        self.lock.lock()
        self.children.removeValue(forKey: ObjectIdentifier(channel))
        self.lock.unlock()
      }
      do {
        let handler = NIOSSLServerHandler(context: self.context)
        return channel.pipeline.addHandler(handler).flatMap {
          channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
        }.flatMap { channel.pipeline.addHandler(RequestHandler(route: self.route)) }
      }
    }
    listener = try await bootstrap.bind(host: ip, port: port).get()
  }
  func stop() async {
    try? await listener?.close().get()
    listener = nil
    lock.lock()
    let open = Array(children.values)
    lock.unlock()
    for channel in open { try? await channel.close().get() }
    try? await group.shutdownGracefully()
  }
}
final class RequestHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let route: TLSServer.Route
  var head: HTTPRequestHead?
  var bytes = Data()
  var deadline: Scheduled<Void>?
  var completed = false
  init(route: @escaping TLSServer.Route) { self.route = route }
  func handlerAdded(context: ChannelHandlerContext) {
    deadline = context.eventLoop.scheduleTask(in: .seconds(15)) { context.close(promise: nil) }
  }
  func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !completed else {
      context.close(promise: nil)
      return
    }
    switch unwrapInboundIn(data) {
    case .head(let h):
      let lengths = h.headers["content-length"]
      guard head == nil, h.method == .POST, h.uri.hasPrefix("/v1/"), !h.uri.contains("?"),
        !h.uri.contains("#"),
        h.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16384,
        lengths.count == 1, let count = Int(lengths[0]), count >= 0, count <= 256 * 1024,
        !h.headers.contains(name: "transfer-encoding")
      else {
        context.close(promise: nil)
        return
      }
      head = h
    case .body(var body):
      guard bytes.count + body.readableBytes <= 256 * 1024,
        let data = body.readBytes(length: body.readableBytes)
      else {
        context.close(promise: nil)
        return
      }
      bytes.append(contentsOf: data)
    case .end:
      guard let head, Int(head.headers.first(name: "content-length") ?? "") == bytes.count else {
        context.close(promise: nil)
        return
      }
      completed = true
      let input = bytes
      Task {
        let result = await route(head.uri, input)
        context.eventLoop.execute {
          do {
            let response = try Wire.data(result.1)
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: String(response.count))
            headers.add(name: "connection", value: "close")
            context.write(
              self.wrapOutboundOut(
                .head(
                  HTTPResponseHead(
                    version: .http1_1, status: HTTPResponseStatus(statusCode: result.0),
                    headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
              context.close(promise: nil)
            }
          } catch { context.close(promise: nil) }
        }
      }
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
