import Foundation
import os.signpost

/// Marks of a player's way to its first frame as signpost events under the
/// points of interest (Instruments shows them on its own lane), with the
/// stage names the Dart side uses: `<stage> p<id>`, an optional detail after
/// the id. Always on; an event costs next to nothing while nobody records.
enum MpxPlayerTrace {
  static let log = OSLog(subsystem: "dev.mpx.player", category: .pointsOfInterest)

  static func mark(_ stage: String, _ id: Int64, _ detail: String? = nil) {
    guard log.signpostsEnabled else { return }
    if let detail {
      os_signpost(.event, log: log, name: "mpx.player", "%{public}@ p%lld %{public}@", stage, id, detail)
    } else {
      os_signpost(.event, log: log, name: "mpx.player", "%{public}@ p%lld", stage, id)
    }
  }
}
