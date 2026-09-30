import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'contract.dart';

Future<List<int>> hash(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes;
Future<String> digest(List<int> bytes) async => base64Encode(await hash(bytes));
String aad(String type, String vault, String id) =>
    'keybridge/v1/$type/$vault/$id';
Future<List<int>> derive(
  List<int> root,
  String vault,
  String device,
  String direction,
) async => (await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
  secretKey: SecretKey(root),
  nonce: utf8.encode('keybridge/v1/$vault/$device'),
  info: utf8.encode('keybridge/v1/$direction'),
)).extractBytes();
Future<Json> seal(
  Json plain,
  List<int> key,
  String context, {
  List<int>? nonce,
}) async {
  final box = await AesGcm.with256bits().encrypt(
    encode(plain),
    secretKey: SecretKey(key),
    nonce: nonce ?? randomBytes(12),
    aad: utf8.encode(context),
  );
  return {
    'nonce': base64Encode(box.nonce),
    'ciphertext': base64Encode(box.cipherText),
    'tag': base64Encode(box.mac.bytes),
  };
}

Future<Json> unseal(Json box, List<int> key, String context) async => parse(
  await AesGcm.with256bits().decrypt(
    SecretBox(
      binary(box['ciphertext']),
      nonce: binary(box['nonce'], 12),
      mac: Mac(binary(box['tag'], 16)),
    ),
    secretKey: SecretKey(key),
    aad: utf8.encode(context),
  ),
);
Future<String> comparison(List<int> secret, List<int> nonce) async {
  final h = await hash([...secret, ...nonce]);
  return (((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) % 1000000)
      .toString()
      .padLeft(6, '0');
}

Future<SimpleKeyPair> signingKey(List<int> seed) =>
    Ed25519().newKeyPairFromSeed(seed);
Future<Json> signSnapshot(String body, String requestId, List<int> seed) async {
  final payload = base64Encode(
    encode({
      'requestId': requestId,
      'snapshotBodyBase64': body,
      'snapshotSha256': await digest(binary(body)),
    }),
  );
  final signature = await Ed25519().sign(
    utf8.encode('keybridge.snapshot.v1\n$payload'),
    keyPair: await signingKey(seed),
  );
  return {'payload': payload, 'signature': base64Encode(signature.bytes)};
}

Future<Json> verifySnapshot(
  Json signed,
  Json pairing,
  String request,
  int generation,
  String? previousDigest,
) async {
  final payload = signed['payload'];
  binary(payload);
  require(
    await Ed25519().verify(
      utf8.encode('keybridge.snapshot.v1\n$payload'),
      signature: Signature(
        binary(signed['signature'], 64),
        publicKey: SimplePublicKey(
          binary(pairing['publicKey'], 32),
          type: KeyPairType.ed25519,
        ),
      ),
    ),
    'signature_failure',
  );
  final p = parse(binary(payload));
  require(p['requestId'] == request, 'request_mismatch');
  final bytes = binary(p['snapshotBodyBase64']);
  final s = parse(bytes, maxSnapshot);
  validateSnapshot(s);
  require(
    s['vaultId'] == pairing['vaultId'] &&
        p['snapshotSha256'] == await digest(bytes),
  );
  require(
    s['generation'] >= generation &&
        (s['generation'] != generation ||
            p['snapshotSha256'] == previousDigest),
    'integrity_failure',
  );
  return {'snapshot': s, 'digest': p['snapshotSha256']};
}
