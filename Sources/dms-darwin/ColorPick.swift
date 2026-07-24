import AppKit
import Foundation

// `dms color pick --json` for macOS: the screen-eyedropper the shell's
// DankColorPickerModal invokes (DankColorPickerModal.qml:107), which reads
// {"hex":"#RRGGBB"} from stdout. The upstream Go CLI samples via Wayland
// screencopy; the niri backend is inert (nigiri parses PickColor but answers
// null - IPC/NiriProtocol.swift:466), so this uses NSColorSampler, the system
// screen color picker (macOS 10.15+). It runs out of process, so no Screen
// Recording grant on this tool is required.
enum ColorPick {
  static func run() -> Int32 {
    // NSColorSampler needs a running app + main run loop to present and
    // deliver its callback. A plain CLI has neither, so spin up a headless
    // accessory app for the one-shot pick.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    var exitCode: Int32 = 1
    let sampler = NSColorSampler()
    sampler.show { color in
      defer { app.terminate(nil) }
      guard let color = color else {
        // User pressed Escape: upstream treats a null pick as a
        // non-error cancel (the modal just logs and does nothing).
        exitCode = 2
        return
      }
      // sRGB is what CSS #hex denotes; convert from whatever space the
      // sampled pixel used so the hex matches what the user sees.
      let rgb = color.usingColorSpace(.sRGB) ?? color
      let r = Int((rgb.redComponent * 255).rounded())
      let g = Int((rgb.greenComponent * 255).rounded())
      let b = Int((rgb.blueComponent * 255).rounded())
      let hex = String(format: "#%02X%02X%02X", r, g, b)
      print("{\"hex\":\"\(hex)\"}")
      exitCode = 0
    }

    app.run()  // returns after app.terminate in the callback
    return exitCode
  }
}
