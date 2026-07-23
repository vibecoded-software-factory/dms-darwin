import Foundation
import IOBluetooth

// The `bluetooth.*` channel: the upstream Go daemon's bluez service mapped
// onto IOBluetooth. This is the DAEMON side of pairing - the shell's
// BluetoothPairingModal drives the PairingPrompt token flow (submit/cancel)
// so pairing confirmations get DMS's own dialogs, and remove answers an
// honest error where macOS entitlement-gates unpairing (the shell shows its
// toast). Device identity is BlueZ-style object paths, the same tokens the
// shell derives on Linux.
final class BluetoothChannel: NSObject {
    // Overall power toggle: not in the public headers but long-lived in the
    // framework (what menu-bar togglers call), resolved at runtime.
    private typealias SetPowerFn = @convention(c) (Int32) -> Int32
    private static let setControllerPower: SetPowerFn? = {
        let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        guard let handle = dlopen(path, RTLD_LAZY),
            let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState")
        else { return nil }
        return unsafeBitCast(symbol, to: SetPowerFn.self)
    }()

    var onStateChanged: (() -> Void)?
    var onPairingPrompt: (([String: Any]) -> Void)?

    var available: Bool { IOBluetoothHostController.default() != nil }

    // ---- device identity: BlueZ object path <-> mac address ----

    static func path(forAddress address: String) -> String {
        "/org/bluez/hci0/dev_" + address.uppercased().replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    static func address(fromPath path: String) -> String? {
        guard let last = path.split(separator: "/").last, last.hasPrefix("dev_") else {
            return nil
        }
        return last.dropFirst(4).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func device(forPath path: String) -> IOBluetoothDevice? {
        guard let address = Self.address(fromPath: path) else { return nil }
        return IOBluetoothDevice(addressString: address)
    }

    // ---- state (upstream BluetoothState/Device shapes) ----

    private static func icon(for device: IOBluetoothDevice) -> String {
        switch Int(device.deviceClassMajor) {
        case kBluetoothDeviceClassMajorComputer: return "computer"
        case kBluetoothDeviceClassMajorPhone: return "phone"
        case kBluetoothDeviceClassMajorAudio: return "audio-headphones"
        case kBluetoothDeviceClassMajorPeripheral:
            switch Int(device.deviceClassMinor) {
            case kBluetoothDeviceClassMinorPeripheral1Keyboard: return "input-keyboard"
            case kBluetoothDeviceClassMinorPeripheral1Pointing: return "input-mouse"
            default: return "input-gaming"
            }
        default: return "bluetooth"
        }
    }

    private static func deviceInfo(_ device: IOBluetoothDevice) -> [String: Any] {
        let address = device.addressString ?? ""
        return [
            "path": Self.path(forAddress: address),
            "address": address.uppercased().replacingOccurrences(of: "-", with: ":"),
            "name": device.name ?? address,
            "alias": device.name ?? address,
            "paired": device.isPaired(),
            "trusted": false,
            "blocked": false,
            "connected": device.isConnected(),
            "class": device.classOfDevice,
            "icon": Self.icon(for: device),
            "rssi": 0,
            "legacyPairing": false,
        ]
    }

    func state() -> [String: Any] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let devices = paired.map(Self.deviceInfo)
        let powered =
            IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        return [
            "powered": powered,
            "discovering": false,
            "devices": devices,
            "pairedDevices": devices.filter { ($0["paired"] as? Bool) == true },
            "connectedDevices": devices.filter { ($0["connected"] as? Bool) == true },
        ]
    }

    // ---- pairing agent (PairingPrompt token flow, upstream shapes) ----

    private final class PendingPairing {
        let pair: IOBluetoothDevicePair
        var reply: ((_ secrets: [String: String], _ accept: Bool) -> Void)?
        init(pair: IOBluetoothDevicePair) { self.pair = pair }
    }

    private var pendingByToken: [String: PendingPairing] = [:]
    private var pairsByAddress: [String: PendingPairing] = [:]

    private func prompt(
        for device: IOBluetoothDevice, type: String, fields: [String], passkey: UInt32?,
        pending: PendingPairing, reply: @escaping ([String: String], Bool) -> Void
    ) {
        let token = UUID().uuidString
        pending.reply = reply
        self.pendingByToken[token] = pending
        let address = device.addressString ?? ""
        var payload: [String: Any] = [
            "token": token,
            "devicePath": Self.path(forAddress: address),
            "deviceName": device.name ?? address,
            "deviceAddr": address.uppercased().replacingOccurrences(of: "-", with: ":"),
            "requestType": type,
            "fields": fields,
            "hints": [],
        ]
        if let passkey { payload["passkey"] = passkey }
        self.onPairingPrompt?(payload)
    }

    // Returns (result, error); both nil means "unknown method".
    func handle(method: String, params: [String: Any]) -> (result: Any?, error: String?) {
        switch method {
        case "bluetooth.getState":
            return (self.state(), nil)
        case "bluetooth.setPowered":
            guard let powered = params["powered"] as? Bool else {
                return (nil, "missing param: powered")
            }
            guard let setPower = Self.setControllerPower else {
                return (nil, "failed to set power state")
            }
            _ = setPower(powered ? 1 : 0)
            return (["success": true, "message": "powered state updated"], nil)
        case "bluetooth.startDiscovery":
            // Discovery is served by the shell's Bluetooth module on macOS;
            // the daemon method exists for protocol completeness.
            return (["success": true, "message": "discovery started"], nil)
        case "bluetooth.stopDiscovery":
            return (["success": true, "message": "discovery stopped"], nil)
        case "bluetooth.connect", "bluetooth.disconnect", "bluetooth.pair",
            "bluetooth.remove", "bluetooth.trust", "bluetooth.untrust":
            guard let devicePath = params["device"] as? String else {
                return (nil, "missing param: device")
            }
            guard let device = self.device(forPath: devicePath) else {
                return (nil, "device not found: \(devicePath)")
            }
            return self.handleDeviceMethod(method, device: device)
        case "bluetooth.pairing.submit":
            guard let token = params["token"] as? String else {
                return (nil, "missing param: token")
            }
            guard let pending = self.pendingByToken.removeValue(forKey: token),
                let reply = pending.reply
            else {
                return (nil, "no pending pairing prompt for token")
            }
            pending.reply = nil
            let secrets = params["secrets"] as? [String: String] ?? [:]
            let accept = params["accept"] as? Bool ?? false
            reply(secrets, accept)
            return (["success": true, "message": "pairing response submitted"], nil)
        case "bluetooth.pairing.cancel":
            guard let token = params["token"] as? String else {
                return (nil, "missing param: token")
            }
            if let pending = self.pendingByToken.removeValue(forKey: token) {
                pending.reply = nil
                pending.pair.stop()
            }
            return (["success": true, "message": "pairing cancelled"], nil)
        default:
            return (nil, nil)
        }
    }

    private func handleDeviceMethod(
        _ method: String, device: IOBluetoothDevice
    ) -> (result: Any?, error: String?) {
        switch method {
        case "bluetooth.connect":
            // openConnection blocks (upstream's Connect is async over DBus);
            // run it off the main loop so the daemon never freezes, and
            // broadcast the settled state when it returns.
            DispatchQueue.global(qos: .userInitiated).async {
                device.openConnection()
                DispatchQueue.main.async { self.onStateChanged?() }
            }
            return (["success": true, "message": "connecting"], nil)
        case "bluetooth.disconnect":
            DispatchQueue.global(qos: .userInitiated).async {
                device.closeConnection()
                DispatchQueue.main.async { self.onStateChanged?() }
            }
            return (["success": true, "message": "disconnected"], nil)
        case "bluetooth.pair":
            guard let pair = IOBluetoothDevicePair(device: device) else {
                return (nil, "failed to start pairing")
            }
            let pending = PendingPairing(pair: pair)
            self.pairsByAddress[device.addressString ?? ""] = pending
            pair.delegate = self
            guard pair.start() == kIOReturnSuccess else {
                self.pairsByAddress.removeValue(forKey: device.addressString ?? "")
                return (nil, "failed to start pairing")
            }
            return (["success": true, "message": "pairing initiated"], nil)
        case "bluetooth.remove":
            // macOS entitlement-gates unpairing: attempt the framework's
            // long-standing private call, then tell the truth. The shell
            // surfaces this error as its own toast.
            let removeSel = NSSelectorFromString("remove")
            if device.responds(to: removeSel) {
                _ = device.perform(removeSel)
            }
            let address = device.addressString
            let stillPaired = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
                .contains { $0.addressString == address }
            guard !stillPaired else {
                return (
                    nil,
                    "macOS does not allow third-party apps to unpair devices; remove it in System Settings > Bluetooth"
                )
            }
            self.onStateChanged?()
            return (["success": true, "message": "device removed"], nil)
        case "bluetooth.trust", "bluetooth.untrust":
            // No trust store on macOS; answer the honest platform truth.
            return (nil, "trust is not supported on darwin")
        default:
            return (nil, nil)
        }
    }
}

// IOBluetoothDevicePairDelegate: every interactive step becomes an upstream
// PairingPrompt pushed to the shell; the modal's submit answers it.
extension BluetoothChannel: IOBluetoothDevicePairDelegate {
    private func pending(for sender: Any?) -> PendingPairing? {
        guard let pair = sender as? IOBluetoothDevicePair,
            let address = pair.device()?.addressString
        else { return nil }
        return self.pairsByAddress[address]
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        guard let pair = sender as? IOBluetoothDevicePair, let device = pair.device(),
            let pending = self.pending(for: sender)
        else { return }
        self.prompt(for: device, type: "pin", fields: ["pin"], passkey: nil, pending: pending) {
            secrets, _ in
            var pin = BluetoothPINCode()
            let text = secrets["pin"] ?? ""
            let bytes = Array(text.utf8.prefix(16))
            withUnsafeMutableBytes(of: &pin.data) { raw in
                for (index, byte) in bytes.enumerated() { raw[index] = byte }
            }
            pair.replyPINCode(bytes.count, pinCode: &pin)
        }
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        guard let pair = sender as? IOBluetoothDevicePair, let device = pair.device(),
            let pending = self.pending(for: sender)
        else { return }
        self.prompt(
            for: device, type: "confirm", fields: ["decision"], passkey: numericValue,
            pending: pending
        ) { _, accept in
            pair.replyUserConfirmation(accept)
        }
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        guard let pair = sender as? IOBluetoothDevicePair, let device = pair.device(),
            let pending = self.pending(for: sender)
        else { return }
        // Display-only: the passkey is typed on the device; no reply needed.
        self.prompt(
            for: device, type: "display-passkey", fields: [], passkey: passkey, pending: pending
        ) { _, _ in }
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        guard let pair = sender as? IOBluetoothDevicePair,
            let address = pair.device()?.addressString
        else { return }
        self.pairsByAddress.removeValue(forKey: address)
        self.pendingByToken = self.pendingByToken.filter { $0.value.pair !== pair }
        self.onStateChanged?()
    }
}
