import CoreGraphics
import Foundation

// Brightness backend for the built-in display, through the private
// DisplayServices framework (the same calls Control Center makes). Loaded
// with dlopen so a missing framework degrades to "no devices" instead of a
// link failure - external DDC displays are a later backend.
//
// Device shape mirrors the upstream daemon's brightness.Device verbatim:
// {class, id, name, current, max, currentPercent, backend}.
final class BrightnessService {
    typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    static let deviceId = "builtin"

    init() {
        let path =
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            self.getBrightness = nil
            self.setBrightness = nil
            return
        }
        self.getBrightness = dlsym(handle, "DisplayServicesGetBrightness").map {
            unsafeBitCast($0, to: GetBrightness.self)
        }
        self.setBrightness = dlsym(handle, "DisplayServicesSetBrightness").map {
            unsafeBitCast($0, to: SetBrightness.self)
        }
    }

    var available: Bool {
        self.getBrightness != nil && self.setBrightness != nil && self.currentPercent() != nil
    }

    // The built-in display's brightness as 0-100, or nil when there is no
    // controllable panel (external-only setups, framework missing).
    func currentPercent() -> Int? {
        guard let get = self.getBrightness else { return nil }
        var value: Float = 0
        guard get(CGMainDisplayID(), &value) == 0 else { return nil }
        return Int((value * 100).rounded())
    }

    func set(percent: Int, exponential: Bool, exponent: Double) -> Bool {
        guard let set = self.setBrightness else { return false }
        let level = BrightnessCurve.hardwareLevel(
            percent: percent, exponential: exponential, exponent: exponent)
        return set(CGMainDisplayID(), Float(level)) == 0
    }

    // The upstream State shape: {devices: [Device]}.
    func state() -> [String: Any] {
        guard let percent = self.currentPercent() else { return ["devices": []] }
        return [
            "devices": [
                [
                    "class": "backlight",
                    "id": Self.deviceId,
                    "name": "Built-in Display",
                    "current": percent,
                    "max": 100,
                    "currentPercent": percent,
                    "backend": "displayservices",
                ]
            ]
        ]
    }
}
