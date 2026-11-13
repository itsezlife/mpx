import Foundation
import QuartzCore

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
  import CoreVideo
#endif

/// Calls [onTick] on the main thread once per display refresh while
/// running: the pulse on which a player checks its video output for a new
/// frame. The engine pulls a texture only after it is told a frame is
/// available, so something has to keep telling it.
///
/// iOS and macOS 14+ use a `CADisplayLink` (macOS: the main screen's);
/// earlier macOS a `CVDisplayLink`. A display link may stay silent (a macOS
/// app whose windows are not on screen, or one never brought to the front),
/// so a slow main-queue timer ticks too whenever the link has not for a
/// while: frames keep arriving and the first one is still reported, only not
/// in step with the display.
final class MpxDisplayLink {
  private let onTick: () -> Void
  // A CADisplayLink; typed loosely because macOS has it from 14 only.
  private var displayLink: AnyObject?
  private var timer: DispatchSourceTimer?
  // Held here as well: not every display link keeps its target.
  private lazy var proxy = Proxy(self)

  #if os(macOS)
    private var cvLink: CVDisplayLink?
    // Set while a tick is queued on the main thread, so a slow main thread
    // does not pile them up.
    private let pending = NSLock()
    private var queued = false
  #endif

  private(set) var running = false

  init(onTick: @escaping () -> Void) {
    self.onTick = onTick
  }

  deinit {
    stop()
  }

  func start() {
    if running { return }
    running = true
    startBackup()
    #if os(iOS)
      let link = CADisplayLink(target: proxy, selector: #selector(Proxy.tick))
      link.add(to: .main, forMode: .common)
      displayLink = link
      return
    #elseif os(macOS)
      if #available(macOS 14.0, *),
        let link = NSScreen.main?.displayLink(target: proxy, selector: #selector(Proxy.tick))
      {
        link.add(to: .main, forMode: .common)
        displayLink = link
        return
      }
      _ = startCVDisplayLink()
    #endif
  }

  func stop() {
    if !running { return }
    running = false
    #if os(iOS)
      (displayLink as? CADisplayLink)?.invalidate()
    #elseif os(macOS)
      if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.invalidate() }
    #endif
    displayLink = nil
    timer?.cancel()
    timer = nil
    #if os(macOS)
      // Stopping waits for a callback in flight, so none runs after this.
      if let cvLink { CVDisplayLinkStop(cvLink) }
    #endif
  }

  // Ticks [backupHz] times a second while the display link has been silent
  // for longer than [silence].
  private static let backupHz = 15
  private static let silence: CFTimeInterval = 0.1
  private var lastTick: CFTimeInterval = 0

  private func startBackup() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now(), repeating: .nanoseconds(1_000_000_000 / MpxDisplayLink.backupHz))
    timer.setEventHandler { [weak self] in
      guard let self, self.running,
        CACurrentMediaTime() - self.lastTick > MpxDisplayLink.silence
      else { return }
      self.onTick()
    }
    timer.resume()
    self.timer = timer
  }

  private func linkTicked() {
    guard running else { return }
    lastTick = CACurrentMediaTime()
    onTick()
  }

  #if os(macOS)
    // macOS 12 and 13: CVDisplayLink, whose callback runs on its own thread.
    private func startCVDisplayLink() -> Bool {
      if cvLink == nil {
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
          let created
        else { return false }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(
          created,
          { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            Unmanaged<MpxDisplayLink>.fromOpaque(context).takeUnretainedValue().fire()
            return kCVReturnSuccess
          }, opaque)
        cvLink = created
      }
      guard let cvLink else { return false }
      return CVDisplayLinkStart(cvLink) == kCVReturnSuccess
    }

    private func fire() {
      pending.lock()
      if queued {
        pending.unlock()
        return
      }
      queued = true
      pending.unlock()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pending.lock()
        self.queued = false
        self.pending.unlock()
        self.linkTicked()
      }
    }
  #endif

  // A display link retains its target; the proxy keeps the link from
  // keeping the player alive.
  private final class Proxy: NSObject {
    weak var owner: MpxDisplayLink?
    init(_ owner: MpxDisplayLink) { self.owner = owner }
    @objc func tick() { owner?.linkTicked() }
  }
}
