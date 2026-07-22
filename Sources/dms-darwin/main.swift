import Foundation

// dms-darwin: a macOS daemon speaking the DankMaterialShell daemon protocol
// ($DMS_SOCKET), so the unmodified shell gets its system integrations from
// native backends. The upstream Go daemon owns Linux; this one owns macOS.
//
//   dms-darwin serve      run the daemon (launchd agent's job)
//   dms-darwin selftest   pure-logic checks
//   dms-darwin version    print the version

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
case "serve":
    let server = Server(socketPath: defaultSocketPath())
    guard server.start() else {
        print("[server] failed to bind \(defaultSocketPath())")
        exit(1)
    }
    RunLoop.main.run()
default:
    print("usage: dms-darwin [serve|selftest|version]")
    exit(64)
}
