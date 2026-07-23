import Foundation

// Night-mode backend: macOS Night Shift, driven through CBBlueLightClient in
// the private CoreBrightness framework (the same control Control Center
// uses). Loaded via the ObjC runtime so a missing framework degrades to "no
// gamma capability" instead of a crash.
//
// The shell's gamma protocol speaks color TEMPERATURE (Kelvin, wlr-gamma
// style); Night Shift speaks a 0..1 warmth STRENGTH. The mapping is linear
// between neutral (6500K, strength 0) and Night Shift's warmest (~2700K,
// strength 1) - documented approximation, monotonic and reversible enough
// for a toggle + temperature slider.
enum GammaMath {
    static let neutralTemp = 6500.0
    static let warmestTemp = 2700.0

    static func strength(forTemp temp: Double) -> Double {
        let clamped = min(neutralTemp, max(warmestTemp, temp))
        return (neutralTemp - clamped) / (neutralTemp - warmestTemp)
    }
}

final class NightShiftService {
    private let client: NSObject?
    private let setEnabledFn: (@convention(c) (NSObject, Selector, Bool) -> Bool)?
    private let setStrengthFn: (@convention(c) (NSObject, Selector, Float, Bool) -> Bool)?

    init() {
        guard
            dlopen(
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                RTLD_LAZY) != nil,
            let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        else {
            self.client = nil
            self.setEnabledFn = nil
            self.setStrengthFn = nil
            return
        }
        let instance = cls.init()
        self.client = instance

        let enabledSel = NSSelectorFromString("setEnabled:")
        let strengthSel = NSSelectorFromString("setStrength:commit:")
        self.setEnabledFn = instance.responds(to: enabledSel)
            ? unsafeBitCast(
                instance.method(for: enabledSel),
                to: (@convention(c) (NSObject, Selector, Bool) -> Bool).self)
            : nil
        self.setStrengthFn = instance.responds(to: strengthSel)
            ? unsafeBitCast(
                instance.method(for: strengthSel),
                to: (@convention(c) (NSObject, Selector, Float, Bool) -> Bool).self)
            : nil
    }

    var available: Bool { self.setEnabledFn != nil && self.setStrengthFn != nil }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard let client = self.client, let fn = self.setEnabledFn else { return false }
        return fn(client, NSSelectorFromString("setEnabled:"), enabled)
    }

    @discardableResult
    func setStrength(_ strength: Double) -> Bool {
        guard let client = self.client, let fn = self.setStrengthFn else { return false }
        return fn(
            client, NSSelectorFromString("setStrength:commit:"),
            Float(min(1.0, max(0.0, strength))), true)
    }
}
