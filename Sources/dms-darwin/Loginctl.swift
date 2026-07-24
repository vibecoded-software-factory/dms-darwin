import AppKit
import Foundation
import IOKit.pwr_mgt

// Native loginctl channel: the macOS stand-in for the upstream Go daemon's
// `loginctl.*`, which speaks systemd-logind over D-Bus and never runs on
// macOS. DMS's SessionService uses it for lock-before-suspend and
// resume-after-sleep recovery, driven by the `preparingForSleep` field of the
// loginctl state (SessionService.updateLoginctlState); NSWorkspace's
// will-sleep/did-wake notifications are the macOS equivalent. Lock state comes
// from the screen-lock distributed notifications.
//
// State shape mirrors core/internal/server/loginctl/types.go so DMS binds
// unchanged: {sessionId, sessionPath, locked, active, idleHint, lockedHint,
// preparingForSleep, sessionType, userName, seat, display}.
final class LoginctlChannel {
  var onStateChanged: (([String: Any]) -> Void)?

  private var preparingForSleep = false
  private var locked = false
  private var lockedHint = false
  private var sleepAssertion: IOPMAssertionID = IOPMAssertionID(0)

  func start() {
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setSleeping(true) }
    ws.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setSleeping(false) }
    ws.addObserver(
      forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setSleeping(true) }
    ws.addObserver(
      forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.setSleeping(false) }

    // Screen lock/unlock: the classic distributed notifications, still
    // delivered on macOS (not part of the public API, but stable).
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(
      forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in self?.setLocked(true) }
    dnc.addObserver(
      forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { [weak self] _ in self?.setLocked(false) }
  }

  private func setSleeping(_ value: Bool) {
    guard self.preparingForSleep != value else { return }
    self.preparingForSleep = value
    self.onStateChanged?(self.state())
  }

  private func setLocked(_ value: Bool) {
    guard self.locked != value else { return }
    self.locked = value
    self.onStateChanged?(self.state())
  }

  func state() -> [String: Any] {
    [
      "sessionId": ProcessInfo.processInfo.environment["XDG_SESSION_ID"] ?? "macos",
      "sessionPath": "",
      "locked": self.locked,
      "active": true,
      "idleHint": false,
      "idleSinceHint": 0,
      "lockedHint": self.lockedHint,
      "preparingForSleep": self.preparingForSleep,
      "sessionType": "macos",
      "sessionClass": "user",
      "userName": NSUserName(),
      "seat": "seat0",
      "display": "",
    ]
  }

  func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
    switch method {
    case "loginctl.getState":
      return (self.state(), nil)
    case "loginctl.lock":
      // The shell already locks natively via customPowerActionLock; this
      // is the daemon-driven path (lock-before-suspend).
      return NativeLock.lock()
        ? (["success": true, "message": "locked"], nil) : (nil, "lock failed")
    case "loginctl.unlock":
      // macOS unlock is owned by the login window (authentication);
      // a third-party process cannot dismiss it.
      return (["success": true, "message": "unlock is owned by macOS"], nil)
    case "loginctl.setLockedHint":
      self.lockedHint = params["locked"] as? Bool ?? false
      self.onStateChanged?(self.state())
      return (["success": true, "message": "locked hint set"], nil)
    case "loginctl.setSleepInhibitorEnabled":
      let enabled = params["enabled"] as? Bool ?? false
      self.setSleepInhibitor(enabled)
      return (["success": true, "message": enabled ? "sleep inhibited" : "sleep allowed"], nil)
    default:
      return (nil, "unknown method: \(method)")
    }
  }

  // A held PreventSystemSleep assertion is the macOS analog of logind's sleep
  // inhibitor lock.
  private func setSleepInhibitor(_ enabled: Bool) {
    if enabled {
      guard self.sleepAssertion == IOPMAssertionID(0) else { return }
      var id = IOPMAssertionID(0)
      if IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        "DMS sleep inhibitor" as CFString, &id) == kIOReturnSuccess
      {
        self.sleepAssertion = id
      }
    } else if self.sleepAssertion != IOPMAssertionID(0) {
      IOPMAssertionRelease(self.sleepAssertion)
      self.sleepAssertion = IOPMAssertionID(0)
    }
  }
}
