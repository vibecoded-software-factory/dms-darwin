import Foundation

// The `wayland.gamma.*` channel: the shell's night-mode protocol, shaped
// verbatim after the upstream Go daemon's wayland/gamma service (State,
// Config and method set), backed here by Night Shift.
//
// v1 scope: the shell's MANUAL path - toggle + temperature. The automation
// fields (location, manual sunrise/sunset, IP location) are stored and
// echoed in state so the shell's UI stays coherent, but scheduling stays
// with the shell/daemon future work; only `enabled` + the temperatures act
// on the panel today.
final class GammaChannel {
    private let nightShift = NightShiftService()

    // Mirrors upstream Config (wayland/types.go); JSON keys match what
    // DisplayService.qml reads (gammaState.config.LowTemp etc.).
    private var enabled = false
    private var lowTemp = 4000.0
    private var highTemp = 6500.0
    private var latitude: Double?
    private var longitude: Double?
    private var useIPLocation = false
    private var manualSunrise: String?
    private var manualSunset: String?
    private var gammaValue = 1.0

    var available: Bool { self.nightShift.available }

    func state() -> [String: Any] {
        [
            "config": [
                "Outputs": [],
                "LowTemp": self.lowTemp,
                "HighTemp": self.highTemp,
                "Latitude": self.latitude as Any,
                "Longitude": self.longitude as Any,
                "UseIPLocation": self.useIPLocation,
                "ManualSunrise": self.manualSunrise as Any,
                "ManualSunset": self.manualSunset as Any,
                "Gamma": self.gammaValue,
                "Enabled": self.enabled,
            ],
            "currentTemp": Int(self.enabled ? self.lowTemp : GammaMath.neutralTemp),
            "isDay": !self.enabled,
            "sunriseTime": "", "sunsetTime": "", "dawnTime": "", "nightTime": "",
            "nextTransition": "", "sunPosition": 0,
        ]
    }

    private func apply() {
        if self.enabled {
            self.nightShift.setEnabled(true)
            self.nightShift.setStrength(GammaMath.strength(forTemp: self.lowTemp))
        } else {
            self.nightShift.setEnabled(false)
        }
    }

    // Returns the response payload, or nil for "unknown method". Mutations
    // answer {success, message} like upstream's SuccessResult.
    func handle(method: String, params: [String: Any]) -> Any? {
        switch method {
        case "wayland.gamma.getState":
            return self.state()
        case "wayland.gamma.setEnabled":
            self.enabled = params["enabled"] as? Bool ?? false
            self.apply()
            return ["success": true, "message": ""]
        case "wayland.gamma.setTemperature":
            if let temp = Self.number(params["temp"]) {
                self.lowTemp = temp
                self.highTemp = temp
            } else {
                if let low = Self.number(params["low"]) { self.lowTemp = low }
                if let high = Self.number(params["high"]) { self.highTemp = high }
            }
            self.apply()
            return ["success": true, "message": ""]
        case "wayland.gamma.setLocation":
            self.latitude = Self.number(params["latitude"])
            self.longitude = Self.number(params["longitude"])
            return ["success": true, "message": ""]
        case "wayland.gamma.setManualTimes":
            self.manualSunrise = params["sunrise"] as? String
            self.manualSunset = params["sunset"] as? String
            return ["success": true, "message": ""]
        case "wayland.gamma.setUseIPLocation":
            self.useIPLocation = params["use"] as? Bool ?? false
            return ["success": true, "message": ""]
        case "wayland.gamma.setGamma":
            if let gamma = Self.number(params["gamma"]) { self.gammaValue = gamma }
            return ["success": true, "message": ""]
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
