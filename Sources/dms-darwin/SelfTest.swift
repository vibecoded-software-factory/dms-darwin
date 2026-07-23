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

        // Temperature -> Night Shift strength mapping (documented linear
        // approximation between 6500K neutral and 2700K warmest).
        expect(GammaMath.strength(forTemp: 6500) == 0.0, "neutral temp is strength 0")
        expect(GammaMath.strength(forTemp: 2700) == 1.0, "warmest temp is full strength")
        expect(abs(GammaMath.strength(forTemp: 4600) - 0.5) < 0.001, "midpoint lands mid-strength")
        expect(GammaMath.strength(forTemp: 9000) == 0.0, "over-neutral clamps to 0")
        expect(GammaMath.strength(forTemp: 1000) == 1.0, "under-warmest clamps to 1")

        // Solar schedule math, pinned against known sky behavior.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
            utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }

        // Equator at the March equinox: sunrise near 06:00 UTC, sunset near
        // 18:00, and the phases strictly ordered.
        let equinox = Solar.calculate(lat: 0, lon: 0, date: date(2026, 3, 20))
        expect(equinox.condition == .normal, "equator equinox is a normal day")
        let t = equinox.times
        expect(
            t.dawn < t.sunrise && t.sunrise < t.sunset && t.sunset < t.night,
            "solar phases are ordered")
        let sunriseHour = utc.component(.hour, from: t.sunrise)
        let sunsetHour = utc.component(.hour, from: t.sunset)
        expect((5...7).contains(sunriseHour), "equinox sunrise near 06:00 UTC (got \(sunriseHour))")
        expect((17...19).contains(sunsetHour), "equinox sunset near 18:00 UTC (got \(sunsetHour))")

        // Longitude shifts solar time 4 minutes per degree westward.
        let west = Solar.calculate(lat: 0, lon: -60, date: date(2026, 3, 20))
        let shift = west.times.sunrise.timeIntervalSince(t.sunrise)
        expect(abs(shift - 60 * 4 * 60) < 60, "60 degrees west shifts sunrise by 4 hours")

        // Polar clamps.
        let polarNight = Solar.calculate(lat: 80, lon: 0, date: date(2026, 12, 21))
        expect(polarNight.condition == .polarNight, "arctic December is polar night")
        expect(polarNight.times.sunrise == polarNight.times.sunset, "polar night has no day")
        let midnightSun = Solar.calculate(lat: 80, lon: 0, date: date(2026, 6, 21))
        expect(midnightSun.condition == .midnightSun, "arctic June is midnight sun")
        expect(
            midnightSun.times.sunset.timeIntervalSince(midnightSun.times.sunrise) > 23 * 3600,
            "midnight sun spans the day")

        // Manual times: hour flanks, and a sunset "before" sunrise is next-day.
        let manual = Solar.manualTimes(
            sunrise: (7, 0), sunset: (19, 0), now: date(2026, 7, 22), calendar: utc)
        expect(
            manual.sunrise.timeIntervalSince(manual.dawn) == 3600, "dawn is an hour before sunrise")
        expect(
            manual.night.timeIntervalSince(manual.sunset) == 3600, "night is an hour after sunset")
        expect(manual.sunset.timeIntervalSince(manual.sunrise) == 12 * 3600, "manual day is 12h")
        let overnight = Solar.manualTimes(
            sunrise: (7, 0), sunset: (1, 0), now: date(2026, 7, 22), calendar: utc)
        expect(
            overnight.sunset.timeIntervalSince(overnight.sunrise) == 18 * 3600,
            "sunset at or before sunrise rolls to the next day")

        // Sun position: 0 at night, linear ramps through twilight, 1 by day.
        expect(Solar.position(now: date(2026, 7, 22, 3), times: manual) == 0.0, "night is 0")
        expect(Solar.position(now: date(2026, 7, 22, 6, 30), times: manual) == 0.5, "mid-dawn is 0.5")
        expect(Solar.position(now: date(2026, 7, 22, 12), times: manual) == 1.0, "midday is 1")
        expect(Solar.position(now: date(2026, 7, 22, 19, 30), times: manual) == 0.5, "mid-dusk is 0.5")
        expect(Solar.position(now: date(2026, 7, 22, 21), times: manual) == 0.0, "after night is 0")

        // Temperature interpolation, upstream's low + (high-low)*pos.
        expect(Solar.temperature(position: 0.0, low: 4000, high: 6500) == 4000, "night temp is low")
        expect(Solar.temperature(position: 1.0, low: 4000, high: 6500) == 6500, "day temp is high")
        expect(
            Solar.temperature(position: 0.5, low: 4000, high: 6500) == 5250, "mid temp interpolates")
        expect(
            Solar.interpolate(now: date(2026, 1, 1), start: date(2026, 1, 1), stop: date(2026, 1, 1))
                == 1.0, "degenerate interpolation is 1")

        print("selftest: \(checks) checks, \(failed ? "FAILURES above" : "all OK")")
        return failed ? 1 : 0
    }
}
