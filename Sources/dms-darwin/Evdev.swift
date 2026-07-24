import CoreGraphics
import Foundation

// Native evdev channel: the macOS stand-in for the upstream Go daemon's
// `evdev.*`, which reads the Caps Lock LED off a Linux /dev/input device. DMS
// only consumes `capsLock` from it (DMSService.qml:368 -> capsLockState),
// driving the bar Caps-Lock indicator, the CapsLockOSD, and the lock screen's
// caps warning. macOS exposes the modifier state via
// CGEventSource.flagsState's alpha-shift bit - no /dev/input, no TCC prompt.
//
// Wire shapes mirror core/internal/server/evdev/models.go: State{available,
// capsLock}; method evdev.getState; the `evdev` event carries the same on
// every toggle.
final class EvdevChannel {
  var onStateChanged: (([String: Any]) -> Void)?

  private var pollTimer: DispatchSourceTimer?
  private var lastCapsLock: Bool?

  private static func capsLockOn() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
  }

  func state() -> [String: Any] {
    ["available": true, "capsLock": Self.capsLockOn()]
  }

  func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
    switch method {
    case "evdev.getState":
      return (self.state(), nil)
    default:
      return (nil, "unknown method: \(method)")
    }
  }

  func start() {
    // Caps Lock has no change notification without an Accessibility-gated
    // global monitor, so poll the modifier flags. 250ms is well under
    // human toggle perception and costs a single cheap read.
    self.lastCapsLock = Self.capsLockOn()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let caps = Self.capsLockOn()
      guard caps != self.lastCapsLock else { return }
      self.lastCapsLock = caps
      self.onStateChanged?(["available": true, "capsLock": caps])
    }
    timer.resume()
    self.pollTimer = timer
  }
}
