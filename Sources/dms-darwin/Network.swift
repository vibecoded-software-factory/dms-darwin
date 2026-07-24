import AppKit
import CoreImage
import Darwin
import Foundation
import SystemConfiguration

// Native network channel: the macOS stand-in for the upstream Go daemon's
// `network.*`, whose backend is 100% NetworkManager/iwd D-Bus. Ethernet is read
// through SystemConfiguration and VPN through `scutil --nc`, both directly.
//
// WiFi is special: macOS gates SSID/BSSID behind Location Services in a way a
// background launchd agent cannot satisfy (even bundled + authorizedAlways,
// CoreWLAN returns <nil> names). Only a LaunchServices-started app unlocks
// them, so the WiFi work lives in a foreground helper (WiFiHelper.swift) this
// channel `open`s; the two talk over a bridge socket the daemon owns. The
// daemon caches the helper's pushed WiFi state and forwards WiFi commands to
// it, and merges that with its own Ethernet/VPN reads into the NetworkState
// DankMaterialShell's DMSNetworkService.qml expects (types.go verbatim).
final class NetworkChannel {
  var onStateChanged: (([String: Any]) -> Void)?

  private let queue = DispatchQueue(label: "dev.dms.network")
  // self.wifi + these fields are touched from both the bridge queue (helper
  // pushes) and the Server's rpc queue (handle/state); guard them.
  private let lock = NSLock()
  private var preference = "auto"
  private var connectingSSID = ""
  private var lastError = ""

  // ---- WiFi via the foreground helper over a bridge socket ----

  private var listenFd: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var helperFd: Int32 = -1
  private var helperSource: DispatchSourceRead?
  private var helperBuffer = Data()
  private var cmdId = 1
  // Last WiFi state the helper pushed (empty until it connects + scans).
  private var wifi: [String: Any] = ["enabled": false, "ssid": "", "networks": []]
  // A pending secured-connect awaiting credentials, keyed by token -> ssid.
  private var pendingConnect: [String: String] = [:]

  func start() {
    self.startBridge()
    self.launchHelper()
  }

  private func startBridge() {
    unlink(WiFiHelper.bridgePath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(WiFiHelper.bridgePath.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
      close(fd)
      return
    }
    self.listenFd = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
    source.setEventHandler { [weak self] in self?.acceptHelper() }
    source.resume()
    self.acceptSource = source
  }

  private func acceptHelper() {
    let fd = accept(self.listenFd, nil, nil)
    guard fd >= 0 else { return }
    // A new helper replaces any stale connection.
    if self.helperFd >= 0 {
      self.helperSource?.cancel()
      close(self.helperFd)
    }
    var flag: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
    self.helperFd = fd
    self.helperBuffer.removeAll()
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
    source.setEventHandler { [weak self] in self?.readHelper() }
    source.setCancelHandler { close(fd) }
    source.resume()
    self.helperSource = source
  }

  private func readHelper() {
    var scratch = [UInt8](repeating: 0, count: 65536)
    let n = read(self.helperFd, &scratch, scratch.count)
    if n <= 0 {
      self.helperSource?.cancel()
      self.helperSource = nil
      self.helperFd = -1
      return
    }
    self.helperBuffer.append(contentsOf: scratch[0..<n])
    while let nl = self.helperBuffer.firstIndex(of: 0x0A) {
      let line = self.helperBuffer.prefix(upTo: nl)
      self.helperBuffer.removeSubrange(...nl)
      guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
      else { continue }
      if let state = obj["state"] as? [String: Any] {
        self.lock.lock()
        self.wifi = state
        self.connectingSSID = ""
        self.lock.unlock()
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.onStateChanged?(self.state())
        }
      }
    }
  }

  private func sendToHelper(_ object: [String: Any]) -> Bool {
    guard self.helperFd >= 0,
      let data = try? JSONSerialization.data(withJSONObject: object)
    else { return false }
    var line = data
    line.append(0x0A)
    let sent = line.withUnsafeBytes { write(self.helperFd, $0.baseAddress, $0.count) }
    return sent > 0
  }

  private func launchHelper() {
    // The helper MUST come up through LaunchServices (open), not as a child
    // process, or it inherits our background context and CoreWLAN stays
    // <nil>. -g keeps it from stealing focus; -n allows a fresh instance.
    let app = "\(NSHomeDirectory())/Applications/DmsDarwin.app"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "-a", app, "--args", "wifi-helper"]
    try? task.run()
  }

  // ---- Ethernet / IP via SystemConfiguration + getifaddrs ----

  private func ipv4(of interfaceName: String) -> String {
    var address = ""
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
    var ptr = first
    while true {
      let flags = Int32(ptr.pointee.ifa_flags)
      let addr = ptr.pointee.ifa_addr
      if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
        addr?.pointee.sa_family == UInt8(AF_INET),
        String(cString: ptr.pointee.ifa_name) == interfaceName
      {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
          addr, socklen_t(addr!.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
        {
          address = String(cString: host)
        }
      }
      guard let next = ptr.pointee.ifa_next else { break }
      ptr = next
    }
    freeifaddrs(ifaddr)
    return address
  }

  private func ethernetDevices() -> [[String: Any]] {
    var devices: [[String: Any]] = []
    guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
    for iface in all {
      guard SCNetworkInterfaceGetInterfaceType(iface) == kSCNetworkInterfaceTypeEthernet,
        let bsd = SCNetworkInterfaceGetBSDName(iface) as String?
      else { continue }
      let ip = self.ipv4(of: bsd)
      devices.append([
        "name": bsd,
        "hwAddress": (SCNetworkInterfaceGetHardwareAddressString(iface) as String?) ?? "",
        "state": ip.isEmpty ? "disconnected" : "connected",
        "connected": !ip.isEmpty,
        "ip": ip,
      ])
    }
    return devices
  }

  // ---- VPN via scutil ----

  private func vpnActive() -> [[String: Any]] {
    let out = Self.run("/usr/sbin/scutil", ["--nc", "list"]).stdout
    var active: [[String: Any]] = []
    for line in out.split(separator: "\n") where line.contains("(Connected)") {
      let name = line.components(separatedBy: "\"").dropFirst().first ?? ""
      active.append([
        "name": name, "uuid": "", "type": "vpn", "serviceType": "", "state": "connected",
      ])
    }
    return active
  }

  private func vpnProfiles() -> [[String: Any]] {
    let out = Self.run("/usr/sbin/scutil", ["--nc", "list"]).stdout
    var profiles: [[String: Any]] = []
    for line in out.split(separator: "\n") where line.contains("\"") {
      let parts = line.components(separatedBy: "\"")
      guard parts.count >= 2 else { continue }
      profiles.append([
        "name": parts[1], "uuid": "", "type": "vpn", "serviceType": "", "autoconnect": false,
      ])
    }
    return profiles
  }

  // ---- state ----

  func state() -> [String: Any] {
    self.lock.lock()
    let wifi = self.wifi
    let connectingSSID = self.connectingSSID
    let lastError = self.lastError
    self.lock.unlock()

    let enabled = wifi["enabled"] as? Bool ?? false
    let currentSSID = wifi["ssid"] as? String ?? ""
    let bssid = wifi["bssid"] as? String ?? ""
    let signal = wifi["signal"] as? Int ?? 0
    let wifiDevice = wifi["device"] as? String ?? "en0"
    let networks = wifi["networks"] as? [[String: Any]] ?? []
    let saved = networks.filter { ($0["saved"] as? Bool) ?? false }
    let wifiIP = self.ipv4(of: wifiDevice)
    let wifiConnected = !currentSSID.isEmpty

    let ethernets = self.ethernetDevices()
    let ethConnected = ethernets.contains { ($0["connected"] as? Bool) ?? false }
    let ethIP = ethernets.first { ($0["connected"] as? Bool) ?? false }?["ip"] as? String ?? ""
    let ethDevice = ethernets.first?["name"] as? String ?? ""
    let vpn = self.vpnActive()

    var status = "disconnected"
    if !vpn.isEmpty {
      status = "vpn"
    } else if ethConnected {
      status = "ethernet"
    } else if wifiConnected {
      status = "wifi"
    }

    return [
      "backend": "corewlan",
      "networkStatus": status,
      "preference": self.preference,
      "ethernetIP": ethIP,
      "ethernetDevice": ethDevice,
      "ethernetConnected": ethConnected,
      "ethernetConnectionUuid": "",
      "ethernetDevices": ethernets,
      "wifiIP": wifiIP,
      "wifiDevice": wifiDevice,
      "wifiConnected": wifiConnected,
      "wifiEnabled": enabled,
      "wifiSSID": currentSSID,
      "wifiBSSID": bssid,
      "wifiSignal": signal,
      "wifiNetworks": networks,
      "savedWifiNetworks": saved,
      "wifiDevices": [
        [
          "name": wifiDevice, "hwAddress": "", "state": enabled ? "connected" : "disconnected",
          "connected": wifiConnected, "apCapable": false, "ssid": currentSSID, "bssid": bssid,
          "signal": signal, "ip": wifiIP, "networks": networks,
        ]
      ],
      "hotspotSupported": false, "hotspotAvailable": false, "hotspotConfigured": false,
      "hotspotEnabled": false, "hotspotActivating": false, "hotspotSecured": false,
      "hotspotSSID": "", "hotspotDevice": "", "hotspotBand": "", "hotspotLastError": "",
      "wiredConnections": [],
      "vpnProfiles": self.vpnProfiles(),
      "vpnActive": vpn,
      "isConnecting": !connectingSSID.isEmpty,
      "connectingSSID": connectingSSID,
      "lastError": lastError,
      "vpnError": "", "vpnErrorUuid": "",
    ]
  }

  // ---- request handling ----

  func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
    switch method {
    case "network.getState":
      return (self.state(), nil)
    case "network.wifi.networks":
      return (self.wifiSnapshot()["networks"] ?? [], nil)
    case "network.wifi.scan":
      _ = self.sendToHelper(["cmd": "scan", "id": self.nextId()])
      return (Self.success("scanning"), nil)
    case "network.wifi.enable", "network.wifi.disable", "network.wifi.toggle":
      let on: Bool
      switch method {
      case "network.wifi.enable": on = true
      case "network.wifi.disable": on = false
      default: on = !((self.wifiSnapshot()["enabled"] as? Bool) ?? false)
      }
      _ = self.sendToHelper(["cmd": "power", "on": on, "id": self.nextId()])
      return (Self.success(on ? "enabling wifi" : "disabling wifi"), nil)
    case "network.wifi.connect":
      return self.connectWiFi(params)
    case "network.wifi.disconnect":
      _ = self.sendToHelper(["cmd": "disconnect", "id": self.nextId()])
      return (Self.success("disconnecting"), nil)
    case "network.wifi.forget":
      guard let ssid = params["ssid"] as? String else { return (nil, "missing param: ssid") }
      _ = self.sendToHelper(["cmd": "forget", "ssid": ssid, "id": self.nextId()])
      return (Self.success("forgetting"), nil)
    case "network.wifi.setAutoconnect":
      return (Self.success("autoconnect is managed by macOS"), nil)
    case "network.credentials.submit":
      return self.submitCredentials(params)
    case "network.credentials.cancel":
      if let token = params["token"] as? String { self.setPending(token, nil) }
      self.setConnecting("")
      return (Self.success("cancelled"), nil)
    case "network.preference.set":
      if let pref = params["preference"] as? String { self.preference = pref }
      return (Self.success("preference set"), nil)
    case "network.info":
      guard let ssid = params["ssid"] as? String else { return (nil, "missing param: ssid") }
      let nets = self.wifiSnapshot()["networks"] as? [[String: Any]] ?? []
      guard let n = nets.first(where: { $0["ssid"] as? String == ssid }) else {
        return (["bands": []], nil)
      }
      let channel = (n["channel"] as? UInt32).map(Int.init) ?? 0
      let freq = channel <= 14 ? 2407 + channel * 5 : 5000 + channel * 5
      let band: [String: Any] = [
        "frequency": freq, "connected": n["connected"] ?? false,
        "signal": n["signal"] ?? 0, "channel": channel, "rate": 0,
        "bssid": n["bssid"] ?? "", "mode": "infrastructure",
        "secured": n["secured"] ?? false, "saved": n["saved"] ?? false,
      ]
      return (["bands": [band]], nil)
    case "network.qrcode-content":
      guard let ssid = params["ssid"] as? String else { return (nil, "missing param: ssid") }
      guard let content = self.qrContent(ssid: ssid) else {
        return (nil, "no saved password for \(ssid)")
      }
      return (content, nil)
    case "network.qrcode":
      guard let ssid = params["ssid"] as? String else { return (nil, "missing param: ssid") }
      guard let content = self.qrContent(ssid: ssid) else {
        return (nil, "no saved password for \(ssid) (QR needs a WPA network you have joined)")
      }
      let base = NSTemporaryDirectory() + "dms-qr-\(abs(ssid.hashValue))"
      let themed = base + "-themed.png"
      let normal = base + "-normal.png"
      guard Self.writeQRPNG(content, to: normal, white: false),
        Self.writeQRPNG(content, to: themed, white: true)
      else { return (nil, "failed to render QR code") }
      return ([themed, normal], nil)
    case "network.delete-qrcode":
      return (Self.success("ok"), nil)
    case "network.ethernet.info":
      return (self.state(), nil)
    case "network.ethernet.connect", "network.ethernet.connect.config",
      "network.ethernet.disconnect":
      return (Self.success("ethernet is managed by macOS"), nil)
    case "network.vpn.profiles":
      return (self.vpnProfiles(), nil)
    case "network.vpn.active":
      return (self.vpnActive(), nil)
    case "network.vpn.connect":
      guard let name = params["name"] as? String ?? params["uuid"] as? String else {
        return (nil, "missing param: name")
      }
      let r = Self.run("/usr/sbin/scutil", ["--nc", "start", name])
      return r.exit == 0 ? (Self.success("connecting"), nil) : (nil, "vpn start failed")
    case "network.vpn.disconnect", "network.vpn.disconnectAll":
      if let name = params["name"] as? String ?? params["uuid"] as? String {
        _ = Self.run("/usr/sbin/scutil", ["--nc", "stop", name])
      } else {
        for p in self.vpnActive() where p["name"] is String {
          _ = Self.run("/usr/sbin/scutil", ["--nc", "stop", p["name"] as! String])
        }
      }
      return (Self.success("disconnected"), nil)
    case let m where m.hasPrefix("network.hotspot."):
      return (nil, "hotspot is not supported on macOS")
    case let m where m.hasPrefix("network.vpn."):
      return (nil, "manage VPN configuration in System Settings on macOS")
    default:
      return (nil, "unknown method: \(method)")
    }
  }

  private func connectWiFi(_ params: [String: Any]) -> (Any?, String?) {
    guard let ssid = params["ssid"] as? String else { return (nil, "missing param: ssid") }
    let password = params["password"] as? String ?? ""
    let interactive = params["interactive"] as? Bool ?? false

    let net = (self.wifiSnapshot()["networks"] as? [[String: Any]] ?? []).first {
      $0["ssid"] as? String == ssid
    }
    let secured = (net?["secured"] as? Bool) ?? false
    let saved = (net?["saved"] as? Bool) ?? false

    // Secured, unsaved, no password, interactive -> ask the shell for the
    // password (upstream's token flow); it comes back via credentials.submit.
    if secured && password.isEmpty && !saved && interactive {
      let token = "net-\(ssid)-\(self.nextId())"
      self.setPending(token, ssid)
      self.setConnecting(ssid)
      return (["token": token, "ssid": ssid, "needsCredentials": true], nil)
    }

    self.setConnecting(ssid)
    _ = self.sendToHelper([
      "cmd": "connect", "ssid": ssid, "password": password, "id": self.nextId(),
    ])
    return (Self.success("connecting"), nil)
  }

  private func submitCredentials(_ params: [String: Any]) -> (Any?, String?) {
    guard let token = params["token"] as? String, let ssid = self.takePending(token) else {
      return (nil, "unknown credentials token")
    }
    let secrets = params["secrets"] as? [String: Any]
    let password = (secrets?["password"] as? String) ?? (params["password"] as? String) ?? ""
    self.setConnecting(ssid)
    _ = self.sendToHelper([
      "cmd": "connect", "ssid": ssid, "password": password, "id": self.nextId(),
    ])
    return (Self.success("connecting"), nil)
  }

  // ---- helpers ----

  private func nextId() -> Int {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.cmdId += 1
    return self.cmdId
  }

  private func setPending(_ token: String, _ ssid: String?) {
    self.lock.lock()
    self.pendingConnect[token] = ssid
    self.lock.unlock()
  }

  private func takePending(_ token: String) -> String? {
    self.lock.lock()
    defer { self.lock.unlock() }
    let ssid = self.pendingConnect[token]
    self.pendingConnect[token] = nil
    return ssid
  }

  private func wifiSnapshot() -> [String: Any] {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.wifi
  }

  private func setConnecting(_ ssid: String) {
    self.lock.lock()
    self.connectingSSID = ssid
    self.lock.unlock()
  }

  private static func success(_ message: String) -> [String: Any] {
    ["success": true, "message": message]
  }

  // The WIFI: URI a QR encodes. A secured network's password is a System
  // keychain generic password ("AirPort network password"); reading it
  // prompts for authorization (admin, on a locked-down Mac). A user WITH the
  // rights approves and gets the QR; one without cancels and gets an honest
  // error - the feature stays for everyone who can use it. The concurrent rpc
  // queue keeps this prompt from stalling the WiFi list. Open networks need
  // no password.
  private func qrContent(ssid: String) -> String? {
    func esc(_ s: String) -> String {
      var o = ""
      for c in s {
        if "\\;,:\"".contains(c) { o.append("\\") }
        o.append(c)
      }
      return o
    }
    let r = Self.run(
      "/usr/bin/security",
      ["find-generic-password", "-D", "AirPort network password", "-a", ssid, "-w"])
    let password = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if r.exit == 0 && !password.isEmpty {
      return "WIFI:S:\(esc(ssid));T:WPA;P:\(esc(password));;"
    }
    // Password not readable (denied / not admin): only an open network
    // still yields a usable QR.
    let nets = self.wifiSnapshot()["networks"] as? [[String: Any]] ?? []
    let secured = (nets.first { $0["ssid"] as? String == ssid }?["secured"] as? Bool) ?? true
    return secured ? nil : "WIFI:S:\(esc(ssid));T:nopass;;"
  }

  private static func writeQRPNG(_ content: String, to path: String, white: Bool) -> Bool {
    guard let data = content.data(using: .utf8),
      let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return false }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard var image = filter.outputImage else { return false }
    image = image.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    // themed = inverted (white modules on black) for dark UI; normal =
    // black on white. Both scan.
    if white, let invert = CIFilter(name: "CIColorInvert") {
      invert.setValue(image, forKey: "inputImage")
      if let out = invert.outputImage { image = out }
    }
    let rep = NSCIImageRep(ciImage: image)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
      let png = bmp.representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  private static func run(_ tool: String, _ args: [String]) -> (
    stdout: String, stderr: String, exit: Int32
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return ("", "\(error)", -1) }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self),
      process.terminationStatus
    )
  }
}
