import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:pointycastle/export.dart' show SHA256Digest;
import 'dart:typed_data';
import 'contract.dart';
import 'crypto.dart';

Future<(int, Json)> pinnedPost(
  Uri origin,
  String path,
  Json body,
  String pin, {
  bool test = false,
}) async {
  endpoint(origin.toString(), test: test);
  require(path.startsWith('/v1/'));
  binary(pin, 32);
  final context = SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
  SecureSocket? socket;
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false;
  try {
    socket = await SecureSocket.connect(
      origin.host,
      origin.port,
      context: context,
      onBadCertificate: (cert) =>
          base64Encode(SHA256Digest().process(Uint8List.fromList(cert.der))) ==
          pin,
      timeout: const Duration(seconds: 10),
    );
    require(
      socket.peerCertificate != null &&
          await digest(socket.peerCertificate!.der) == pin,
      'certificate_mismatch',
    );
    final connected = socket;
    client.connectionFactory = (_, _, _) async => ConnectionTask.fromSocket(
      Future.value(connected),
      () => connected.destroy(),
    );
    final req = await client
        .postUrl(
          Uri(scheme: 'http', host: origin.host, port: origin.port, path: path),
        )
        .timeout(const Duration(seconds: 10));
    req.followRedirects = false;
    req.persistentConnection = false;
    req.headers.contentType = ContentType.json;
    final bytes = encode(body);
    require(bytes.length <= maxRequest);
    req.contentLength = bytes.length;
    req.add(bytes);
    final response = await req.close().timeout(const Duration(seconds: 15));
    require(response.contentLength <= maxWire);
    final output = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      require(output.length + chunk.length <= maxWire);
      output.addAll(chunk);
    }
    return (response.statusCode, parse(output));
  } finally {
    client.close(force: true);
    socket?.destroy();
  }
}
