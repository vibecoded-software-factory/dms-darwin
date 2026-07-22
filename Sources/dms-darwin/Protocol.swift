import Foundation

// The DMS daemon wire protocol, as spoken by DankMaterialShell's
// DMSService.qml and implemented by the upstream Go daemon (core/): JSON
// objects, one per line, over a unix socket at $DMS_SOCKET.
//
//   request socket:    {"id": N, "method": "svc.name", "params": {...}}
//                   -> {"id": N, "result": ...} | {"id": N, "error": "..."}
//   subscribe socket:  {"method": "subscribe", "params": {"clientId": "...",
//                       "services": [...]?}}
//                   -> stream of {"result": {"service": "...", "data": ...}}
//
// The first pushed event is service "server" carrying {apiVersion,
// cliVersion, capabilities} - the handshake the shell gates its features on.
// Pure: parsing/serialization only, so the selftest can cover it without a
// socket.
enum Wire {
    struct Request {
        let id: Int?
        let method: String
        let params: [String: Any]

        static func parse(_ line: Data) -> Request? {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let method = object["method"] as? String
            else { return nil }
            return Request(
                id: object["id"] as? Int,
                method: method,
                params: object["params"] as? [String: Any] ?? [:])
        }
    }

    static func jsonLine(_ object: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return Data("{}\n".utf8) }
        return data + Data("\n".utf8)
    }

    static func response(id: Int?, result: Any) -> Data {
        jsonLine(["id": id as Any, "result": result])
    }

    static func error(id: Int?, _ message: String) -> Data {
        jsonLine(["id": id as Any, "error": message])
    }

    // A subscription push: what the shell's subscribe socket receives.
    static func event(service: String, data: Any) -> Data {
        jsonLine(["result": ["service": service, "data": data]])
    }
}

// Perceptual brightness mapping, verbatim from the upstream daemon's
// exponential option: the shell sends percent plus an exponent, and the
// hardware value is (percent/100)^exponent. Pure for the selftest.
enum BrightnessCurve {
    static func hardwareLevel(percent: Int, exponential: Bool, exponent: Double) -> Double {
        let clamped = Double(min(100, max(0, percent))) / 100.0
        guard exponential, exponent > 0 else { return clamped }
        return pow(clamped, exponent)
    }
}
