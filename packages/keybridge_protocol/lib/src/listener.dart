import 'dart:async';
import 'dart:io';

class BoundedTlsListener extends Stream<Socket> implements ServerSocket {
  BoundedTlsListener(this.raw, this.context) {
    raw.listen(accept, onError: output.addError, onDone: output.close);
  }
  final ServerSocket raw;
  final SecurityContext context;
  final output = StreamController<Socket>();
  final sockets = <Socket>{};
  bool closed = false;
  void accept(Socket socket) async {
    if (closed || sockets.length >= 16) {
      socket.destroy();
      return;
    }
    sockets.add(socket);
    Socket current = socket;
    final deadline = Timer(const Duration(seconds: 20), () {
      current.destroy();
      sockets.remove(current);
    });
    try {
      final secure = await SecureSocket.secureServer(
        socket,
        context,
      ).timeout(const Duration(seconds: 10));
      current = secure;
      sockets.remove(socket);
      sockets.add(secure);
      if (closed) {
        secure.destroy();
        return;
      }
      secure.done.then(
        (_) {
          deadline.cancel();
          sockets.remove(current);
        },
        onError: (_) {
          deadline.cancel();
          sockets.remove(current);
        },
      );
      output.add(secure);
    } catch (_) {
      deadline.cancel();
      sockets.remove(current);
      socket.destroy();
    }
  }

  @override
  InternetAddress get address => raw.address;
  @override
  int get port => raw.port;
  @override
  Future<ServerSocket> close() async {
    closed = true;
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    sockets.clear();
    await raw.close();
    return this;
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => output.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
