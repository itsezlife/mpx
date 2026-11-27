import Foundation
import os

/// Where the native envelope's events go: always to `os_log` (subsystem
/// `dev.mpx.transfer`, category `envelope`), and, while no Dart side is
/// attached to hear them, into a ring file in the app's container that the
/// next Dart side drains at attach.
///
/// Each record is one JSON line (`time` in ms since the epoch, `level`,
/// `op`, `fields`): numbers and short strings only, never user content.
/// The file never grows past `limit` bytes; its oldest lines go first.
final class MpxTransferEnvelopeLog {
  /// The largest the ring file grows by default: 2 MiB. The Dart side may
  /// set another at attach.
  static let defaultLimit = 2 * 1024 * 1024

  /// The largest the ring file grows.
  var limit: Int

  private let file: URL?
  private let log = OSLog(subsystem: "dev.mpx.transfer", category: "envelope")

  /// A log keeping its ring at `file`; the app's `mpx_transfer` folder in
  /// Application Support when nil.
  init(file: URL? = nil, limit: Int = MpxTransferEnvelopeLog.defaultLimit) {
    self.file = file ?? MpxTransferEnvelopeLog.defaultFile()
    self.limit = limit
  }

  /// Writes the event to `os_log`, and to the ring when `keep` is true.
  func record(
    _ op: String,
    level: String,
    fields: [String: Any] = [:],
    keep: Bool,
    now: Date = Date()
  ) {
    let line = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
    let type: OSLogType
    switch level {
    case "warning", "error": type = .error
    case "info": type = .info
    default: type = .debug
    }
    os_log("%{public}@ %{public}@", log: log, type: type, op, line)
    guard keep else { return }
    append([
      "time": Int64((now.timeIntervalSince1970 * 1000).rounded()),
      "level": level,
      "op": op,
      "fields": fields,
    ])
  }

  /// The records kept so far, oldest first, and an empty ring after.
  func drain() -> [[String: Any]] {
    guard let file = file, let data = try? Data(contentsOf: file) else { return [] }
    try? FileManager.default.removeItem(at: file)
    return MpxTransferEnvelopeLog.lines(of: data).compactMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
  }

  private func append(_ record: [String: Any]) {
    guard let file = file,
      JSONSerialization.isValidJSONObject(record),
      var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    else { return }
    line.append(0x0A)
    guard line.count <= limit else { return }
    let old = (try? Data(contentsOf: file)) ?? Data()
    var kept = MpxTransferEnvelopeLog.lines(of: old)
    var size = kept.reduce(0) { $0 + $1.count + 1 }
    // Rewritten whole: records are rare (only while no Dart side is
    // attached) and small, so a ring of offsets would buy nothing.
    while size + line.count > limit, !kept.isEmpty {
      size -= kept.removeFirst().count + 1
    }
    var data = Data(capacity: size + line.count)
    for kept in kept {
      data.append(kept)
      data.append(0x0A)
    }
    data.append(line)
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: file, options: .atomic)
    } catch {
      os_log("ring write failed", log: log, type: .error)
    }
  }

  private static func lines(of data: Data) -> [Data] {
    data.split(separator: 0x0A).map { Data($0) }
  }

  private static func defaultFile() -> URL? {
    guard
      var folder = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first?.appendingPathComponent("mpx_transfer", isDirectory: true)
    else { return nil }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? folder.setResourceValues(values)
    return folder.appendingPathComponent("envelope.ring")
  }
}
