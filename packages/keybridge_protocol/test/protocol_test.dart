import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:keybridge_protocol/keybridge_protocol.dart';

void main() {
  test(
    'strict serialization rejects duplicate keys, invalid Unicode and integers',
    () {
      for (final s in [
        '{"a":1,"a":2}',
        '{"a":"\\ud800"}',
        '{"a":1.0}',
        '{"a":-1}',
        '{"a":9007199254740992}',
        '{"a":true,}',
      ]) {
        expect(() => parse(utf8.encode(s)), throwsA(anything));
      }
      expect(parse(utf8.encode('{"a":"a\\uD83D\\uDE00"}'))['a'], 'a😀');
    },
  );
  test('endpoint excludes public, wildcard, link-local and decorated URLs', () {
    for (final s in [
      'https://8.8.8.8:443',
      'https://0.0.0.0:44',
      'https://169.254.1.1:4',
      'https://127.0.0.1:3',
      'https://10.0.0.1:3/a',
      'https://user@10.0.0.1:3',
      'https://10.0.0.1:3?q=1',
      'http://10.0.0.1:3',
    ]) {
      expect(() => endpoint(s), throwsA(anything));
    }
    expect(endpoint('https://100.64.0.1:4000').host, '100.64.0.1');
  });
  test('CSV preserves credential bytes and rejects incomplete quotes', () {
    final rows = importCsv(
      utf8.encode(
        '\ufeffPassword,Username,URL,Title,Notes\r\n" a,""b""\r\nc ", u ,https://a.example.test,T,n\r\n',
      ),
    );
    expect(rows.single['password'], ' a,"b"\r\nc ');
    expect(rows.single['username'], ' u ');
    expect(
      () => importCsv(utf8.encode('Title,URL,Username,Password\nT,u,a,"bad')),
      throwsA(anything),
    );
  });
  test(
    'reconciliation preserves IDs, retains missing and separates ambiguous accounts',
    () {
      final old = syntheticRecords(2);
      final changed = {...old[0], 'id': newId(), 'password': 'new'};
      final r = reconcile(old, [changed], complete: true);
      expect(r[0]['id'], old[0]['id']);
      expect(r[1]['state'], 'missing');
      final dup = {...old[0], 'id': newId(), 'password': 'other'};
      final conflict = reconcile([old[0], dup], [changed], complete: false);
      expect(conflict.length, 3);
      expect(conflict.every((r) => r['state'] == 'conflict'), isTrue);
    },
  );
  test('AEAD rejects cross-direction, wrong tag and domain', () async {
    final key = randomBytes(32);
    final c = await derive(key, 'vault', 'device', 'c2s'),
        s = await derive(key, 'vault', 'device', 's2c');
    expect(c, s.isNotEmpty ? isNot(equals(s)) : anything);
    final box = await seal({'version': 1}, c, 'context');
    expect(await unseal(box, c, 'context'), {'version': 1});
    await expectLater(unseal(box, s, 'context'), throwsA(anything));
    await expectLater(unseal(box, c, 'wrong'), throwsA(anything));
  });
  test('real TLS pairing, staging, commit receipts and restart', () async {
    final dir = await Directory.systemTemp.createTemp('kb-test-');
    final vault = DesktopVault(dir);
    await vault.unlock('synthetic-test-only-passphrase');
    final desktop = Desktop(vault, test: true);
    await desktop.publish(syntheticRecords(2));
    await desktop.start('127.0.0.1');
    final q = await desktop.createInvite(), device = newId();
    final request = await seal(
      {
        'version': 1,
        'vaultId': q['vaultId'],
        'deviceId': device,
        'deviceName': 'Synthetic test',
        'clientNonce': base64Encode(randomBytes(32)),
      },
      binary(q['secret'], 32),
      aad('pair-request', q['vaultId'], q['pairId']),
    );
    Future<(int, Json)> post(String path, Json body, {String? pin}) =>
        pinnedPost(
          Uri.parse(q['url']),
          path,
          body,
          pin ?? q['certificateSha256'],
          test: true,
        );
    expect((await post('/v1/pair/${q['pairId']}', request)).$1, 202);
    await desktop.approve(true);
    final p = await unseal(
      (await post('/v1/pair/${q['pairId']}', request)).$2,
      binary(q['secret'], 32),
      aad('pair-response', q['vaultId'], q['pairId']),
    );
    p['publicKey'] = q['publicKey'];
    expect(vault.state!['active'], isNull);
    expect(vault.state!['staged']['deviceId'], device);
    final c = await derive(
          binary(p['syncKey'], 32),
          q['vaultId'],
          device,
          'c2s',
        ),
        s = await derive(binary(p['syncKey'], 32), q['vaultId'], device, 's2c');
    Future<(int, Json)> send(String kind, Json payload) async =>
        post('/v1/$kind', {
          ...await seal(payload, c, aad('$kind-request', q['vaultId'], device)),
          'deviceId': device,
        });
    final rid = base64Encode(randomBytes(32));
    final plain = {
      'version': 1,
      'vaultId': q['vaultId'],
      'deviceId': device,
      'requestId': rid,
      'lastGeneration': 0,
      'lastDigest': '',
    };
    final response = await send('sync', plain);
    expect(response.$1, 200);
    final signed = await unseal(
      response.$2,
      s,
      aad('sync-response', q['vaultId'], device),
    );
    final verified = await verifySnapshot(signed, p, rid, 0, null);
    expect(verified['snapshot']['records'].length, 2);
    await expectLater(
      verifySnapshot(signed, p, base64Encode(randomBytes(32)), 0, null),
      throwsA(anything),
    );
    await expectLater(
      verifySnapshot(signed, p, rid, 2, null),
      throwsA(anything),
    );
    await expectLater(
      verifySnapshot(signed, p, rid, 1, base64Encode(randomBytes(32))),
      throwsA(anything),
    );
    final ack = {
      'version': 1,
      'vaultId': q['vaultId'],
      'deviceId': device,
      'requestId': rid,
      'generation': 1,
      'snapshotSha256': verified['digest'],
      'status': 'committed',
    };
    expect(
      (await send('ack', {
        ...ack,
        'requestId': base64Encode(randomBytes(32)),
      })).$1,
      400,
    );
    expect(desktop.status, 'awaiting_receipt');
    expect((await send('ack', ack)).$1, 200);
    expect(desktop.status, 'synced');
    expect(vault.state!['active']['deviceId'], device);
    expect((await send('ack', ack)).$1, 200);
    await expectLater(
      post('/v1/sync', {}, pin: base64Encode(randomBytes(32))),
      throwsA(anything),
    );
    await desktop.publish([
      {...syntheticRecords(1).first, 'username': 'changed'},
    ]);
    expect((await send('ack', ack)).$1, 200);
    expect(desktop.status, 'pending_delivery');
    await desktop.stop();
    vault.lock();
    await vault.unlock('synthetic-test-only-passphrase');
    expect(vault.state!['active']['deviceId'], device);
    expect(vault.state!['receipts'].length, 1);
    final bytes = await vault.file.readAsBytes();
    expect(utf8.decode(bytes).contains('KB_SYNTHETIC_CANARY'), isFalse);
    await desktop.revoke();
    expect(vault.state!['active'], isNull);
    vault.lock();
    await expectLater(
      vault.unlock('wrong-synthetic-passphrase'),
      throwsA(anything),
    );
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
