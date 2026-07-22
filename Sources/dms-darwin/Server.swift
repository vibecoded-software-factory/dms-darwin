import Foundation

// The daemon's unix-socket server: accepts connections, reads JSON lines,
// answers requests and streams subscription events - the darwin stand-in for
// the upstream Go daemon DankMaterialShell talks to over $DMS_SOCKET.
//
// Single-threaded on the main queue (the shell is one client with two
// connections; there is nothing to parallelize), GCD read sources per
// connection, nigiri's MsgServer discipline: a dead client is dropped,
// never allowed to wedge the loop.
final class Server {
    static let apiVersion = 1
    static let cliVersion = "dms-darwin 0.1.0"

    private let socketPath: String
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private let brightness = BrightnessService()
    // Last state pushed to subscribers, for the poll-driven change detection
    // (the hardware brightness keys change the panel outside our socket).
    private var lastBrightnessPercent: Int?
    private var pollTimer: DispatchSourceTimer?

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        // A connection becomes a subscriber when it sends `subscribe`; from
        // then on it receives event pushes for these services ([] = all).
        var subscribedServices: [String]? = nil

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }

        func wants(_ service: String) -> Bool {
            guard let services = self.subscribedServices else { return false }
            return services.isEmpty || services.contains(service)
        }
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    var capabilities: [String] {
        var caps: [String] = []
        if self.brightness.available { caps.append("brightness") }
        return caps
    }

    func start() -> Bool {
        unlink(self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(self.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }

        self.listenFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        self.acceptSource = source

        // Poll for out-of-band brightness changes (the keyboard keys, auto
        // brightness). 2s is imperceptible for a slider and costs nothing.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.pollBrightness() }
        timer.resume()
        self.pollTimer = timer

        print("[server] listening on \(self.socketPath) capabilities=\(self.capabilities)")
        return true
    }

    private func acceptConnection() {
        let fd = accept(self.listenFd, nil, nil)
        guard fd >= 0 else { return }
        // A stalled client must never block the daemon in write().
        var flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        flags = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flags, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        let connection = Connection(fd: fd, source: source)
        self.connections[fd] = connection
        source.setEventHandler { [weak self] in self?.readFrom(connection) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func dropConnection(_ connection: Connection) {
        self.connections.removeValue(forKey: connection.fd)
        connection.source.cancel()
    }

    private func readFrom(_ connection: Connection) {
        var scratch = [UInt8](repeating: 0, count: 65536)
        let count = read(connection.fd, &scratch, scratch.count)
        if count <= 0 {
            self.dropConnection(connection)
            return
        }
        connection.buffer.append(contentsOf: scratch[0..<count])
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer.prefix(upTo: newline)
            connection.buffer.removeSubrange(...newline)
            if !line.isEmpty { self.handleLine(Data(line), from: connection) }
        }
    }

    private func send(_ data: Data, to connection: Connection) {
        let sent = data.withUnsafeBytes { raw in
            write(connection.fd, raw.baseAddress, raw.count)
        }
        // Best-effort: a client too slow to take an event gets dropped, the
        // same policy as the compositor's event stream.
        if sent < 0 && errno != EAGAIN { self.dropConnection(connection) }
    }

    private func broadcast(service: String, data: Any) {
        let line = Wire.event(service: service, data: data)
        for connection in self.connections.values where connection.wants(service) {
            self.send(line, to: connection)
        }
    }

    private func handleLine(_ line: Data, from connection: Connection) {
        guard let request = Wire.Request.parse(line) else {
            self.send(Wire.error(id: nil, "malformed request"), to: connection)
            return
        }

        switch request.method {
        case "subscribe":
            connection.subscribedServices = request.params["services"] as? [String] ?? []
            // Handshake first - the shell gates every feature on it - then
            // the current state of everything subscribed.
            self.send(
                Wire.event(
                    service: "server",
                    data: [
                        "apiVersion": Self.apiVersion,
                        "cliVersion": Self.cliVersion,
                        "capabilities": self.capabilities,
                    ]), to: connection)
            if connection.wants("brightness"), self.brightness.available {
                self.send(
                    Wire.event(service: "brightness", data: self.brightness.state()),
                    to: connection)
            }
        case "ping":
            self.send(Wire.response(id: request.id, result: "pong"), to: connection)
        case let method where method.hasPrefix("brightness."):
            self.handleBrightness(request, from: connection)
        default:
            self.send(
                Wire.error(id: request.id, "unknown method: \(request.method)"), to: connection)
        }
    }

    // ---- brightness ----
    //
    // Method set and response shapes mirror the upstream handlers verbatim:
    // every mutation answers with the full State and pushes it to
    // subscribers.

    private func handleBrightness(_ request: Wire.Request, from connection: Connection) {
        guard self.brightness.available else {
            self.send(Wire.error(id: request.id, "no brightness devices"), to: connection)
            return
        }

        func respondState() {
            let state = self.brightness.state()
            self.send(Wire.response(id: request.id, result: state), to: connection)
            self.lastBrightnessPercent = self.brightness.currentPercent()
            self.broadcast(service: "brightness", data: state)
        }

        switch request.method {
        case "brightness.getState", "brightness.rescan":
            self.send(
                Wire.response(id: request.id, result: self.brightness.state()), to: connection)
        case "brightness.setBrightness":
            guard let percent = request.params["percent"] as? Int else {
                self.send(Wire.error(id: request.id, "missing param: percent"), to: connection)
                return
            }
            let exponential = request.params["exponential"] as? Bool ?? false
            let exponent = request.params["exponent"] as? Double ?? 1.2
            guard self.brightness.set(percent: percent, exponential: exponential, exponent: exponent)
            else {
                self.send(Wire.error(id: request.id, "set failed"), to: connection)
                return
            }
            respondState()
        case "brightness.increment", "brightness.decrement":
            let step = request.params["step"] as? Int ?? 10
            let signed = request.method.hasSuffix("increment") ? step : -step
            let current = self.brightness.currentPercent() ?? 0
            let target = min(100, max(0, current + signed))
            let exponential = request.params["exponential"] as? Bool ?? false
            let exponent = request.params["exponent"] as? Double ?? 1.2
            guard self.brightness.set(percent: target, exponential: exponential, exponent: exponent)
            else {
                self.send(Wire.error(id: request.id, "set failed"), to: connection)
                return
            }
            respondState()
        default:
            self.send(
                Wire.error(id: request.id, "unknown method: \(request.method)"), to: connection)
        }
    }

    // The hardware brightness keys and auto-brightness change the panel
    // behind our back; poll and push so the shell's slider follows.
    private func pollBrightness() {
        guard self.brightness.available else { return }
        let percent = self.brightness.currentPercent()
        guard percent != self.lastBrightnessPercent else { return }
        self.lastBrightnessPercent = percent
        self.broadcast(service: "brightness", data: self.brightness.state())
    }
}
