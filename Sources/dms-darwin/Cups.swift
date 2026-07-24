import Foundation

// Native CUPS/printing channel: the macOS stand-in for the upstream Go
// daemon's `cups.*` methods. The Go manager talks IPP over TCP to
// http://localhost:631, but macOS's cupsd is socket-activated by launchd and
// only exposes the domain socket /private/var/run/cupsd reliably - its TCP
// listener exists solely while cupsd is awake, so the Go daemon's init hits
// "connection refused" and never advertises `cups`. The CUPS CLI (lpstat/lp/
// cancel/lpinfo/cupsenable...) always reaches cupsd through that domain
// socket, so this channel drives the CLI.
//
// Wire shapes mirror core/internal/server/cups/{types,handlers}.go verbatim so
// DankMaterialShell's CupsService.qml binds unchanged: getPrinters -> [Printer
// {name,uri,state,stateReason,location,info,makeModel,accepting,jobs}],
// getJobs -> [Job {id,name,state,printer,user,size,timeCreated}]. Admin
// mutations (enable/disable, accept/reject, lpadmin) go through cupsd's policy;
// where it demands authorization the CLI exits non-zero and that surfaces as an
// honest error rather than a faked success.
final class CupsChannel {
  // Handed the freshly-computed state (already off the main loop) so the
  // Server just broadcasts it - never runs the CUPS CLI on the shared loop.
  var onStateChanged: (([String: Any]) -> Void)?

  private var pollTimer: DispatchSourceTimer?
  private var lastSignature = ""
  // Every CLI call (fast lpstat, slow lpinfo) runs here, off the main loop.
  private let queue = DispatchQueue(label: "dev.dms.cups.poll")

  // ---- lifecycle ----

  func start() {
    // No CUPS push over the domain socket (the Go path used D-Bus, absent
    // here), so poll cupsd and fire onStateChanged when the printer/job
    // set changes. The shell's handler just re-fetches, so a coarse
    // signature is enough. 3s is unobtrusive for a print queue.
    let timer = DispatchSource.makeTimerSource(queue: self.queue)
    timer.schedule(deadline: .now() + 3, repeating: 3)
    timer.setEventHandler { [weak self] in self?.pollForChanges() }
    timer.resume()
    self.pollTimer = timer
  }

  // Runs on `self.queue`.
  private func pollForChanges() {
    let sig = Self.run("/usr/bin/lpstat", ["-p", "-o"]).stdout
    guard sig != self.lastSignature else { return }
    self.lastSignature = sig
    let snapshot = self.state()
    DispatchQueue.main.async { [weak self] in self?.onStateChanged?(snapshot) }
  }

  func state() -> [String: Any] {
    // CUPSState{printers: map}. The shell only treats the event as a
    // re-fetch trigger, so a light snapshot keyed by name is enough.
    var printers: [String: Any] = [:]
    for printer in self.getPrinters() {
      if let name = printer["name"] as? String { printers[name] = printer }
    }
    return ["printers": printers]
  }

  // ---- request handling ----

  func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
    switch method {
    case "cups.getPrinters":
      return (self.getPrinters(), nil)
    case "cups.getJobs":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      return (self.getJobs(printer: name), nil)
    case "cups.cancelJob":
      guard let id = Self.intParam(params, "jobId") else { return (nil, "missing param: jobId") }
      return self.action("/usr/bin/cancel", ["\(id)"], "job canceled")
    case "cups.purgeJobs":
      let name = params["printerName"] as? String
      return self.action("/usr/bin/cancel", name.map { ["-a", $0] } ?? ["-a"], "jobs purged")
    case "cups.pausePrinter":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      return self.action("/usr/sbin/cupsdisable", [name], "printer paused")
    case "cups.resumePrinter":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      return self.action("/usr/sbin/cupsenable", [name], "printer resumed")
    case "cups.acceptJobs":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      return self.action("/usr/sbin/cupsaccept", [name], "accepting jobs")
    case "cups.rejectJobs":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      return self.action("/usr/sbin/cupsreject", [name], "rejecting jobs")
    case "cups.getDevices":
      return (self.getDevices(), nil)
    case "cups.getPPDs":
      return (self.getPPDs(), nil)
    case "cups.getClasses":
      return (self.getClasses(), nil)
    case "cups.printTestPage":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      let page =
        "/System/Library/Frameworks/CoreServices.framework/Resources/English.lproj/InfoPlist.strings"
      let file = FileManager.default.fileExists(atPath: page) ? page : "/etc/hosts"
      return self.action("/usr/bin/lp", ["-d", name, file], "test page sent")
    case "cups.setPrinterLocation":
      guard let name = params["printerName"] as? String, let loc = params["location"] as? String
      else { return (nil, "missing param: printerName/location") }
      return self.action("/usr/sbin/lpadmin", ["-p", name, "-L", loc], "location set")
    case "cups.setPrinterInfo":
      guard let name = params["printerName"] as? String, let info = params["info"] as? String
      else { return (nil, "missing param: printerName/info") }
      return self.action("/usr/sbin/lpadmin", ["-p", name, "-D", info], "info set")
    case "cups.setPrinterShared":
      guard let name = params["printerName"] as? String, let shared = params["shared"] as? Bool
      else { return (nil, "missing param: printerName/shared") }
      return self.action(
        "/usr/sbin/lpadmin", ["-p", name, "-o", "printer-is-shared=\(shared ? "true" : "false")"],
        "sharing updated")
    case "cups.deletePrinter":
      guard let name = params["printerName"] as? String else {
        return (nil, "missing param: printerName")
      }
      return self.action("/usr/sbin/lpadmin", ["-x", name], "printer deleted")
    case "cups.deleteClass":
      guard let name = params["className"] as? String else {
        return (nil, "missing param: className")
      }
      return self.action("/usr/sbin/lpadmin", ["-x", name], "class deleted")
    case "cups.addPrinterToClass":
      guard let p = params["printerName"] as? String, let c = params["className"] as? String
      else { return (nil, "missing param: printerName/className") }
      return self.action("/usr/sbin/lpadmin", ["-p", p, "-c", c], "added to class")
    case "cups.removePrinterFromClass":
      guard let p = params["printerName"] as? String, let c = params["className"] as? String
      else { return (nil, "missing param: printerName/className") }
      return self.action("/usr/sbin/lpadmin", ["-p", p, "-r", c], "removed from class")
    case "cups.testConnection":
      let ok = Self.run("/usr/bin/lpstat", ["-r"]).exit == 0
      return (["success": ok, "connected": ok], nil)
    case "cups.holdJob":
      guard let id = Self.intParam(params, "jobId") else { return (nil, "missing param: jobId") }
      return self.action("/usr/bin/lp", ["-i", "\(id)", "-H", "hold"], "job held")
    case "cups.restartJob":
      guard let id = Self.intParam(params, "jobId") else { return (nil, "missing param: jobId") }
      return self.action("/usr/bin/lp", ["-i", "\(id)", "-H", "resume"], "job restarted")
    case "cups.moveJob":
      guard let id = Self.intParam(params, "jobId"), let dest = params["printerName"] as? String
      else { return (nil, "missing param: jobId/printerName") }
      return self.action("/usr/sbin/lpmove", ["\(id)", dest], "job moved")
    case "cups.subscribe":
      return (self.state(), nil)
    case "cups.createPrinter":
      // Driver install + PPD selection is an interactive lpadmin flow
      // better done in System Settings > Printers on macOS.
      return (nil, "not supported: add printers via System Settings on macOS")
    default:
      return (nil, "unknown method: \(method)")
    }
  }

  // ---- reads via CLI ----

  private func getPrinters() -> [[String: Any]] {
    // `lpstat -l -p` : "printer NAME is idle. enabled since ...\n\treason"
    // `lpstat -a`    : "NAME accepting requests since ..." / "not accepting"
    // `lpstat -v`    : "device for NAME: uri"
    // `lpoptions -p NAME` : printer-make-and-model / -location / -info
    let pOut = Self.run("/usr/bin/lpstat", ["-l", "-p"]).stdout
    let aOut = Self.run("/usr/bin/lpstat", ["-a"]).stdout
    let vOut = Self.run("/usr/bin/lpstat", ["-v"]).stdout

    var accepting: [String: Bool] = [:]
    for line in aOut.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1)
      guard let name = parts.first.map(String.init) else { continue }
      accepting[name] = !line.contains("not accepting")
    }
    var uris: [String: String] = [:]
    for line in vOut.split(separator: "\n") where line.hasPrefix("device for ") {
      let rest = line.dropFirst("device for ".count)
      if let colon = rest.firstIndex(of: ":") {
        let name = String(rest[..<colon])
        let uri = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        uris[name] = uri
      }
    }

    var printers: [[String: Any]] = []
    var current: [String: Any]?
    func flush() {
      if let printer = current { printers.append(printer) }
      current = nil
    }
    for raw in pOut.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if line.hasPrefix("printer ") {
        flush()
        // "printer NAME is idle.  enabled since ..." /
        // "printer NAME disabled since ... -" / "... is processing"
        let after = line.dropFirst("printer ".count)
        let name = String(after.prefix(while: { $0 != " " }))
        var pstate = "idle"
        if line.contains("is processing") || line.contains("now printing") {
          pstate = "processing"
        } else if line.contains("disabled") || line.contains("is stopped") {
          pstate = "stopped"
        }
        let makeModel = Self.lpoption(name, "printer-make-and-model")
        current = [
          "name": name,
          "uri": uris[name] ?? "",
          "state": pstate,
          "stateReason": "",
          "location": Self.lpoption(name, "printer-location"),
          "info": Self.lpoption(name, "printer-info"),
          "makeModel": makeModel,
          "accepting": accepting[name] ?? true,
          "jobs": self.getJobs(printer: name),
        ]
      } else if current != nil {
        // Indented detail line - the disable/state reason.
        let reason = line.trimmingCharacters(in: .whitespaces)
        if !reason.isEmpty, current?["stateReason"] as? String == "" {
          current?["stateReason"] = reason
        }
      }
    }
    flush()
    return printers
  }

  private func getJobs(printer: String?) -> [[String: Any]] {
    // `lpstat -W not-completed -o [NAME]` :
    //   "NAME-ID   user   size   date"
    var args = ["-W", "not-completed", "-o"]
    if let printer = printer { args.append(printer) }
    let out = Self.run("/usr/bin/lpstat", args).stdout
    var jobs: [[String: Any]] = []
    for raw in out.split(separator: "\n") {
      let fields = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard fields.count >= 3 else { continue }
      let token = fields[0]  // NAME-ID
      guard let dash = token.lastIndex(of: "-"),
        let id = Int(token[token.index(after: dash)...])
      else { continue }
      let printerName = String(token[..<dash])
      let user = fields[1]
      let size = Int(fields[2]) ?? 0
      jobs.append([
        "id": id,
        "name": token,
        "state": "processing",
        "printer": printerName,
        "user": user,
        "size": size,
        "timeCreated": ISO8601DateFormatter().string(from: Date()),
      ])
    }
    return jobs
  }

  private func getDevices() -> [[String: Any]] {
    // `lpinfo -v` : "network ipp://..." / "direct usb://..."
    var devices: [[String: Any]] = []
    for raw in Self.run("/usr/sbin/lpinfo", ["-v"]).stdout.split(separator: "\n") {
      let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      devices.append(["class": parts[0], "uri": parts[1], "info": "", "makeModel": ""])
    }
    return devices
  }

  private func getPPDs() -> [[String: Any]] {
    // `lpinfo -m` : "ppd-name  make-and-model"
    var ppds: [[String: Any]] = []
    for raw in Self.run("/usr/sbin/lpinfo", ["-m"]).stdout.split(separator: "\n") {
      let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      ppds.append(["ppd": parts[0], "makeModel": parts[1].trimmingCharacters(in: .whitespaces)])
    }
    return ppds
  }

  private func getClasses() -> [[String: Any]] {
    // `lpstat -c` : "members of class NAME:\n\tprinter1\n\tprinter2"
    var classes: [[String: Any]] = []
    var name: String?
    var members: [String] = []
    func flush() {
      if let n = name { classes.append(["name": n, "printers": members]) }
      name = nil
      members = []
    }
    for raw in Self.run("/usr/bin/lpstat", ["-c"]).stdout.split(separator: "\n") {
      let line = String(raw)
      if line.hasPrefix("members of class ") {
        flush()
        let after = line.dropFirst("members of class ".count)
        name = String(after.prefix(while: { $0 != ":" }))
      } else if name != nil {
        let m = line.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { members.append(m) }
      }
    }
    flush()
    return classes
  }

  // ---- helpers ----

  private func action(_ tool: String, _ args: [String], _ message: String) -> (Any?, String?) {
    let result = Self.run(tool, args)
    if result.exit == 0 {
      return (["success": true, "message": message], nil)
    }
    let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return (nil, err.isEmpty ? "\(tool) failed (exit \(result.exit))" : err)
  }

  private static func lpoption(_ printer: String, _ key: String) -> String {
    // `lpoptions -p NAME` prints space-separated key=value; values with
    // spaces are single-quoted.
    let out = run("/usr/bin/lpoptions", ["-p", printer]).stdout
    guard let range = out.range(of: "\(key)=") else { return "" }
    let after = out[range.upperBound...]
    if after.first == "'" {
      let body = after.dropFirst()
      if let end = body.firstIndex(of: "'") { return String(body[..<end]) }
    }
    return String(after.prefix(while: { $0 != " " && $0 != "\n" }))
  }

  private static func intParam(_ params: [String: Any], _ key: String) -> Int? {
    if let value = params[key] as? Int { return value }
    if let value = params[key] as? Double { return Int(value) }
    return nil
  }

  private static func run(_ tool: String, _ args: [String]) -> (
    stdout: String, stderr: String, exit: Int32
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
      try process.run()
    } catch {
      return ("", "\(error)", -1)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      String(decoding: outData, as: UTF8.self),
      String(decoding: errData, as: UTF8.self),
      process.terminationStatus
    )
  }
}
