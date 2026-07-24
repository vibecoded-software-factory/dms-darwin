import AppKit
import CoreLocation
import CoreWLAN
import Darwin
import Foundation

// The foreground WiFi worker (`dms-darwin wifi-helper`).
//
// macOS gates WiFi SSID/BSSID behind Location Services in a way a background
// launchd agent cannot satisfy - even bundled, with an embedded usage string
// and authorizationStatus == .authorizedAlways, CoreWLAN returns <nil> names
// (and ipconfig/networksetup are redacted too). The ONE context that unlocks
// them is a real app launched through LaunchServices. So NetworkChannel
// `open -g`s this helper (LSUIElement: no Dock icon, never steals focus); it
// holds the CoreWLAN session, scans continuously, and performs the WiFi
// actions, reporting to the daemon over a bridge socket the daemon owns.
//
// Bridge protocol (JSON lines):
//   helper -> daemon:  {"state": {enabled, ssid, bssid, signal, networks:[...]}}
//   daemon -> helper:  {"id": N, "cmd": "connect|disconnect|power|forget|scan", ...}
//   helper -> daemon:  {"id": N, "ok": true} | {"id": N, "error": "..."}
final class WiFiHelper: NSObject, CLLocationManagerDelegate {
  static let bridgePath = "/tmp/dms-wifi-bridge.sock"

  private let location = CLLocationManager()
  private let client = CWWiFiClient.shared()
  private var fd: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var buffer = Data()
  private var lastStateJSON = ""

  private var interface: CWInterface? { self.client.interface() }

  func run() {
    self.location.delegate = self
    self.location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    if self.location.authorizationStatus == .notDetermined {
      self.location.requestAlwaysAuthorization()
    } else {
      self.location.startUpdatingLocation()
    }
    self.connectBridge()
    // Continuous scan + push. 4s balances freshness against the ~2s scan.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 4)
    timer.setEventHandler { [weak self] in self?.pushState() }
    timer.resume()
    self.scanTimer = timer
  }

  private var scanTimer: DispatchSourceTimer?

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager.authorizationStatus == .authorizedAlways { manager.startUpdatingLocation() }
  }
  func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {}
  func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {}

  // ---- bridge connection (retry until the daemon is up) ----

  private func connectBridge() {
    self.fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard self.fd >= 0 else {
      self.scheduleReconnect()
      return
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(Self.bridgePath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(self.fd, $0, size) }
    }
    if ok != 0 {
      close(self.fd)
      self.fd = -1
      self.scheduleReconnect()
      return
    }
    var flag: Int32 = 1
    setsockopt(self.fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
    let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: .main)
    source.setEventHandler { [weak self] in self?.readBridge() }
    source.resume()
    self.readSource = source
    self.lastStateJSON = ""
    self.pushState()
  }

  private func scheduleReconnect() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectBridge() }
  }

  private func dropBridge() {
    self.readSource?.cancel()
    self.readSource = nil
    if self.fd >= 0 { close(self.fd) }
    self.fd = -1
    self.scheduleReconnect()
  }

  private func readBridge() {
    var scratch = [UInt8](repeating: 0, count: 65536)
    let n = read(self.fd, &scratch, scratch.count)
    if n <= 0 {
      self.dropBridge()
      return
    }
    self.buffer.append(contentsOf: scratch[0..<n])
    while let nl = self.buffer.firstIndex(of: 0x0A) {
      let line = self.buffer.prefix(upTo: nl)
      self.buffer.removeSubrange(...nl)
      if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
        self.handleCommand(obj)
      }
    }
  }

  private func send(_ object: [String: Any]) {
    guard self.fd >= 0,
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return }
    var line = data
    line.append(0x0A)
    _ = line.withUnsafeBytes { Darwin.write(self.fd, $0.baseAddress, $0.count) }
  }

  // ---- scanning ----

  private func signalPercent(_ rssi: Int) -> Int {
    if rssi >= -50 { return 100 }
    if rssi <= -100 { return 0 }
    return 2 * (rssi + 100)
  }

  private func savedSSIDs() -> Set<String> {
    guard let config = self.interface?.configuration() else { return [] }
    var names = Set<String>()
    for case let p as CWNetworkProfile in config.networkProfiles {
      if let s = p.ssid { names.insert(s) }
    }
    return names
  }

  private func wifiState() -> [String: Any] {
    guard let iface = self.interface else {
      return ["enabled": false, "ssid": "", "bssid": "", "signal": 0, "networks": []]
    }
    let current = iface.ssid()
    let saved = self.savedSSIDs()
    let nets = (try? iface.scanForNetworks(withSSID: nil)).map { Array($0) } ?? []
    var networks: [[String: Any]] = []
    var seen = Set<String>()
    for net in nets {
      guard let ssid = net.ssid, !ssid.isEmpty, !seen.contains(ssid) else { continue }
      seen.insert(ssid)
      let secured =
        net.supportsSecurity(.personal) || net.supportsSecurity(.enterprise)
        || net.supportsSecurity(.wpa2Personal) || net.supportsSecurity(.wpa3Personal)
      networks.append([
        "ssid": ssid, "bssid": net.bssid ?? "", "signal": self.signalPercent(net.rssiValue),
        "secured": secured, "enterprise": net.supportsSecurity(.enterprise),
        "connected": ssid == current, "saved": saved.contains(ssid),
        "channel": UInt32(net.wlanChannel?.channelNumber ?? 0),
      ])
    }
    networks.sort { ($0["signal"] as! Int) > ($1["signal"] as! Int) }
    return [
      "enabled": iface.powerOn(),
      "ssid": current ?? "",
      "bssid": iface.bssid() ?? "",
      "signal": self.signalPercent(iface.rssiValue()),
      "device": iface.interfaceName ?? "",
      "networks": networks,
    ]
  }

  private func pushState() {
    let state = self.wifiState()
    guard let data = try? JSONSerialization.data(withJSONObject: ["state": state]) else { return }
    let json = String(decoding: data, as: UTF8.self)
    // Only push when something actually changed (scan is noisy on rssi, so
    // key on ssid/enabled/network-name-set).
    let sig =
      "\(state["ssid"] ?? "")|\(state["enabled"] ?? "")|"
      + ((state["networks"] as? [[String: Any]])?.compactMap { $0["ssid"] as? String }.sorted()
        .joined(separator: ",") ?? "")
    if sig != self.lastStateJSON {
      self.lastStateJSON = sig
      self.send(["state": state])
    }
    _ = json
  }

  // ---- commands ----

  private func handleCommand(_ obj: [String: Any]) {
    let id = obj["id"] as? Int ?? 0
    let cmd = obj["cmd"] as? String ?? ""
    guard let iface = self.interface else {
      self.send(["id": id, "error": "no wifi interface"])
      return
    }
    switch cmd {
    case "scan":
      self.lastStateJSON = ""
      self.pushState()
      self.send(["id": id, "ok": true])
    case "power":
      let on = obj["on"] as? Bool ?? true
      do {
        try iface.setPower(on)
        self.send(["id": id, "ok": true])
      } catch { self.send(["id": id, "error": error.localizedDescription]) }
      self.lastStateJSON = ""
      self.pushState()
    case "disconnect":
      iface.disassociate()
      self.send(["id": id, "ok": true])
      self.lastStateJSON = ""
      self.pushState()
    case "forget":
      let ssid = obj["ssid"] as? String ?? ""
      let device = iface.interfaceName ?? "en0"
      let r = Process()
      r.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
      r.arguments = ["-removepreferredwirelessnetwork", device, ssid]
      try? r.run()
      r.waitUntilExit()
      self.send([
        "id": id, "ok": r.terminationStatus == 0,
        "error": r.terminationStatus == 0 ? "" : "forget needs admin",
      ])
    case "connect":
      let ssid = obj["ssid"] as? String ?? ""
      let password = obj["password"] as? String ?? ""
      let device = iface.interfaceName ?? "en0"
      // networksetup -setairportnetwork joins by name and reuses the
      // keychain password for a saved network when none is given -
      // more reliable than CWInterface.associate, which does not pull
      // the saved secret and fails to rejoin a known secured network.
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
      proc.arguments =
        ["-setairportnetwork", device, ssid] + (password.isEmpty ? [] : [password])
      let out = Pipe()
      proc.standardOutput = out
      proc.standardError = out
      try? proc.run()
      proc.waitUntilExit()
      let reply = String(
        decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      // networksetup prints an error line but often still exits 0, so
      // treat any "Error"/"Failed" text as failure.
      let failed =
        reply.localizedCaseInsensitiveContains("error")
        || reply.localizedCaseInsensitiveContains("failed")
        || reply.localizedCaseInsensitiveContains("not find")
      if failed {
        self.send(["id": id, "error": reply.isEmpty ? "connect failed" : reply])
      } else {
        self.send(["id": id, "ok": true])
      }
      self.lastStateJSON = ""
      self.pushState()
    default:
      self.send(["id": id, "error": "unknown cmd: \(cmd)"])
    }
  }
}
