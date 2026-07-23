import Foundation

// The native macOS lock screen, engaged the way Keychain Access's "Lock
// Screen" menu item does it: SACLockScreenImmediate from the private
// login.framework. The OS then owns the lock surface and authentication
// (password / Touch ID), which is exactly the "external locker" contract
// DankMaterialShell's customPowerActionLock expects - the shell spawns the
// locker and stays out of the lock/auth lifecycle entirely.
enum NativeLock {
    static func lock() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW) else {
            fputs("[lock] dlopen login.framework failed\n", stderr)
            return false
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            fputs("[lock] SACLockScreenImmediate not found\n", stderr)
            return false
        }
        typealias LockFn = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: LockFn.self)() == 0
    }
}
