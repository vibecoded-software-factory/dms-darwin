import Foundation

// The `wayland.gamma.*` channel: the shell's night-mode protocol, shapes and
// behavior mirrored from the upstream Go daemon's wayland/gamma service,
// backed by Night Shift.
//
// Scheduling parity: three modes, resolved exactly like upstream -
//   manual sunrise/sunset  -> fixed schedule (1h twilight flanks)
//   location (explicit or IP-geolocated via ip-api.com, same provider)
//                          -> solar schedule (suncalc port, Solar.swift)
//   neither                -> static: position 1.0 / HighTemp (the shell's
//                             manual toggle sets low == high)
// The temperature follows the sun position continuously (gradual dawn/dusk
// transitions, same interpolation as upstream). A one-minute idempotent tick
// evaluates "what should the panel be right now" - simpler than deadline
// timers and immune to sleep/wake clock jumps by construction.
final class GammaChannel {
    private let nightShift = NightShiftService()

    // Config, mirroring upstream's (JSON keys match what the shell reads).
    private var enabled = false
    private var lowTemp = 4000.0
    private var highTemp = 6500.0
    private var latitude: Double?
    private var longitude: Double?
    private var useIPLocation = false
    private var manualSunrise: (hour: Int, minute: Int)?
    private var manualSunset: (hour: Int, minute: Int)?
    private var manualSunriseRaw: String?
    private var manualSunsetRaw: String?
    private var gammaValue = 1.0

    // IP-geolocated coordinates, kept apart from explicit ones; enabling IP
    // lookup wipes the explicit pair (upstream semantics), so only one pair
    // is ever populated.
    private var ipLatitude: Double?
    private var ipLongitude: Double?
    private var ipFetchInFlight = false

    private var tick: DispatchSourceTimer?
    private var lastAppliedTemp: Int?
    private var lastAppliedEnabled: Bool?

    // The server hooks this to push fresh state to subscribers whenever the
    // schedule moves the temperature on its own.
    var onStateChanged: (() -> Void)?

    var available: Bool { self.nightShift.available }

    init() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.evaluate(broadcast: true) }
        timer.resume()
        self.tick = timer
    }

    // ---- schedule resolution ----

    private func effectiveCoordinates() -> (lat: Double, lon: Double)? {
        if let lat = self.latitude, let lon = self.longitude { return (lat, lon) }
        if self.useIPLocation, let lat = self.ipLatitude, let lon = self.ipLongitude {
            return (lat, lon)
        }
        return nil
    }

    private func currentSchedule(now: Date) -> Solar.SunTimes? {
        if let sunrise = self.manualSunrise, let sunset = self.manualSunset {
            return Solar.manualTimes(sunrise: sunrise, sunset: sunset, now: now)
        }
        if let coords = self.effectiveCoordinates() {
            return Solar.calculate(lat: coords.lat, lon: coords.lon, date: now).times
        }
        return nil
    }

    private func currentPositionAndTemp(now: Date) -> (position: Double, temp: Int) {
        guard let times = self.currentSchedule(now: now) else {
            // No schedule: upstream reports position 1.0 and HighTemp
            // regardless of Enabled (the shell's manual toggle sets
            // low == high, so the applied value is the requested one).
            return (1.0, Int(self.highTemp))
        }
        let position = Solar.position(now: now, times: times)
        return (position, Solar.temperature(position: position, low: self.lowTemp, high: self.highTemp))
    }

    // ---- application ----

    private func evaluate(broadcast: Bool) {
        let now = Date()
        let targetTemp = self.enabled ? self.currentPositionAndTemp(now: now).temp : Int(GammaMath.neutralTemp)
        let strength = GammaMath.strength(forTemp: Double(targetTemp))
        let wantOn = self.enabled && strength > 0.005

        let changed = self.lastAppliedTemp != targetTemp || self.lastAppliedEnabled != wantOn
        guard changed else { return }
        self.lastAppliedTemp = targetTemp
        self.lastAppliedEnabled = wantOn

        if wantOn {
            _ = self.nightShift.setEnabled(true)
            _ = self.nightShift.setStrength(strength)
        } else {
            _ = self.nightShift.setEnabled(false)
        }
        if broadcast { self.onStateChanged?() }
    }

    // ---- geolocation (ip-api.com, the same provider upstream uses) ----

    private func fetchIPLocationIfNeeded() {
        guard self.useIPLocation, self.ipLatitude == nil, !self.ipFetchInFlight else { return }
        guard let url = URL(string: "http://ip-api.com/json/") else { return }
        self.ipFetchInFlight = true
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ipFetchInFlight = false
                guard let data,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    object["status"] as? String == "success",
                    let lat = object["lat"] as? Double, let lon = object["lon"] as? Double
                else {
                    print("[gamma] ip-api.com geolocation failed")
                    return
                }
                self.ipLatitude = lat
                self.ipLongitude = lon
                print("[gamma] ip location: \(lat), \(lon)")
                self.evaluate(broadcast: true)
            }
        }.resume()
    }

    // ---- state ----

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func timeString(_ date: Date?) -> String {
        date.map { iso.string(from: $0) } ?? ""
    }

    func state() -> [String: Any] {
        let now = Date()
        let times = self.currentSchedule(now: now)
        let (position, scheduledTemp) = self.currentPositionAndTemp(now: now)
        let isDay = times.map { Solar.isDay(now: now, times: $0) } ?? true
        // Upstream: next of the schedule's boundaries, or tomorrow when
        // there is no schedule.
        let nextTransition: Date? =
            times.flatMap { t in
                [t.dawn, t.sunrise, t.sunset, t.night].first { $0 > now }
            } ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))
        return [
            "config": [
                "Outputs": [],
                "LowTemp": self.lowTemp,
                "HighTemp": self.highTemp,
                "Latitude": self.latitude as Any,
                "Longitude": self.longitude as Any,
                "UseIPLocation": self.useIPLocation,
                "ManualSunrise": self.manualSunriseRaw as Any,
                "ManualSunset": self.manualSunsetRaw as Any,
                "Gamma": self.gammaValue,
                "Enabled": self.enabled,
            ],
            "currentTemp": self.enabled ? scheduledTemp : Int(GammaMath.neutralTemp),
            "isDay": isDay,
            "sunriseTime": Self.timeString(times?.sunrise),
            "sunsetTime": Self.timeString(times?.sunset),
            "dawnTime": Self.timeString(times?.dawn),
            "nightTime": Self.timeString(times?.night),
            "nextTransition": Self.timeString(nextTransition),
            "sunPosition": position,
        ]
    }

    // ---- methods ----

    private static func parseClock(_ value: Any?) -> (raw: String, time: (hour: Int, minute: Int))? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        return (raw, (hour, minute))
    }

    // Returns (result, error); both nil means "unknown method". Mutations
    // answer {success, message} like upstream's SuccessResult.
    func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
        switch method {
        case "wayland.gamma.getState":
            return (self.state(), nil)
        case "wayland.gamma.setEnabled":
            self.enabled = params["enabled"] as? Bool ?? false
            self.fetchIPLocationIfNeeded()
            self.evaluate(broadcast: false)
            return (["success": true, "message": "enabled state set"], nil)
        case "wayland.gamma.setTemperature":
            let low: Double
            let high: Double
            if let temp = Self.number(params["temp"]) {
                low = temp
                high = temp
            } else if let lowParam = Self.number(params["low"]),
                let highParam = Self.number(params["high"])
            {
                low = lowParam
                high = highParam
            } else {
                return (nil, "missing temperature parameters (provide 'temp' or both 'low' and 'high')")
            }
            guard low >= 1000 && low <= 10000 && high >= 1000 && high <= 10000 else {
                return (nil, "temperature must be between 1000 and 10000")
            }
            guard low <= high else {
                return (nil, "low temperature must not exceed high temperature")
            }
            self.lowTemp = low
            self.highTemp = high
            self.evaluate(broadcast: false)
            return (["success": true, "message": "temperature set"], nil)
        case "wayland.gamma.setLocation":
            guard let latitude = Self.number(params["latitude"]),
                let longitude = Self.number(params["longitude"])
            else {
                return (nil, "missing param: latitude/longitude")
            }
            self.latitude = latitude
            self.longitude = longitude
            // Upstream: an explicit location turns IP-based lookup off.
            self.useIPLocation = false
            self.evaluate(broadcast: false)
            return (["success": true, "message": "location set"], nil)
        case "wayland.gamma.setManualTimes":
            if let sunrise = Self.parseClock(params["sunrise"]),
                let sunset = Self.parseClock(params["sunset"])
            {
                self.manualSunrise = sunrise.time
                self.manualSunset = sunset.time
                self.manualSunriseRaw = sunrise.raw
                self.manualSunsetRaw = sunset.raw
                self.evaluate(broadcast: false)
                return (["success": true, "message": "manual times set"], nil)
            }
            self.manualSunrise = nil
            self.manualSunset = nil
            self.manualSunriseRaw = nil
            self.manualSunsetRaw = nil
            self.evaluate(broadcast: false)
            return (["success": true, "message": "manual times cleared"], nil)
        case "wayland.gamma.setUseIPLocation":
            self.useIPLocation = params["use"] as? Bool ?? false
            if self.useIPLocation {
                // Upstream: enabling IP lookup wipes the explicit location
                // and flushes the cached fix, so the IP result actually
                // drives the schedule (stale fixed coords must not win).
                self.latitude = nil
                self.longitude = nil
                self.ipLatitude = nil
                self.ipLongitude = nil
            }
            self.fetchIPLocationIfNeeded()
            self.evaluate(broadcast: false)
            return (["success": true, "message": "IP location preference set"], nil)
        case "wayland.gamma.setGamma":
            if let gamma = Self.number(params["gamma"]) { self.gammaValue = gamma }
            return (["success": true, "message": "gamma set"], nil)
        default:
            return (nil, nil)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
