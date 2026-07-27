import Foundation
import IOKit.pwr_mgt
import OpenDirectory

// The `freedesktop.*` channel: the shell's accounts/portal protocol, shapes
// mirrored from the upstream Go daemon's freedesktop service. On macOS the
// accounts backend is OpenDirectory - the user's avatar lives in the local
// directory node as JPEGPhoto, readable without privileges - and the
// settings portal's color scheme is the system appearance: reads map
// AppleInterfaceStyle to the portal values (1 = prefer-dark, 2 =
// prefer-light) and the AppleInterfaceThemeChanged distributed notification
// becomes a state broadcast, so the shell follows macOS light/dark switches
// the way it follows the portal on Linux. (Writes go the other way: the
// shell execs `gsettings`, provided on macOS by the install glue's shim.)
//
// The screensaver reports unavailable: idle inhibition already goes through
// the wayland IdleInhibitor path.
final class FreedesktopChannel: NSObject {
    private let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/dms-darwin", isDirectory: true)

    // The server hooks this to push fresh state when the system appearance
    // changes behind our back (the OS auto-switch, System Settings).
    var onStateChanged: (() -> Void)?
    /// Raised when the set of display-idle inhibitors changes.
    ///
    /// Its own callback because the shell subscribes to
    /// `freedesktop.screensaver` as a separate service from `freedesktop`, and
    /// reads `inhibited` / `inhibitors` off it.
    var onScreensaverChanged: (([String: Any]) -> Void)?
    /// Cookies of the inhibitors last reported, for change detection.
    private var lastInhibitorCookies: Set<Int> = []

    /// Re-read the assertions and push them if the holders changed.
    ///
    /// Polled rather than observed: IOKit publishes no notification for the
    /// assertion table, and the holders change at human speed. Shares the
    /// server's existing 2s tick, so it costs one extra IOKit call.
    func pollScreensaver() {
        let state = self.screensaverState()
        let cookies = Set(
            (state["inhibitors"] as? [[String: Any]] ?? []).compactMap { $0["cookie"] as? Int })
        guard cookies != self.lastInhibitorCookies else { return }
        self.lastInhibitorCookies = cookies
        self.onScreensaverChanged?(state)
    }

    var available: Bool { true }

    override init() {
        super.init()
        // deliverImmediately matters: an idle agent gets App Napped, and
        // with the default suspension behavior the theme-change notification
        // is silently dropped while napping - the sync then only works when
        // the daemon happens to be warm (fresh install, recent requests).
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(self.appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func appearanceChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.noteAppearance() }
    }

    // Belt and braces: the server's poll timer also calls this, so even if
    // the OS withholds the notification the change lands within a tick.
    private var lastScheme: Int?

    func pollAppearance() {
        self.noteAppearance()
    }

    private func noteAppearance() {
        let scheme = self.colorScheme()
        guard scheme != self.lastScheme else { return }
        self.lastScheme = scheme
        self.onStateChanged?()
    }

    // Portal color-scheme values: 1 = prefer-dark, 2 = prefer-light. The
    // synchronize matters: a long-running daemon's preferences cache goes
    // stale, and this read happens right after the change notification.
    private func colorScheme() -> Int {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style =
            CFPreferencesCopyAppValue(
                "AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return style == "Dark" ? 1 : 2
    }

    // ---- OpenDirectory access ----

    private func userRecord(_ username: String) throws -> ODRecord {
        let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
        return try node.record(
            withRecordType: kODRecordTypeUsers, name: username,
            attributes: [
                kODAttributeTypeJPEGPhoto, kODAttributeTypePicture, kODAttributeTypeFullName,
            ])
    }

    private func attribute(_ record: ODRecord, _ name: String) -> Any? {
        (try? record.values(forAttribute: name))?.first
    }

    // The avatar: prefer the JPEGPhoto blob (what System Settings sets),
    // materialized into the cache so the shell gets a plain file path; fall
    // back to the legacy Picture path attribute.
    private func iconFile(for username: String) -> String {
        guard let record = try? self.userRecord(username) else { return "" }

        if let photo = self.attribute(record, kODAttributeTypeJPEGPhoto) as? Data, !photo.isEmpty {
            let cached = self.cacheDir.appendingPathComponent("avatar-\(username).jpg")
            try? FileManager.default.createDirectory(
                at: self.cacheDir, withIntermediateDirectories: true)
            if (try? photo.write(to: cached)) != nil {
                return cached.path
            }
        }
        if let picture = self.attribute(record, kODAttributeTypePicture) as? String,
            FileManager.default.fileExists(atPath: picture)
        {
            return picture
        }
        return ""
    }

    // ---- state ----

    func state() -> [String: Any] {
        let username = NSUserName()
        let passwd = getpwnam(username)
        return [
            "accounts": [
                "available": true,
                "userPath": "/Local/Default/Users/\(username)",
                "iconFile": self.iconFile(for: username),
                "realName": NSFullUserName(),
                "userName": username,
                "accountType": 0,
                "homeDirectory": FileManager.default.homeDirectoryForCurrentUser.path,
                "shell": passwd.map { String(cString: $0.pointee.pw_shell) } ?? "",
                "email": "",
                "language": Locale.preferredLanguages.first ?? "",
                "location": "",
                "locked": false,
                "passwordMode": 0,
                "uid": UInt64(getuid()),
            ],
            "settings": ["available": true, "colorScheme": self.colorScheme()],
            "screensaver": self.screensaverState(),
        ]
    }

    // ---- screensaver ----

    /// Who is currently holding the display awake, in the shell's shape.
    ///
    /// Upstream is the freedesktop screensaver interface: apps call Inhibit
    /// over D-Bus and the daemon lists the holders. The macOS equivalent is a
    /// power assertion, and `IOPMCopyAssertionsByProcess` is public IOKit -
    /// which is also what `pmset -g assertions` prints. So the inhibitor list
    /// is real here, not empty: a video player, `caffeinate`, and bento's own
    /// IdleInhibitor all show up, because all three take the same assertion.
    ///
    /// Only display-idle assertions count. A process may hold
    /// PreventSystemSleep while the display is free to sleep, and reporting
    /// that as a screensaver inhibitor would light the shell's indicator for
    /// every background download.
    ///
    /// Fields mirror the Go daemon's ScreensaverInhibitor (freedesktop/
    /// types.go:38): cookie, appName, reason, peer, startTime. `peer` is the
    /// pid, which is the closest thing to a D-Bus peer name here.
    func screensaverState() -> [String: Any] {
        var inhibitors: [[String: Any]] = []
        var byProcess: Unmanaged<CFDictionary>?
        if IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
            let table = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        {
            for (pid, assertions) in table {
                for assertion in assertions {
                    guard let type = assertion["AssertionTrueType"] as? String
                            ?? assertion["AssertType"] as? String,
                        Self.displayIdleAssertions.contains(type)
                    else { continue }
                    inhibitors.append([
                        "cookie": assertion["AssertionId"] as? Int ?? 0,
                        "appName": assertion["Process Name"] as? String ?? "pid \(pid.intValue)",
                        "reason": assertion["AssertName"] as? String ?? type,
                        "peer": String(pid.intValue),
                        "startTime": Int(
                            (assertion["AssertStartWhen"] as? Date ?? Date()).timeIntervalSince1970),
                    ])
                }
            }
        }
        return [
            "available": true,
            // The screen being locked is loginctl's business, not this one's;
            // upstream reports `active` for a running screensaver and macOS
            // exposes no public read for that.
            "active": false,
            "inhibited": !inhibitors.isEmpty,
            "inhibitors": inhibitors,
        ]
    }

    /// Assertion types that hold the DISPLAY awake, and so suppress a
    /// screensaver. `NoDisplaySleepAssertion` is the long-standing name and
    /// `PreventUserIdleDisplaySleep` its modern spelling; both appear in the
    /// live table depending on which API the holder used.
    private static let displayIdleAssertions: Set<String> = [
        "NoDisplaySleepAssertion",
        "PreventUserIdleDisplaySleep",
    ]

    // ---- methods ----

    private func setAttribute(_ name: String, to value: Any) -> String? {
        do {
            let record = try self.userRecord(NSUserName())
            try record.setValue(value, forAttribute: name)
            return nil
        } catch {
            // Expected on stock macOS: writing the directory record needs
            // admin rights the agent does not hold. The wording matters -
            // the shell pattern-matches "permission" for its toast.
            return "permission denied by directory services: \(error.localizedDescription)"
        }
    }

    // Returns the response payload, nil for "unknown method", or a thrown
    // error string via the `errorOut` shape below. Mutations answer
    // {success, message} like upstream's SuccessResult.
    func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
        switch method {
        case "freedesktop.getState":
            return (self.state(), nil)
        case "freedesktop.accounts.getUserIconFile":
            guard let username = params["username"] as? String else {
                return (nil, "missing param: username")
            }
            return (["success": true, "value": self.iconFile(for: username)], nil)
        case "freedesktop.accounts.setIconFile":
            guard let path = params["path"] as? String else {
                return (nil, "missing param: path")
            }
            guard path.isEmpty || FileManager.default.fileExists(atPath: path) else {
                return (nil, "icon file does not exist: \(path)")
            }
            let data = path.isEmpty ? Data() : ((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
            if let failure = self.setAttribute(kODAttributeTypeJPEGPhoto, to: data) {
                return (nil, failure)
            }
            return (["success": true, "message": "icon file set"], nil)
        case "freedesktop.accounts.setRealName":
            guard let name = params["name"] as? String else {
                return (nil, "missing param: name")
            }
            if let failure = self.setAttribute(kODAttributeTypeFullName, to: name) {
                return (nil, failure)
            }
            return (["success": true, "message": "real name set"], nil)
        case "freedesktop.accounts.setEmail", "freedesktop.accounts.setLanguage",
            "freedesktop.accounts.setLocation":
            return (nil, "not supported on darwin")
        case "freedesktop.settings.getColorScheme":
            return (["colorScheme": self.colorScheme()], nil)
        case "freedesktop.settings.setIconTheme":
            return (nil, "not supported on darwin")
        default:
            return (nil, nil)
        }
    }
}
