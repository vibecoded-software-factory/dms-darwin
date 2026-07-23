import Foundation

// dms-darwin: a macOS daemon speaking the DankMaterialShell daemon protocol
// ($DMS_SOCKET), so the unmodified shell gets its system integrations from
// native backends. The upstream Go daemon owns Linux; this one owns macOS.
//
//   dms-darwin serve      run the daemon (launchd agent's job)
//   dms-darwin selftest   pure-logic checks
//   dms-darwin version    print the version
//   dms-darwin lock       engage the native lock screen
//   dms-darwin audio-tap  system audio -> fifo, for visualizers

let arguments = CommandLine.arguments

func defaultSocketPath() -> String {
    if let fromEnv = ProcessInfo.processInfo.environment["DMS_SOCKET"], !fromEnv.isEmpty {
        return fromEnv
    }
    return "/tmp/dms-darwin.sock"
}

switch arguments.count > 1 ? arguments[1] : "serve" {
case "selftest":
    exit(SelfTest.run())
case "version":
    print(Server.cliVersion)
    exit(0)
case "lock":
    // The shell's customPowerActionLock spawns this: lock natively and let
    // the OS own the surface and the authentication.
    exit(NativeLock.lock() ? 0 : 1)
case "audio-tap":
    // System-audio -> fifo, for a visualizer. Run as a child of the app
    // holding the Screen Recording grant (TCC follows the responsible
    // process).
    let fifo = arguments.count > 2 ? arguments[2] : "/tmp/dms-audio-tap.fifo"
    exit(AudioTap(fifoPath: fifo).run())
case "serve":
    // launchd points stdout at a log file; line-buffer it so prints land live.
    setvbuf(stdout, nil, _IOLBF, 0)
    // Opt out of App Nap: a napped agent stops receiving distributed
    // notifications (regardless of suspension behavior), which silently
    // breaks appearance-change delivery. The daemon is tiny; keeping it
    // schedulable costs nothing and also keeps the gamma tick on time.
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep],
        reason: "event delivery must survive idle (App Nap drops notifications)")
    _ = activity
    let server = Server(socketPath: defaultSocketPath())
    guard server.start() else {
        print("[server] failed to bind \(defaultSocketPath())")
        exit(1)
    }
    RunLoop.main.run()
default:
    print("usage: dms-darwin [serve|selftest|version|lock|audio-tap]")
    exit(64)
}
