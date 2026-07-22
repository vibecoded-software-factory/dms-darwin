import Foundation

// Pure-logic checks, nigiri-style: `dms-darwin selftest` exits non-zero on
// the first failure. Everything socket-free lives here.
enum SelfTest {
    private static var checks = 0
    private static var failed = false

    private static func expect(_ condition: Bool, _ what: String) {
        checks += 1
        if !condition {
            failed = true
            print("FAIL: \(what)")
        }
    }

    static func run() -> Int32 {
        // Wire parsing: the exact lines DMSService.qml sends.
        let request = Wire.Request.parse(
            Data(#"{"id": 7, "method": "brightness.setBrightness", "params": {"device": "builtin", "percent": 40}}"#.utf8))
        expect(request != nil, "a request line parses")
        expect(request?.id == 7, "id survives")
        expect(request?.method == "brightness.setBrightness", "method survives")
        expect(request?.params["percent"] as? Int == 40, "params survive")

        let subscribe = Wire.Request.parse(
            Data(#"{"method": "subscribe", "params": {"clientId": "x"}}"#.utf8))
        expect(subscribe?.id == nil, "subscribe carries no id")

        expect(Wire.Request.parse(Data("not json\n".utf8)) == nil, "garbage is rejected")

        // Wire serialization round-trips through JSON.
        let event = Wire.event(service: "brightness", data: ["devices": []])
        let parsed = try? JSONSerialization.jsonObject(with: event) as? [String: Any]
        let result = parsed?["result"] as? [String: Any]
        expect(result?["service"] as? String == "brightness", "event carries its service")

        let error = Wire.error(id: 3, "nope")
        let parsedError = try? JSONSerialization.jsonObject(with: error) as? [String: Any]
        expect(parsedError?["error"] as? String == "nope", "errors carry their message")
        expect(parsedError?["id"] as? Int == 3, "errors carry the request id")

        // The perceptual curve, mirroring upstream's exponential option.
        expect(
            BrightnessCurve.hardwareLevel(percent: 100, exponential: false, exponent: 1.2) == 1.0,
            "100% linear is full")
        expect(
            BrightnessCurve.hardwareLevel(percent: 0, exponential: true, exponent: 1.2) == 0.0,
            "0% is off under any curve")
        let mid = BrightnessCurve.hardwareLevel(percent: 50, exponential: true, exponent: 2.0)
        expect(abs(mid - 0.25) < 0.0001, "50% at exponent 2 is a quarter of the range")
        expect(
            BrightnessCurve.hardwareLevel(percent: 140, exponential: false, exponent: 1) == 1.0,
            "over-range clamps high")
        expect(
            BrightnessCurve.hardwareLevel(percent: -3, exponential: false, exponent: 1) == 0.0,
            "under-range clamps low")

        print("selftest: \(checks) checks, \(failed ? "FAILURES above" : "all OK")")
        return failed ? 1 : 0
    }
}
