import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:cryptography/cryptography.dart';
import 'package:basic_utils/basic_utils.dart';
import 'contract.dart';
import 'crypto.dart';
import 'import.dart';
import 'listener.dart';

final _libc = DynamicLibrary.open('libc.so.6');
final _chmod = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');
final _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');
final _fsync = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'fsync',
);
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _flock = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'flock',
    );
void privatePath(String p, int mode) {
  final ptr = p.toNativeUtf8();
  try {
    require(_chmod(ptr, mode) == 0, 'permissions_failed');
  } finally {
    calloc.free(ptr);
  }
}

void syncDirectory(String p) {
  final ptr = p.toNativeUtf8();
  final fd = _open(ptr, 0x10000);
  calloc.free(ptr);
  require(fd >= 0, 'directory_open_failed');
  try {
    require(_fsync(fd) == 0, 'durability_failed');
  } finally {
    _close(fd);
  }
}

Json clone(Json value) => parse(encode(value));

class DesktopVault {
  DesktopVault(this.directory);
  final Directory directory;
  SecretKey? _key;
  List<int>? _salt;
  int? _lock;
  Json? state;
  File get file => File('${directory.path}/state.kbv');
  bool get unlocked => state != null;
  Future<void> unlock(String passphrase) async {
    require(passphrase.length >= 12, 'passphrase_too_short');
    await directory.create(recursive: true);
    require(
      await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.directory,
      'unsafe_path',
    );
    privatePath(directory.path, 448);
    if (_lock == null) {
      final lockFile = File('${directory.path}/instance.lock');
      final lockType = await FileSystemEntity.type(
        lockFile.path,
        followLinks: false,
      );
      require(
        lockType == FileSystemEntityType.notFound ||
            lockType == FileSystemEntityType.file,
        'unsafe_lock',
      );
      await lockFile.open(mode: FileMode.append).then((f) => f.close());
      privatePath(lockFile.path, 384);
      final ptr = lockFile.path.toNativeUtf8();
      final fd = _open(ptr, 0x20000 | 2);
      calloc.free(ptr);
      if (fd < 0 || _flock(fd, 6) != 0) {
        if (fd >= 0) _close(fd);
        throw StateError('another_instance');
      }
      _lock = fd;
    }
    Json? container;
    if (await file.exists()) {
      require(
        await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file,
        'unsafe_archive',
      );
      require(await file.length() <= 64 * 1024 * 1024);
      container = parse(await file.readAsBytes(), 64 * 1024 * 1024);
      require(container['version'] == 1 && container['iterations'] == 600000);
      _salt = binary(container['salt'], 16);
    } else {
      _salt = randomBytes(16);
    }
    _key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 600000,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: _salt!);
    try {
      if (container != null) {
        state = await unseal(container, await _key!.extractBytes(), _context());
      } else {
        final pair = CryptoUtils.generateEcKeyPair();
        final privateKey = pair.privateKey as ECPrivateKey;
        final publicKey = pair.publicKey as ECPublicKey;
        final csr = X509Utils.generateEccCsrPem(
          {'CN': 'Keybridge Connect'},
          privateKey,
          publicKey,
        );
        state = {
          'version': 1,
          'vaultId': newId(),
          'seed': base64Encode(randomBytes(32)),
          'certificate': X509Utils.generateSelfSignedCertificate(
            privateKey,
            csr,
            3650,
          ),
          'privateKey': CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
          'records': <Json>[],
          'generation': 0,
          'deliveries': <Json>[],
          'receipts': <Json>[],
        };
        await commit(state!);
      }
    } catch (_) {
      lock();
      rethrow;
    }
  }

  String _context() => 'keybridge/v1/local/600000/${base64Encode(_salt!)}';
  Future<void> commit(Json next) async {
    require(_key != null, 'locked');
    final encrypted = await seal(next, await _key!.extractBytes(), _context());
    final temp = File('${directory.path}/.${newId()}.tmp');
    try {
      await temp.writeAsBytes(
        encode({
          'version': 1,
          'iterations': 600000,
          'salt': base64Encode(_salt!),
          ...encrypted,
        }),
        flush: true,
      );
      privatePath(temp.path, 384);
      await temp.rename(file.path);
      syncDirectory(directory.path);
      state = clone(next);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  void lock() {
    state = null;
    _key = null;
    _salt = null;
    if (_lock != null) {
      _close(_lock!);
      _lock = null;
    }
  }
}

class Desktop {
  Desktop(this.vault, {this.test = false});
  final DesktopVault vault;
  final bool test;
  HttpServer? server;
  BoundedTlsListener? listener;
  Json? invite;
  Json? request;
  Json? approved;
  String? boundRequest;
  bool rejected = false;
  String? comparisonCode;
  String status = 'ready';
  String? url;
  void Function()? onChanged;
  Future<void> _tail = Future.value();
  int _connections = 0;
  final Map<String, List<int>> _rates = {};
  Future<T> serialized<T>(Future<T> Function() work) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await work());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Json get state => vault.state ?? (throw StateError('locked'));
  void changed() {
    onChanged?.call();
  }

  Future<void> start(String ip, {int port = 0}) async {
    require(
      privateAddress(InternetAddress(ip), test: test),
      'private_interface_required',
    );
    final context = SecurityContext()
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
      ..useCertificateChainBytes(utf8.encode(state['certificate']))
      ..usePrivateKeyBytes(utf8.encode(state['privateKey']));
    listener = BoundedTlsListener(
      await ServerSocket.bind(ip, port, backlog: 16),
      context,
    );
    server = HttpServer.listenOn(listener!);
    server!.idleTimeout = const Duration(seconds: 10);
    url = Uri(scheme: 'https', host: ip, port: server!.port).toString();
    server!.listen(
      _handle,
      onError: (_) {
        status = 'transport_error';
        changed();
      },
    );
    changed();
  }

  Future<Json> createInvite() => serialized(() async {
    require(server != null);
    if (state['staged'] != null && state['staged']['expiresAt'] <= now()) {
      final next = clone(state)..remove('staged');
      await vault.commit(next);
    }
    require(state['staged'] == null, 'replacement_pending');
    final public = await (await signingKey(
      binary(state['seed'], 32),
    )).extractPublicKey();
    final cert = base64Decode(
      (state['certificate'] as String)
          .replaceAll(RegExp(r'-----[^-]+-----|\s'), '')
          .trim(),
    );
    invite = {
      'version': 1,
      'url': url,
      'vaultId': state['vaultId'],
      'pairId': newId(),
      'secret': base64Encode(randomBytes(32)),
      'publicKey': base64Encode(public.bytes),
      'certificateSha256': await digest(cert),
      'expiresAt': now() + 300,
      'desktopName': 'Keybridge Linux',
    };
    request = null;
    approved = null;
    boundRequest = null;
    rejected = false;
    comparisonCode = null;
    changed();
    return invite!;
  });
  Future<void> approve(bool allow) => serialized(() async {
    require(invite != null && request != null && invite!['expiresAt'] > now());
    if (!allow) {
      rejected = true;
      changed();
      return;
    }
    if (approved != null) return;
    final next = clone(state);
    final paired = {
      'deviceId': request!['deviceId'],
      'deviceName': request!['deviceName'],
      'syncKey': base64Encode(randomBytes(32)),
      'expiresAt': now() + 600,
    };
    next['staged'] = paired;
    await vault.commit(next);
    approved = await seal(
      {
        'version': 1,
        'vaultId': state['vaultId'],
        'deviceId': paired['deviceId'],
        'syncKey': paired['syncKey'],
        'desktopName': invite!['desktopName'],
      },
      binary(invite!['secret'], 32),
      aad('pair-response', state['vaultId'], invite!['pairId']),
    );
    changed();
  });
  Future<void> publish(
    List<Json> rows, {
    bool complete = false,
    bool replace = false,
  }) => serialized(() async {
    status = 'importing';
    changed();
    final next = clone(state);
    final records = replace
        ? rows
        : reconcile(
            (next['records'] as List).cast<Json>(),
            rows,
            complete: complete,
          );
    final previous = jsonEncode(next['records']);
    if (previous == jsonEncode(records) && next['generation'] > 0) {
      status = _delivered(next) ? 'synced' : 'pending_delivery';
      changed();
      return;
    }
    next['records'] = records;
    next['generation'] = (next['generation'] as int) + 1;
    final body = {
      'version': 1,
      'vaultId': next['vaultId'],
      'generation': next['generation'],
      'createdAt': now(),
      'source': 'linux',
      'records': records,
    };
    validateSnapshot(body);
    next['body'] = base64Encode(encode(body));
    next['digest'] = await digest(encode(body));
    await vault.commit(next);
    status = 'pending_delivery';
    changed();
  });
  bool _delivered(Json s) => (s['receipts'] as List).any(
    (r) =>
        r['deviceId'] == s['active']?['deviceId'] &&
        r['generation'] == s['generation'] &&
        r['snapshotSha256'] == s['digest'],
  );
  Future<void> cancelStaged() => serialized(() async {
    final next = clone(state);
    final staged = next.remove('staged');
    if (staged == null) return;
    next['deliveries'] = (next['deliveries'] as List)
        .where((d) => d['deviceId'] != staged['deviceId'])
        .toList();
    await vault.commit(next);
    invite = null;
    request = null;
    approved = null;
    comparisonCode = null;
    changed();
  });
  Future<void> revoke() => serialized(() async {
    final next = clone(state)
      ..remove('active')
      ..remove('staged');
    next['deliveries'] = <Json>[];
    next['receipts'] = <Json>[];
    await vault.commit(next);
    invite = null;
    request = null;
    approved = null;
    status = 'pending_delivery';
    changed();
  });
  Future<void> stop() async {
    await listener?.close();
    await server?.close(force: true);
    listener = null;
    server = null;
    invite = null;
    request = null;
    approved = null;
    boundRequest = null;
    await _tail;
    url = null;
    changed();
  }

  bool rate(String key, int cap) {
    final t = now();
    final entries = _rates.putIfAbsent(key, () => []);
    entries.removeWhere((n) => n < t - 60);
    if (entries.length >= cap) return false;
    entries.add(t);
    return true;
  }

  Future<void> _handle(HttpRequest r) async {
    if (++_connections > 16) {
      _connections--;
      r.response.statusCode = 429;
      await r.response.close();
      return;
    }
    try {
      require(
        r.method == 'POST' &&
            r.uri.query.isEmpty &&
            r.uri.fragment.isEmpty &&
            r.contentLength >= 0 &&
            r.contentLength <= maxRequest,
      );
      var headerSize = 0;
      r.headers.forEach((k, v) {
        headerSize += k.length + v.join().length;
      });
      require(headerSize <= 16384);
      final data = <int>[];
      await for (final chunk in r.timeout(const Duration(seconds: 10))) {
        require(data.length + chunk.length <= maxRequest);
        data.addAll(chunk);
      }
      final result = await serialized(
        () => route(r.uri.path, parse(data, maxRequest), base64Encode(data)),
      );
      r.response.statusCode = result.$1;
      r.response.headers.contentType = ContentType.json;
      r.response.persistentConnection = false;
      r.response.add(encode(result.$2));
      await r.response.close().timeout(const Duration(seconds: 10));
    } catch (_) {
      try {
        r.response.statusCode = 400;
        r.response.write('{"error":"request_rejected"}');
        await r.response.close();
      } catch (_) {}
    } finally {
      _connections--;
    }
  }

  Future<(int, Json)> route(String path, Json envelope, String exact) async {
    if (path.startsWith('/v1/pair/')) {
      if (!rate('pair', 30)) return (429, {'error': 'rate_limited'});
      final q = invite;
      if (q == null ||
          q['expiresAt'] <= now() ||
          path != '/v1/pair/${q['pairId']}')
        return (410, {'error': 'expired'});
      if (rejected) return (403, {'error': 'rejected'});
      final p = await unseal(
        envelope,
        binary(q['secret'], 32),
        aad('pair-request', q['vaultId'], q['pairId']),
      );
      require(
        p['version'] == 1 &&
            p['vaultId'] == q['vaultId'] &&
            validId(p['deviceId']) &&
            p['deviceName'] is String &&
            p['deviceName'].length <= 80,
      );
      binary(p['clientNonce'], 32);
      if (boundRequest != null && boundRequest != exact)
        return (403, {'error': 'bound'});
      boundRequest = exact;
      request = p;
      comparisonCode = await comparison(
        binary(q['secret'], 32),
        binary(p['clientNonce'], 32),
      );
      changed();
      return approved == null ? (202, {'status': 'pending'}) : (200, approved!);
    }
    require(path == '/v1/sync' || path == '/v1/ack');
    final id = envelope['deviceId'];
    require(validId(id));
    final next = clone(state);
    Json? device;
    if (next['active']?['deviceId'] == id) device = next['active'];
    if (next['staged']?['deviceId'] == id &&
        next['staged']['expiresAt'] > now())
      device = next['staged'];
    if (device == null) return (403, {'error': 'revoked'});
    if (!rate(id, 60)) return (429, {'error': 'rate_limited'});
    final type = path.endsWith('sync') ? 'sync' : 'ack';
    final root = binary(device['syncKey'], 32);
    final c2s = await derive(root, state['vaultId'], id, 'c2s');
    final s2c = await derive(root, state['vaultId'], id, 's2c');
    final p = await unseal(
      envelope,
      c2s,
      aad('$type-request', state['vaultId'], id),
    );
    require(
      p['version'] == 1 &&
          p['vaultId'] == state['vaultId'] &&
          p['deviceId'] == id,
    );
    binary(p['requestId'], 32);
    Json response;
    if (type == 'sync') {
      require(integer(p['lastGeneration']));
      if (p['lastGeneration'] > 0) binary(p['lastDigest'], 32);
      if (next['generation'] == 0) return (409, {'error': 'no_snapshot'});
      require(
        p['lastGeneration'] <= next['generation'] &&
            (p['lastGeneration'] != next['generation'] ||
                p['lastDigest'] == next['digest']),
        'integrity_failure',
      );
      final deliveries = (next['deliveries'] as List);
      deliveries.removeWhere((d) => d['expiresAt'] <= now());
      deliveries.removeWhere(
        (d) => d['deviceId'] == id && d['requestId'] == p['requestId'],
      );
      while (deliveries.where((d) => d['deviceId'] == id).length >= 32) {
        deliveries.removeAt(deliveries.indexWhere((d) => d['deviceId'] == id));
      }
      deliveries.add({
        'deviceId': id,
        'requestId': p['requestId'],
        'generation': next['generation'],
        'snapshotSha256': next['digest'],
        'expiresAt': now() + 86400,
      });
      await vault.commit(next);
      response = p['lastGeneration'] == next['generation']
          ? {
              'version': 1,
              'status': 'unchanged',
              'requestId': p['requestId'],
              'generation': next['generation'],
              'snapshotSha256': next['digest'],
            }
          : await signSnapshot(
              next['body'],
              p['requestId'],
              binary(next['seed'], 32),
            );
      status = 'awaiting_receipt';
    } else {
      require(p['status'] == 'committed' && integer(p['generation'], 1));
      binary(p['snapshotSha256'], 32);
      bool matches(dynamic d) =>
          d['deviceId'] == id &&
          d['requestId'] == p['requestId'] &&
          d['generation'] == p['generation'] &&
          d['snapshotSha256'] == p['snapshotSha256'];
      require(
        (next['deliveries'] as List).any(
              (d) => matches(d) && d['expiresAt'] > now(),
            ) ||
            (next['receipts'] as List).any(matches),
        'receipt_not_issued',
      );
      if (next['staged']?['deviceId'] == id) {
        next['active'] = next.remove('staged');
        next['active'].remove('expiresAt');
        next['deliveries'] = (next['deliveries'] as List)
            .where((d) => d['deviceId'] == id)
            .toList();
      }
      final receipts = next['receipts'] as List;
      receipts.removeWhere((d) => d['deviceId'] == id);
      receipts.add({...p, 'confirmedAt': now()});
      await vault.commit(next);
      response = {
        'version': 1,
        'vaultId': next['vaultId'],
        'deviceId': id,
        'requestId': p['requestId'],
        'generation': p['generation'],
        'snapshotSha256': p['snapshotSha256'],
        'status': 'recorded',
      };
      status = _delivered(next) ? 'synced' : 'pending_delivery';
    }
    changed();
    return (
      200,
      await seal(response, s2c, aad('$type-response', state['vaultId'], id)),
    );
  }
}
