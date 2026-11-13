import AVFoundation
import AVKit
import Foundation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// Picture in picture for one player at a time, through a hidden
/// `AVPlayerLayer` on the same AVPlayer: the system window needs a layer,
/// and the texture keeps drawing from the video output meanwhile.
///
/// The layer joins the key window's layer tree (picture in picture is only
/// possible for a layer in one), one point large and transparent, and
/// leaves it when the window closes.
final class MpxPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
  private let report: (Int64, Bool) -> Void
  private var playerId: Int64?
  private var layer: AVPlayerLayer?
  private var controller: AVPictureInPictureController?
  private var possible: NSKeyValueObservation?

  init(report: @escaping (Int64, Bool) -> Void) {
    self.report = report
  }

  static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

  /// Whether a window is up or starting.
  var isActive: Bool { playerId != nil }

  func start(_ player: MpxPlayer) {
    guard MpxPictureInPicture.isSupported else { return }
    if playerId == player.id { return }
    stop()
    guard let host = MpxPictureInPicture.hostLayer() else { return }
    let layer = AVPlayerLayer(player: player.player)
    layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    layer.opacity = 0
    host.addSublayer(layer)
    guard let controller = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      return
    }
    controller.delegate = self
    playerId = player.id
    self.layer = layer
    self.controller = controller
    // The controller becomes able to start a moment after it gets a layer
    // that shows a ready item.
    possible = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
      controller, _ in
      guard controller.isPictureInPicturePossible else { return }
      DispatchQueue.main.async {
        if !controller.isPictureInPictureActive { controller.startPictureInPicture() }
      }
    }
  }

  func stop() {
    if let controller, controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    } else {
      finish()
    }
  }

  /// The player goes: its window closes.
  func playerDisposed(_ id: Int64) {
    if playerId == id { stop() }
  }

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    if let playerId { report(playerId, true) }
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    finish()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    finish()
  }

  private func finish() {
    possible?.invalidate()
    possible = nil
    layer?.removeFromSuperlayer()
    layer = nil
    controller = nil
    if let id = playerId {
      playerId = nil
      report(id, false)
    }
  }

  private static func hostLayer() -> CALayer? {
    #if os(iOS)
      let windows = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
      return (windows.first(where: \.isKeyWindow) ?? windows.first)?.layer
    #elseif os(macOS)
      let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
      guard let view = window?.contentView else { return nil }
      view.wantsLayer = true
      return view.layer
    #endif
  }
}
