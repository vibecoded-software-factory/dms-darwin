import AppKit
import ApplicationServices
import Foundation

// Native clipboard-history channel: the macOS stand-in for the upstream Go
// daemon's `clipboard.*` methods. Upstream's implementation is hard-wired to
// a Wayland ext-data-control device (core/internal/clipboard/wl.go,
// wlclient.Connect) and its server manager refuses to initialize without a
// Wayland context (core/internal/server/server.go InitializeClipboardManager),
// so on macOS the Go daemon never advertises `clipboard` nor answers its
// methods. This channel serves them natively over NSPasteboard with a
// JSON-persisted store.
//
// The wire shapes mirror core/internal/server/clipboard/handlers.go +
// types.go verbatim so DankMaterialShell's ClipboardService.qml binds
// unchanged: Entry {id,data,mimeType,preview,size,timestamp,isImage,hash,
// pinned}, SearchResult {entries,total,hasMore}, {supported}, {count},
// SuccessResult {success,message}. getHistory/search omit `data` (upstream
// nils it); getEntry returns it base64-encoded (the thumbnail loads it as a
// `data:image/png;base64,` URI).
final class ClipboardChannel {
  struct Entry {
    var id: UInt64
    var data: Data
    var mimeType: String
    var preview: String
    var size: Int
    var timestamp: Date
    var isImage: Bool
    var hash: UInt64
    var pinned: Bool
  }

  struct Config {
    var maxHistory = 100
    var maxEntrySize = 5 * 1024 * 1024
    var autoClearDays = 0
    var clearAtStartup = false
    var disabled = false
    var maxPinned = 25
  }

  // Fired on the main queue after any store mutation so the Server can
  // broadcast a `clipboard` state event to subscribers (upstream pushes
  // State on every change via the manager's notifier).
  var onStateChanged: (() -> Void)?

  private var entries: [Entry] = []  // newest first (highest id first)
  private var nextId: UInt64 = 1
  private var config = Config()
  private let pasteboard = NSPasteboard.general
  private var lastChangeCount: Int
  private var pollTimer: DispatchSourceTimer?

  // Password managers and transient producers tag their writes so history
  // tools skip them; honor the de-facto NSPasteboard privacy contract, the
  // macOS analogue of upstream's hasSensitiveMimeType (x-kde-passwordManager
  // -Hint / concealed hints).
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  private let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  init() {
    self.lastChangeCount = NSPasteboard.general.changeCount
    self.loadConfig()
    self.loadStore()
    if self.config.clearAtStartup {
      self.entries.removeAll { !$0.pinned }
    }
    if self.config.autoClearDays > 0 {
      let cutoff = Date().addingTimeInterval(-Double(self.config.autoClearDays) * 86400)
      self.entries.removeAll { !$0.pinned && $0.timestamp < cutoff }
    }
  }

  // ---- lifecycle ----

  func start() {
    // 0.5s is imperceptible for a paste and cheap: a changeCount read is a
    // single Mach message. Upstream watches the Wayland data device for
    // offers; NSPasteboard exposes no change notification, so we poll.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    timer.setEventHandler { [weak self] in self?.poll() }
    timer.resume()
    self.pollTimer = timer
    // Capture whatever is already on the pasteboard so the first open of
    // the history modal is not empty.
    self.poll(initial: true)
  }

  private func poll(initial: Bool = false) {
    let count = self.pasteboard.changeCount
    guard count != self.lastChangeCount || initial else { return }
    self.lastChangeCount = count
    guard !self.config.disabled else { return }
    guard let captured = self.capture() else { return }
    self.insert(captured)
  }

  // ---- capture ----

  private func capture() -> Entry? {
    let types = self.pasteboard.types ?? []
    if types.contains(Self.concealedType) || types.contains(Self.transientType) { return nil }

    // An image copy commonly also exposes plain text (a filename/URL), so
    // detect image first to store the richer form, matching upstream's
    // mime preference ordering.
    if let png = self.readImagePNG() {
      guard png.count <= self.config.maxEntrySize else { return nil }
      return self.makeEntry(data: png, mimeType: "image/png", isImage: true)
    }
    if let text = self.pasteboard.string(forType: .string),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let data = Data(text.utf8)
      guard data.count <= self.config.maxEntrySize else { return nil }
      return self.makeEntry(data: data, mimeType: "text/plain;charset=utf-8", isImage: false)
    }
    return nil
  }

  private func readImagePNG() -> Data? {
    if let png = self.pasteboard.data(forType: .png) { return png }
    if let tiff = self.pasteboard.data(forType: .tiff),
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    {
      return png
    }
    return nil
  }

  private func makeEntry(data: Data, mimeType: String, isImage: Bool) -> Entry {
    Entry(
      id: 0,
      data: data,
      mimeType: mimeType,
      preview: isImage ? Self.imagePreview(data) : Self.textPreview(data),
      size: data.count,
      timestamp: Date(),
      isImage: isImage,
      hash: Self.fnv1a(data),
      pinned: false)
  }

  // ---- store ----

  private func insert(_ candidate: Entry) {
    var entry = candidate
    if let index = self.entries.firstIndex(where: {
      $0.hash == entry.hash && $0.mimeType == entry.mimeType
    }) {
      // Duplicate: move the existing row to the front with a fresh id so
      // it sorts newest (upstream deletes + re-inserts on dedup), keeping
      // its pinned flag.
      var existing = self.entries.remove(at: index)
      existing.id = self.allocId()
      existing.timestamp = entry.timestamp
      self.entries.insert(existing, at: 0)
    } else {
      entry.id = self.allocId()
      entry.pinned = false
      self.entries.insert(entry, at: 0)
    }
    self.trim()
    self.persist()
    self.onStateChanged?()
  }

  private func allocId() -> UInt64 {
    let id = self.nextId
    self.nextId += 1
    return id
  }

  // Trim keeps at most maxHistory UNPINNED rows; pinned rows are exempt
  // (upstream stores them in a separate bucket).
  private func trim() {
    var unpinnedSeen = 0
    self.entries = self.entries.filter { entry in
      if entry.pinned { return true }
      unpinnedSeen += 1
      return unpinnedSeen <= self.config.maxHistory
    }
  }

  private func touch(id: UInt64) {
    guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
    var entry = self.entries.remove(at: index)
    entry.id = self.allocId()
    entry.timestamp = Date()
    self.entries.insert(entry, at: 0)
    self.persist()
    self.onStateChanged?()
  }

  private func setPinned(id: UInt64, _ pinned: Bool) -> (Any?, String?) {
    guard let index = self.entries.firstIndex(where: { $0.id == id }) else {
      return (nil, "entry not found")
    }
    if pinned && !self.entries[index].pinned {
      let count = self.entries.reduce(0) { $0 + ($1.pinned ? 1 : 0) }
      if count >= self.config.maxPinned {
        return (nil, "maximum pinned entries reached")
      }
    }
    self.entries[index].pinned = pinned
    self.persist()
    self.onStateChanged?()
    return (Self.success(pinned ? "entry pinned" : "entry unpinned"), nil)
  }

  private func storeRaw(_ data: Data, mimeType: String) {
    let isImage = mimeType.hasPrefix("image/")
    var entry = self.makeEntry(data: data, mimeType: mimeType, isImage: isImage)
    entry.hash = Self.fnv1a(data)
    self.writeToPasteboard(entry)
    self.insert(entry)
  }

  // ---- pasteboard writes ----
  //
  // After every write we snap lastChangeCount forward so the poller does not
  // re-capture our own write as a brand-new entry.

  private func writeText(_ text: String) {
    self.pasteboard.clearContents()
    self.pasteboard.setString(text, forType: .string)
    self.lastChangeCount = self.pasteboard.changeCount
  }

  private func writeToPasteboard(_ entry: Entry) {
    self.pasteboard.clearContents()
    if entry.isImage {
      self.pasteboard.setData(entry.data, forType: .png)
    } else {
      self.pasteboard.setString(String(decoding: entry.data, as: UTF8.self), forType: .string)
    }
    self.lastChangeCount = self.pasteboard.changeCount
  }

  private func writeFile(_ path: String) {
    let url = URL(fileURLWithPath: path)
    self.pasteboard.clearContents()
    self.pasteboard.writeObjects([url as NSURL])
    self.lastChangeCount = self.pasteboard.changeCount
  }

  // macOS paste is Cmd+V in every app including terminals, so the upstream
  // `shift` param (Ctrl+Shift+V for Linux terminals) is not needed here.
  // Requires the daemon to hold Accessibility trust; without it we report
  // pasteSupported=false and the shell falls back to copy-only.
  private func sendPasteKeystroke() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 0x09  // ANSI 'v'
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  // ---- request handling ----

  func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
    switch method {
    case "clipboard.getState":
      return (self.state(), nil)
    case "clipboard.getHistory":
      return (self.entries.map { self.entryDict($0, includeData: false) }, nil)
    case "clipboard.getEntry":
      guard let id = Self.uintParam(params, "id") else { return (nil, "missing param: id") }
      guard let entry = self.entries.first(where: { $0.id == id }) else { return (NSNull(), nil) }
      return (self.entryDict(entry, includeData: true), nil)
    case "clipboard.deleteEntry":
      guard let id = Self.uintParam(params, "id") else { return (nil, "missing param: id") }
      self.entries.removeAll { $0.id == id }
      self.persist()
      self.onStateChanged?()
      return (Self.success("entry deleted"), nil)
    case "clipboard.clearHistory":
      self.entries.removeAll { !$0.pinned }
      self.persist()
      self.onStateChanged?()
      return (Self.success("history cleared"), nil)
    case "clipboard.copy":
      guard let text = params["text"] as? String else { return (nil, "missing param: text") }
      self.writeText(text)
      return (Self.success("copied to clipboard"), nil)
    case "clipboard.copyEntry":
      guard let id = Self.uintParam(params, "id") else { return (nil, "missing param: id") }
      guard let entry = self.entries.first(where: { $0.id == id }) else {
        return (nil, "entry not found")
      }
      self.writeToPasteboard(entry)
      self.touch(id: id)
      return (Self.success("copied to clipboard"), nil)
    case "clipboard.paste":
      return (["text": self.pasteboard.string(forType: .string) ?? ""], nil)
    case "clipboard.sendPaste":
      guard self.sendPasteKeystroke() else {
        return (nil, "paste not permitted: grant Accessibility to dms-darwin")
      }
      return (Self.success("paste sent"), nil)
    case "clipboard.pasteSupported":
      return (["supported": AXIsProcessTrusted()], nil)
    case "clipboard.search":
      return (self.search(params), nil)
    case "clipboard.getConfig":
      return (self.configDict(), nil)
    case "clipboard.setConfig":
      self.applyConfig(params)
      self.persistConfig()
      self.trim()
      self.persist()
      self.onStateChanged?()
      return (Self.success("config updated"), nil)
    case "clipboard.store":
      guard let data = params["data"] as? String else { return (nil, "missing param: data") }
      let mime = params["mimeType"] as? String ?? "text/plain;charset=utf-8"
      self.storeRaw(Data(data.utf8), mimeType: mime)
      return (Self.success("stored"), nil)
    case "clipboard.pinEntry":
      guard let id = Self.uintParam(params, "id") else { return (nil, "missing param: id") }
      return self.setPinned(id: id, true)
    case "clipboard.unpinEntry":
      guard let id = Self.uintParam(params, "id") else { return (nil, "missing param: id") }
      return self.setPinned(id: id, false)
    case "clipboard.getPinnedEntries":
      return (self.entries.filter { $0.pinned }.map { self.entryDict($0, includeData: false) }, nil)
    case "clipboard.getPinnedCount":
      return (["count": self.entries.reduce(0) { $0 + ($1.pinned ? 1 : 0) }], nil)
    case "clipboard.copyFile":
      guard let path = params["filePath"] as? String else {
        return (nil, "missing param: filePath")
      }
      self.writeFile(path)
      return (Self.success("copied"), nil)
    default:
      return (nil, "unknown method: \(method)")
    }
  }

  private func search(_ params: [String: Any]) -> [String: Any] {
    let query = (params["query"] as? String ?? "").lowercased()
    let mimeType = params["mimeType"] as? String ?? ""
    let isImage = params["isImage"] as? Bool
    let limit = Self.intParam(params, "limit", 50)
    let offset = max(0, Self.intParam(params, "offset", 0))

    let matched = self.entries.filter { entry in
      if !query.isEmpty && !entry.preview.lowercased().contains(query) { return false }
      if !mimeType.isEmpty && entry.mimeType != mimeType { return false }
      if let wantImage = isImage, entry.isImage != wantImage { return false }
      return true
    }
    let total = matched.count
    let page = offset < matched.count ? Array(matched[offset...]) : []
    let hasMore = page.count > limit
    let limited = page.count > limit ? Array(page.prefix(limit)) : page
    return [
      "entries": limited.map { self.entryDict($0, includeData: false) },
      "total": total,
      "hasMore": hasMore,
    ]
  }

  // ---- state / serialization ----

  func state() -> [String: Any] {
    [
      "enabled": !self.config.disabled,
      "history": self.entries.map { self.entryDict($0, includeData: false) },
    ]
  }

  private func entryDict(_ entry: Entry, includeData: Bool) -> [String: Any] {
    var dict: [String: Any] = [
      "id": entry.id,
      "mimeType": entry.mimeType,
      "preview": entry.preview,
      "size": entry.size,
      "timestamp": self.iso.string(from: entry.timestamp),
      "isImage": entry.isImage,
      "hash": entry.hash,
      "pinned": entry.pinned,
    ]
    if includeData && !entry.data.isEmpty {
      dict["data"] = entry.data.base64EncodedString()
    }
    return dict
  }

  private func configDict() -> [String: Any] {
    [
      "maxHistory": self.config.maxHistory,
      "maxEntrySize": self.config.maxEntrySize,
      "autoClearDays": self.config.autoClearDays,
      "clearAtStartup": self.config.clearAtStartup,
      "disabled": self.config.disabled,
      "maxPinned": self.config.maxPinned,
    ]
  }

  private func applyConfig(_ params: [String: Any]) {
    if let value = params["maxHistory"] as? Int { self.config.maxHistory = value }
    if let value = params["maxEntrySize"] as? Int { self.config.maxEntrySize = value }
    if let value = params["maxEntrySize"] as? Double { self.config.maxEntrySize = Int(value) }
    if let value = params["autoClearDays"] as? Int { self.config.autoClearDays = value }
    if let value = params["clearAtStartup"] as? Bool { self.config.clearAtStartup = value }
    if let value = params["disabled"] as? Bool { self.config.disabled = value }
    if let value = params["maxPinned"] as? Int { self.config.maxPinned = value }
  }

  // ---- helpers ----

  private static func success(_ message: String) -> [String: Any] {
    ["success": true, "message": message]
  }

  private static func uintParam(_ params: [String: Any], _ key: String) -> UInt64? {
    if let value = params[key] as? Int { return UInt64(exactly: value) }
    if let value = params[key] as? Double { return UInt64(exactly: value.rounded()) }
    if let value = params[key] as? UInt64 { return value }
    return nil
  }

  private static func intParam(_ params: [String: Any], _ key: String, _ fallback: Int) -> Int {
    if let value = params[key] as? Int { return value }
    if let value = params[key] as? Double { return Int(value) }
    return fallback
  }

  static func textPreview(_ data: Data) -> String {
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count <= 200 { return text }
    return String(text.prefix(200))
  }

  static func imagePreview(_ data: Data) -> String {
    let kib = (data.count + 1023) / 1024
    return "image/png (\(kib) KiB)"
  }

  // FNV-1a 64-bit, upstream's dedup key is a 64-bit content hash too.
  static func fnv1a(_ data: Data) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
  }

  // ---- persistence ----

  private struct StoredEntry: Codable {
    var id: UInt64
    var data: Data
    var mimeType: String
    var preview: String
    var size: Int
    var timestamp: Date
    var isImage: Bool
    var hash: UInt64
    var pinned: Bool
  }
  private struct StoredState: Codable {
    var nextId: UInt64
    var entries: [StoredEntry]
  }

  private var supportDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("DankMaterialShell", isDirectory: true)
  }
  private var storePath: URL { self.supportDir.appendingPathComponent("clipboard-darwin.json") }
  private var configPath: URL { self.supportDir.appendingPathComponent("clsettings.json") }

  private func persist() {
    let stored = StoredState(
      nextId: self.nextId,
      entries: self.entries.map {
        StoredEntry(
          id: $0.id, data: $0.data, mimeType: $0.mimeType, preview: $0.preview,
          size: $0.size, timestamp: $0.timestamp, isImage: $0.isImage, hash: $0.hash,
          pinned: $0.pinned)
      })
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(stored) else { return }
    try? FileManager.default.createDirectory(
      at: self.supportDir, withIntermediateDirectories: true)
    try? data.write(to: self.storePath, options: .atomic)
  }

  private func loadStore() {
    guard let data = try? Data(contentsOf: self.storePath) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let stored = try? decoder.decode(StoredState.self, from: data) else { return }
    self.nextId = max(stored.nextId, 1)
    self.entries = stored.entries.map {
      Entry(
        id: $0.id, data: $0.data, mimeType: $0.mimeType, preview: $0.preview,
        size: $0.size, timestamp: $0.timestamp, isImage: $0.isImage, hash: $0.hash,
        pinned: $0.pinned)
    }
  }

  private func loadConfig() {
    guard let data = try? Data(contentsOf: self.configPath),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    self.applyConfig(object)
  }

  private func persistConfig() {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: self.configDict(), options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? FileManager.default.createDirectory(
      at: self.supportDir, withIntermediateDirectories: true)
    try? data.write(to: self.configPath, options: .atomic)
  }
}
