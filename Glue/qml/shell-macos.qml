//@ pragma Env QSG_RENDER_LOOP=threaded
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Material
//@ pragma UseQApplication
//@ pragma AppId com.danklinux.dms

// macOS entry point: DankMaterialShell's shell.qml, plus the wallpaper bridge
// that mirrors the shell's wallpaper onto the real macOS desktop. bento
// suppresses the shell's own background (wallpaper) layer on macOS, so this
// keeps the desktop in sync with what the shell was asked to show. Kept as a
// thin wrapper so upstream shell.qml stays untouched.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules
import qs.Services

ShellRoot {
    id: entrypoint

    readonly property bool disableHotReload: Quickshell.env("DMS_DISABLE_HOT_RELOAD") === "1" || Quickshell.env("DMS_DISABLE_HOT_RELOAD") === "true"

    Component.onCompleted: {
        Quickshell.watchFiles = !disableHotReload;
    }

    // macOS-only: keep the OS desktop wallpaper in sync with the shell.
    MacWallpaperBridge {}

    // macOS-only: system-audio tap for the visualizer. Runs as OUR child so
    // it inherits the shell's Screen Recording grant (TCC follows the
    // responsible process). Streams every output device - the PipeWire
    // monitor-source analogue - into the fifo cava reads, replacing the
    // BlackHole + aggregate-device contraption (which also broke the
    // hardware volume keys by making an aggregate the default output).
    Process {
        id: audioTap
        running: SettingsData.audioVisualizerEnabled
        command: [Quickshell.env("HOME") + "/.local/bin/dms-darwin", "audio-tap", "/tmp/dms-audio-tap.fifo"]
        onExited: restartTap.restart()
    }
    Timer {
        id: restartTap
        interval: 3000
        onTriggered: if (SettingsData.audioVisualizerEnabled) audioTap.running = true
    }

    Loader {
        id: wallpaperLoader
        asynchronous: false

        sourceComponent: Scope {
            WallpaperBackground {}

            Loader {
                active: SettingsData.blurredWallpaperLayer && CompositorService.isNiri
                asynchronous: false
                sourceComponent: BlurredWallpaperBackground {}
            }
        }
    }

    Loader {
        id: shellCoreLoader
        asynchronous: true
        source: "ShellCore.qml"
        onLoaded: dmsShellLoader.setSource("DMSShell.qml", {
            core: item
        })
    }

    Loader {
        id: dmsShellLoader
        asynchronous: true
    }
}
