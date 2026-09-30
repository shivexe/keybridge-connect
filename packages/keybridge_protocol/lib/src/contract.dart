import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef Json = Map<String, dynamic>;
const maxSnapshot = 8 * 1024 * 1024;
const maxWire = 32 * 1024 * 1024;
const maxRequest = 256 * 1024;
const maxInteger = 9007199254740991;

enum SyncPhase {
  locked,
  ready,
  awaitingAuthentication,
  exporting,
  importing,
  cleaningUp,
  pendingDelivery,
  delivering,
  awaitingReceipt,
  synced,
  cancelled,
  cleanupBlocked,
  integrityFailure,
}

final _random = Random.secure();
List<int> randomBytes(int n) => List.generate(n, (_) => _random.nextInt(256));
String newId() {
  final b = randomBytes(16);
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
void require(bool condition, [String code = 'invalid_data']) {
  if (!condition) throw FormatException(code);
}

bool validId(dynamic s) =>
    s is String &&
    RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$').hasMatch(s);
bool integer(dynamic n, [int minimum = 0]) =>
    n is int && n >= minimum && n <= maxInteger;
List<int> binary(dynamic value, [int? length]) {
  require(value is String && value.length <= maxWire);
  final bytes = base64Decode(value as String);
  require(
    base64Encode(bytes) == value && (length == null || bytes.length == length),
  );
  return bytes;
}

List<int> encode(Json value) => utf8.encode(jsonEncode(value));
Json parse(List<int> bytes, [int limit = maxWire]) {
  require(bytes.length <= limit, 'limit_exceeded');
  final source = utf8.decode(bytes, allowMalformed: false);
  _JsonCheck(source).check();
  final result = jsonDecode(source);
  require(result is Json);
  return result as Json;
}

class _JsonCheck {
  _JsonCheck(this.s);
  final String s;
  int i = 0;
  void space() {
    while (i < s.length && ' \r\n\t'.contains(s[i])) {
      i++;
    }
  }

  void check() {
    value(0);
    space();
    require(i == s.length);
  }

  String string() {
    final start = i++;
    bool end = false;
    while (i < s.length) {
      final c = s[i++];
      if (c == '\\') {
        require(i < s.length);
        i++;
      } else if (c == '"') {
        end = true;
        break;
      }
    }
    require(end);
    final v = jsonDecode(s.substring(start, i)) as String;
    for (var j = 0; j < v.length; j++) {
      final c = v.codeUnitAt(j);
      if (c >= 0xd800 && c <= 0xdbff) {
        require(
          ++j < v.length &&
              v.codeUnitAt(j) >= 0xdc00 &&
              v.codeUnitAt(j) <= 0xdfff,
        );
      } else {
        require(c < 0xdc00 || c > 0xdfff);
      }
    }
    return v;
  }

  void value(int depth) {
    require(depth <= 24);
    space();
    require(i < s.length);
    if (s[i] == '"') {
      string();
      return;
    }
    if (s[i] == '{' || s[i] == '[') {
      final object = s[i++] == '{';
      final close = object ? '}' : ']';
      final keys = <String>{};
      space();
      if (i < s.length && s[i] == close) {
        i++;
        return;
      }
      while (true) {
        space();
        require(i < s.length);
        if (object) {
          require(s[i] == '"');
          require(keys.add(string()), 'duplicate_key');
          space();
          require(i < s.length && s[i++] == ':');
        }
        value(depth + 1);
        space();
        require(i < s.length);
        final c = s[i++];
        if (c == close) {
          return;
        }
        require(c == ',');
      }
    }
    final start = i;
    while (i < s.length && !' ,]}\r\n\t'.contains(s[i])) {
      i++;
    }
    final token = s.substring(start, i);
    require(
      token == 'true' ||
          token == 'false' ||
          token == 'null' ||
          (RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(token) &&
              integer(int.tryParse(token))),
    );
  }
}

bool privateAddress(InternetAddress a, {bool test = false}) {
  final b = a.rawAddress;
  if (a.isLoopback) return test;
  if (a.type == InternetAddressType.IPv4)
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  return (b[0] & 254) == 252;
}

Uri endpoint(String value, {bool test = false}) {
  final u = Uri.parse(value);
  final a = InternetAddress.tryParse(u.host);
  require(
    u.scheme == 'https' &&
        a != null &&
        privateAddress(a, test: test) &&
        u.userInfo.isEmpty &&
        !u.hasQuery &&
        !u.hasFragment &&
        (u.path.isEmpty || u.path == '/') &&
        u.port > 0 &&
        u.port <= 65535,
    'private_endpoint_required',
  );
  return u.replace(path: '');
}

Json invitation(String value, {bool test = false}) {
  final q = parse(utf8.encode(value), 16384);
  require(
    q['version'] == 1 &&
        validId(q['vaultId']) &&
        validId(q['pairId']) &&
        integer(q['expiresAt']) &&
        q['expiresAt'] > now() &&
        q['expiresAt'] <= now() + 330,
  );
  require(q['desktopName'] is String && q['desktopName'].length <= 80);
  endpoint(q['url'] as String, test: test);
  binary(q['secret'], 32);
  binary(q['publicKey'], 32);
  binary(q['certificateSha256'], 32);
  return q;
}

void validateSnapshot(Json s) {
  require(
    s['version'] == 1 &&
        validId(s['vaultId']) &&
        integer(s['generation'], 1) &&
        integer(s['createdAt']) &&
        ['linux', 'macos'].contains(s['source']),
  );
  final records = s['records'];
  require(records is List && records.length <= 10000);
  final ids = <String>{};
  for (final r in records) {
    require(
      r is Json &&
          validId(r['id']) &&
          ids.add(r['id']) &&
          encode(r).length <= 65536,
    );
    for (final k in ['title', 'username', 'password', 'notes']) {
      require(r[k] is String);
    }
    require(['active', 'missing', 'conflict'].contains(r['state']));
    require(
      r['urls'] is List &&
          r['urls'].length <= 100 &&
          r['urls'].every((u) => u is String && u.length <= 8192),
    );
  }
  require(encode(s).length <= maxSnapshot, 'limit_exceeded');
}
