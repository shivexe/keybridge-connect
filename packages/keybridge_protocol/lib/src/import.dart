import 'dart:convert';
import 'contract.dart';

List<List<String>> csvRows(List<int> data) {
  require(data.length <= 16 * 1024 * 1024, 'csv_limit');
  var s = utf8.decode(data, allowMalformed: false);
  if (s.startsWith('\ufeff')) s = s.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  bool quoted = false, ended = false;
  void endField() {
    row.add(field.toString());
    field = StringBuffer();
    ended = false;
  }

  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
          ended = true;
        }
      } else {
        field.write(c);
      }
    } else if (c == ',') {
      endField();
    } else if (c == '\r' || c == '\n') {
      endField();
      rows.add(row);
      row = [];
      if (c == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
    } else if (c == '"' && field.isEmpty && !ended) {
      quoted = true;
    } else {
      require(!ended && c != '"', 'invalid_csv');
      field.write(c);
    }
    require(field.length <= 65536 && rows.length <= 10001, 'csv_limit');
  }
  require(!quoted, 'incomplete_csv');
  if (field.isNotEmpty || row.isNotEmpty || ended) {
    endField();
    rows.add(row);
  }
  return rows;
}

String normalizedHost(String url) {
  try {
    final u = Uri.parse(url);
    if (u.scheme != 'https' || u.userInfo.isNotEmpty || u.host.isEmpty)
      return '';
    return u.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  } catch (_) {
    return '';
  }
}

List<Json> importCsv(List<int> data) {
  final rows = csvRows(data);
  require(rows.isNotEmpty, 'empty_csv');
  final headers = rows.first.map((s) => s.toLowerCase()).toList();
  require(headers.toSet().length == headers.length);
  for (final h in ['title', 'url', 'username', 'password']) {
    require(headers.contains(h), 'unsupported_csv_schema');
  }
  String get(List<String> row, String key) =>
      headers.contains(key) ? row[headers.indexOf(key)] : '';
  return rows.skip(1).map((r) {
    require(r.length == headers.length, 'invalid_csv_row');
    return <String, dynamic>{
      'id': newId(),
      'title': get(r, 'title'),
      'username': get(r, 'username'),
      'password': get(r, 'password'),
      'urls': get(r, 'url').isEmpty ? <String>[] : [get(r, 'url')],
      'notes': get(r, 'notes'),
      'state': 'active',
    };
  }).toList();
}

List<Json> reconcile(
  List<Json> old,
  List<Json> incoming, {
  required bool complete,
}) {
  String exact(Json r) => jsonEncode([
    r['title'],
    r['username'],
    r['password'],
    r['urls'],
    r['notes'],
  ]);
  String identity(Json r) {
    final urls =
        (r['urls'] as List).map((u) => normalizedHost(u)).toSet().toList()
          ..sort();
    return jsonEncode([r['username'], urls]);
  }

  final used = <String>{};
  final result = <Json>[];
  for (final row in incoming) {
    final exacts = old
        .where((r) => !used.contains(r['id']) && exact(r) == exact(row))
        .toList();
    if (exacts.isNotEmpty) {
      final r = exacts.first;
      used.add(r['id']);
      result.add({...row, 'id': r['id'], 'state': 'active'});
      continue;
    }
    final candidates = old
        .where((r) => !used.contains(r['id']) && identity(r) == identity(row))
        .toList();
    final duplicates = incoming
        .where((r) => identity(r) == identity(row))
        .length;
    if (candidates.length == 1 && duplicates == 1) {
      used.add(candidates.single['id']);
      result.add({...row, 'id': candidates.single['id'], 'state': 'active'});
    } else {
      result.add({
        ...row,
        'state': candidates.isNotEmpty || duplicates > 1
            ? 'conflict'
            : 'active',
      });
      for (final r in candidates) {
        used.add(r['id']);
        result.add({...r, 'state': 'conflict'});
      }
    }
  }
  for (final r in old) {
    if (!used.contains(r['id']))
      result.add({...r, 'state': complete ? 'missing' : r['state']});
  }
  require(result.length <= 10000, 'record_limit');
  return result;
}

List<Json> syntheticRecords([int count = 12]) => List.generate(
  count,
  (i) => {
    'id': newId(),
    'title': 'Fixture ${i + 1}',
    'username': 'dummy$i',
    'password': 'KB_SYNTHETIC_CANARY_${i}_only!',
    'urls': ['https://login$i.example.test'],
    'notes': 'Synthetic fixture, never a real credential.',
    'state': 'active',
  },
);
