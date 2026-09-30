import Foundation

enum Importer {
  static func rows(_ data: Data, dummy: Bool) throws -> [Object] {
    guard data.count <= 16 * 1024 * 1024 else { throw ProtocolError.limit }
    if dummy { _ = try DummyCSV.validate(data) }
    let rows = try DummyCSV.rows(data)
    guard let first = rows.first else { throw BridgeFailure.invalidCSV }
    let headers = first.map { $0.lowercased() }
    try Wire.require(
      Set(headers).count == headers.count
        && ["title", "url", "username", "password"].allSatisfy(headers.contains))
    return try rows.dropFirst().map { row in
      try Wire.require(row.count == headers.count)
      func field(_ key: String) -> String { headers.firstIndex(of: key).map { row[$0] } ?? "" }
      return [
        "id": UUID().uuidString.lowercased(), "title": field("title"),
        "username": field("username"), "password": field("password"),
        "urls": field("url").isEmpty ? [] : [field("url")], "notes": field("notes"),
        "state": "active",
      ]
    }
  }
  static func host(_ url: String) -> String {
    guard let u = URLComponents(string: url), u.scheme == "https", u.user == nil, u.password == nil,
      let host = u.host
    else { return "" }
    return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }
  static func reconcile(_ old: [Object], _ rows: [Object], complete: Bool) throws -> [Object] {
    func exact(_ r: Object) throws -> Data {
      try Wire.data(r.filter { !["id", "state"].contains($0.key) })
    }
    func identity(_ r: Object) throws -> Data {
      try Wire.data([
        "username": r["username"]!,
        "hosts": Array(Set((r["urls"] as! [String]).map(host))).sorted(),
      ])
    }
    var used = Set<String>()
    var output = [Object]()
    for var row in rows {
      let equal = try old.filter {
        guard !used.contains($0["id"] as! String) else { return false }
        return try exact($0) == exact(row)
      }
      if let match = equal.first {
        row["id"] = match["id"]
        used.insert(match["id"] as! String)
        output.append(row)
        continue
      }
      let candidates = try old.filter {
        guard !used.contains($0["id"] as! String) else { return false }
        return try identity($0) == identity(row)
      }
      let incoming = try rows.filter { try identity($0) == identity(row) }.count
      if candidates.count == 1 && incoming == 1 {
        row["id"] = candidates[0]["id"]
        used.insert(candidates[0]["id"] as! String)
        output.append(row)
      } else {
        row["state"] = !candidates.isEmpty || incoming > 1 ? "conflict" : "active"
        output.append(row)
        for var c in candidates {
          used.insert(c["id"] as! String)
          c["state"] = "conflict"
          output.append(c)
        }
      }
    }
    for var r in old where !used.contains(r["id"] as! String) {
      if complete { r["state"] = "missing" }
      output.append(r)
    }
    try Wire.require(output.count <= 10000)
    return output
  }
}
