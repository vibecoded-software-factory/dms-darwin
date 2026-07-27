import QtQuick
import Quickshell
import Quickshell.Mac
import qs.Common

// Mirror the shell's chosen wallpaper onto the real macOS desktop.
//
// On Wayland the shell paints its own wallpaper on a background layer surface;
// on macOS bento suppresses that layer (the OS owns the desktop) and we drive
// the OS wallpaper here instead, so changing the wallpaper in the shell changes
// it for real. This is client-side wiring: bento stays generic (it just exposes
// Quickshell.Mac.Desktop), and only this file knows it is DankMaterialShell's
// SessionData that holds the path.
Scope {
    function apply() {
        var path = SessionData.wallpaperPath;
        // Skip empty and solid-colour values (a "#rrggbb" string) - the OS
        // wallpaper API only takes an image file.
        if (path && path.length > 0 && !path.startsWith("#")) {
            Desktop.setWallpaper(path);
        }
    }

    Connections {
        target: SessionData
        function onWallpaperPathChanged() { apply(); }
    }

    // Apply whatever is already set once the session has loaded.
    Component.onCompleted: apply()
}
