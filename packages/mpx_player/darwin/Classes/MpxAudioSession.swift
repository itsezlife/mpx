import AVFoundation
import Foundation

/// The app's audio session as the player pool's sound owner uses it (iOS).
///
/// A request sets the `.playback` category (sound with the silent switch on,
/// and in the background where the host declares the audio background mode)
/// and activates the session; an abandon deactivates it so other apps'
/// audio comes back. While held, interruptions (calls, alarms, Siri) and
/// route changes (headphones out) are reported. macOS has no audio session:
/// requests do nothing and nothing is reported.
final class MpxAudioSession {
  private let report: (NativeAudioFocusChange) -> Void
  private var held = false
  private var observers: [NSObjectProtocol] = []

  init(report: @escaping (NativeAudioFocusChange) -> Void) {
    self.report = report
    #if os(iOS)
      let center = NotificationCenter.default
      observers = [
        center.addObserver(
          forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.interrupted(note) },
        center.addObserver(
          forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in self?.routeChanged(note) },
      ]
    #endif
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  func request() {
    held = true
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
      } catch {
        // Another app holds a session that cannot be interrupted (a call):
        // the owner pauses for good, as when focus is lost.
        report(.lost)
      }
    #endif
  }

  func abandon() {
    guard held else { return }
    held = false
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    #endif
  }

  #if os(iOS)
    private func interrupted(_ note: Notification) {
      guard held,
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      switch type {
      case .began:
        report(.interrupted)
      case .ended:
        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(
          AVAudioSession.InterruptionOptions.init(rawValue:))
        // Without "should resume" the system means the sound is not
        // coming back on its own: the owner stays paused.
        report(options?.contains(.shouldResume) == true ? .gained : .lost)
      @unknown default:
        break
      }
    }

    private func routeChanged(_ note: Notification) {
      guard held,
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
      else { return }
      report(.outputRemoved)
    }
  #endif
}
