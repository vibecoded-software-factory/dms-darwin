#!/bin/sh
# Install DankMaterialShell as the macOS login shell, rendered by bento-box
# (the quickshell macOS port) under the nigiri compositor.
#
# What it sets up:
#   - ~/Applications/Bento.app         a signed bundle of the bento binary, so
#                                      the login agent has a stable TCC identity
#                                      (the same reason nigiri ships as an .app)
#   - this repo's quickshell/ dir       DankMaterialShell + a thin macOS wrapper
#                                      (shell-macos.qml) that mirrors the shell's
#                                      wallpaper onto the real macOS desktop
#   - ~/Library/LaunchAgents/dev.bento.plist   runs it at login, kept alive
#
# Re-runnable: rebuilds, re-bundles, rewrites the wrapper, and restarts the
# agent. `uninstall.sh` tears it back down.
set -e

# This script is VERSIONED IN dms-darwin (Glue/) and run against the DMS
# checkout - DMS's own tree stays pristine (its core QML must never be
# modified; the macOS wrapper files below are generated build products).
# Default assumes the standard sibling layout; override with DMS_DIR.
DMS_DIR="${DMS_DIR:-$(cd "$(dirname "$0")/../../DankMaterialShell" && pwd)}"
SHELL_DIR="$DMS_DIR/quickshell"
BENTO_REPO="${BENTO_REPO:-$HOME/Downloads/GitHub/vibecoded-software-factory/bento-box}"
BUILD_DIR="$BENTO_REPO/build-release"
APP="$HOME/Applications/Bento.app"
LABEL="dev.bento"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/bento.log"
NIRI_SOCKET="${NIRI_SOCKET:-/tmp/nigiri-msg.sock}"
# The darwin system daemon (dms-darwin) serving brightness/night/etc over
# the DMS daemon protocol; installed by its own repo's Scripts/install.sh.
DMS_SOCKET="${DMS_SOCKET:-/tmp/dms-darwin.sock}"

echo ">> Building bento (release)"
cmake -S "$BENTO_REPO" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
    -DWAYLAND=OFF -DX11=OFF -DI3=OFF -DBLUETOOTH=OFF -DNETWORK=OFF \
    -DCRASH_HANDLER=OFF -DUSE_JEMALLOC=OFF \
    -DSERVICE_MPRIS=OFF -DSERVICE_PIPEWIRE=OFF -DSERVICE_UPOWER=OFF \
    -DSERVICE_STATUS_NOTIFIER=OFF -DSERVICE_NOTIFICATIONS=OFF \
    -DSERVICE_PAM=OFF -DSERVICE_POLKIT=OFF -DSERVICE_GREETD=OFF >/dev/null
cmake --build "$BUILD_DIR"
BIN="$BUILD_DIR/src/quickshell"

echo ">> Bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/bento"
# Ship the MediaRemote adapter framework inside the bundle so the app is
# self-contained: bento resolves it from Contents/Frameworks at runtime instead
# of depending on the build tree still being present. Loaded by the entitled
# system perl (not linked), so its own ad-hoc signature is left as built.
MRA="$BUILD_DIR/src/mac/mpris/mediaremote-adapter/MediaRemoteAdapter.framework"
if [ -d "$MRA" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$MRA" "$APP/Contents/Frameworks/"
fi
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.bento</string>
    <key>CFBundleName</key><string>Bento</string>
    <key>CFBundleExecutable</key><string>bento</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <!-- macOS hard-CRASHES a launchd-run app that touches a TCC-protected API
         with no usage-description string (this is why it "worked" from a
         terminal but not as an agent: the terminal was the responsible process).
         The bar reads Bluetooth device state, so it needs this or it aborts. -->
    <key>NSBluetoothAlwaysUsageDescription</key><string>DankMaterialShell shows Bluetooth device status in the bar.</string>
    <key>NSAppleEventsUsageDescription</key><string>DankMaterialShell controls desktop features.</string>
    <!-- The audio visualizer (cava) captures audio input; on macOS any input
         capture (even a loopback like BlackHole) needs Microphone access. -->
    <key>NSMicrophoneUsageDescription</key><string>DankMaterialShell visualizes audio in the bar.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>DankMaterialShell reads its own files, installed under Downloads.</string>
</dict>
</plist>
EOF
# A stable code-signing identity keeps any TCC grant (e.g. Bluetooth) alive
# across rebuilds; ad-hoc re-pins to the per-build hash. Create a self-signed
# "bento codesign" certificate to get the stable path, as nigiri documents.
if security find-identity -v -p codesigning | grep -q "bento codesign"; then
    # Let codesign use the private key non-interactively: since Sierra macOS
    # requires the key's partition list to include codesign, or signing fails
    # with errSecInternalComponent. Best-effort (an empty keychain password).
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
    codesign --force --sign "bento codesign" --identifier dev.bento "$APP"
else
    echo "   (no 'bento codesign' cert; ad-hoc signature)"
    codesign --force --sign - --identifier dev.bento "$APP"
fi

# Drift guard: shell-macos.qml below embeds a copy of shell.qml's body
# (QML has no include; the wrapper adds the Mac bridge + audio tap around
# the same loaders). If upstream shell.qml changes, the copy must be
# reviewed - warn LOUDLY instead of drifting silently.
SHELL_QML_EXPECTED="e33a870ba8a89c1ac27108ffcbd6a9f2b51e6d0b85df1f827ce0a0f81ab45c19"
SHELL_QML_ACTUAL="$(shasum -a 256 "$SHELL_DIR/shell.qml" | cut -d' ' -f1)"
if [ "$SHELL_QML_ACTUAL" != "$SHELL_QML_EXPECTED" ]; then
    echo "!! WARNING: upstream shell.qml changed since the macOS wrapper was written." >&2
    echo "!!          Review Glue/install.sh's shell-macos.qml heredoc against it," >&2
    echo "!!          then update SHELL_QML_EXPECTED. Continuing with the old wrapper body." >&2
fi

echo ">> Writing the macOS wrapper into $SHELL_DIR"
# The entry point: DankMaterialShell's shell, plus the wallpaper bridge. Kept
# here (not upstream) so a DMS update never clobbers it and vice-versa.
cat > "$SHELL_DIR/shell-macos.qml" <<'EOF'
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
EOF
cat > "$SHELL_DIR/MacWallpaperBridge.qml" <<'EOF'
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
EOF

echo ">> Installing the dms CLI shim"
# The shell shells out to the `dms` CLI (the Go binary on Linux) for a few
# actions. Cover what actually gets invoked on macOS; everything else fails
# loudly instead of silently doing nothing.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/dms" <<'EOF'
#!/bin/sh
# dms - darwin stand-in for the DankMaterialShell CLI. Generated by
# install.sh; re-run it to regenerate.
#
#   dms restart      restart the shell agent (the power menu's "Restart DMS")
#   dms ipc ...      forward to the shell's IPC (bento's ipc CLI)
#   dms cl copy ...  copy text to the clipboard (pbcopy)
#   dms dl ...       fetch a URL to stdout (curl), used by location search
case "$1" in
restart)
    exec launchctl kickstart -k "gui/$(id -u)/__LABEL__"
    ;;
ipc)
    shift
    exec "__APP__/Contents/MacOS/bento" -p "__SHELL_DIR__/shell-macos.qml" ipc "$@"
    ;;
cl)
    if [ "$2" = "copy" ]; then
        shift 2
        printf '%s' "$*" | pbcopy
        exit 0
    fi
    echo "dms (darwin shim): cl subcommand '$2' is not ported" >&2
    exit 1
    ;;
dl)
    shift
    url=""
    timeout=10
    prev=""
    for arg in "$@"; do
        case "$arg" in
        http://*|https://*) url="$arg" ;;
        esac
        [ "$prev" = "--timeout" ] && timeout="$arg"
        prev="$arg"
    done
    [ -n "$url" ] && exec curl -4 -sfL --max-time "$timeout" "$url"
    echo "dms (darwin shim): dl needs a url" >&2
    exit 1
    ;;
*)
    echo "dms (darwin shim): subcommand '$1' is not ported; available: restart, ipc, cl copy, dl" >&2
    exit 1
    ;;
esac
EOF
sed -i '' -e "s|__LABEL__|$LABEL|g" -e "s|__APP__|$APP|g" -e "s|__SHELL_DIR__|$SHELL_DIR|g" "$HOME/.local/bin/dms"
chmod +x "$HOME/.local/bin/dms"

# The shell writes the SYSTEM color scheme by exec'ing gsettings (its
# PortalService probes `command -v gsettings || command -v dconf` and there
# is no daemon method for this upstream). This stand-in maps the color-scheme
# key onto the system-wide macOS appearance, so toggling the shell's dark
# mode flips Finder and every native window too - the exact parity of what
# gsettings does to GTK apps on Linux. Reads print nothing (callers all
# handle empty); every other key is accepted and dropped.
cat > "$HOME/.local/bin/gsettings" <<'EOF'
#!/bin/sh
# gsettings - darwin stand-in for the shell's system color-scheme writes.
# Generated by DankMaterialShell's macOS install.sh; re-run it to regenerate.
#
# Only the color-scheme write does real work (drives the system-wide macOS
# appearance). Everything else fails like real gsettings does on a system
# without the schema, so the shell's availability probes stay honest.
if [ "$1" = "set" ] && [ "$2" = "org.gnome.desktop.interface" ] \
    && [ "$3" = "color-scheme" ]; then
    case "$4" in
    *dark*) dark=true ;;
    *) dark=false ;;
    esac
    exec osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $dark"
fi
echo "gsettings (darwin shim): schema not served: $*" >&2
exit 1
EOF
chmod +x "$HOME/.local/bin/gsettings"

# The visualizer: the shell generates a cava config with no [input] section
# (Linux cava autodetects pulse/pipewire). This stand-in injects the darwin
# analogue - the system-audio tap fifo - keeping upstream CavaService.qml
# untouched.
cat > "$HOME/.local/bin/cava" <<'EOF'
#!/bin/sh
# cava - darwin stand-in for the shell's visualizer launch. Generated by
# DankMaterialShell's macOS install.sh; re-run it to regenerate.
#
# The shell generates a cava config with NO [input] section (on Linux cava
# autodetects pulse/pipewire). The macOS analogue of that autodetection is
# the system-audio tap fifo (dms-darwin audio-tap); inject it into the
# generated config, then run the real cava. Configs that already carry an
# [input] section pass through untouched.
conf=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-p" ] && conf="$arg"
    prev="$arg"
done
if [ -n "$conf" ] && [ -f "$conf" ] && ! grep -q '^\[input\]' "$conf"; then
    printf '\n[input]\nmethod=fifo\nsource=/tmp/dms-audio-tap.fifo\n' >> "$conf"
fi
exec /opt/homebrew/bin/cava "$@"
EOF
chmod +x "$HOME/.local/bin/cava"

# DMS's niri path shells out to a `niri` CLI (NiriService.qml: `niri validate`,
# `niri msg -j outputs`, `niri msg output <name> ...`). No repo ships a real
# niri on macOS - the compositor is nigiri, which speaks niri's IPC on its
# socket. This stand-in answers those calls truthfully: validate runs nigiri's
# own config parser, msg forwards the niri JSON request over the socket and
# unwraps the reply exactly like `niri msg -j` prints it. Display settings come
# back as nigiri's own honest Err ("output configuration is not supported on
# macOS") instead of a fake success.
cat > "$HOME/.local/bin/niri" <<'EOF'
#!/usr/bin/env python3
# niri - darwin stand-in for DMS's niri CLI calls. Generated by
# DankMaterialShell's macOS install.sh; re-run it to regenerate.
import json, os, socket, subprocess, sys

SOCKET = os.environ.get("NIGIRI_SOCKET", os.environ.get("NIRI_SOCKET", "/tmp/nigiri-msg.sock"))


def find_nigiri():
    for p in (os.environ.get("NIGIRI_BIN"), os.path.expanduser("~/.local/bin/nigiri")):
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    from shutil import which
    return which("nigiri")


def request(payload):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(2.0)
        s.connect(SOCKET)
        s.sendall((json.dumps(payload) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf)


def main(argv):
    if not argv:
        print("usage: niri <validate|msg [-j] <request...>>", file=sys.stderr)
        return 1
    cmd, args = argv[0], argv[1:]
    if cmd == "validate":
        # niri validate checks the config; the macOS analogue is nigiri's own
        # parser report. Absence of the binary is not a config error - note it
        # on stderr (DMS only toasts on a NONZERO exit) and pass.
        nigiri = find_nigiri()
        if nigiri is None:
            print("niri shim: nigiri binary not found; config not validated", file=sys.stderr)
            return 0
        proc = subprocess.run([nigiri, "check-config"], capture_output=True, text=True)
        sys.stderr.write(proc.stdout + proc.stderr)  # niri validate reports over stderr
        return proc.returncode
    if cmd == "msg":
        if args and args[0] == "-j":
            args = args[1:]  # replies here are JSON either way
        if not args:
            print("usage: niri msg [-j] <outputs|output <name> ...|<request>>", file=sys.stderr)
            return 1
        sub = args[0]
        if sub == "output":
            # Request::Output { output, action }. nigiri answers OutputWasMissing
            # for unknown targets and an honest Err for real ones - macOS owns
            # display configuration.
            name = args[1] if len(args) > 1 else ""
            reply = request({"Output": {"output": name, "action": args[2:]}})
        else:
            # kebab-case subcommand -> niri's PascalCase request (outputs ->
            # "Outputs", focused-window -> "FocusedWindow", ...).
            reply = request("".join(w.capitalize() for w in sub.split("-")))
        if "Ok" in reply:
            payload = reply["Ok"]
            # `niri msg -j outputs` prints the outputs MAP itself, which is
            # what DMS JSON-parses; mirror that unwrapping per request kind.
            if isinstance(payload, dict) and len(payload) == 1:
                payload = next(iter(payload.values()))
            print(json.dumps(payload))
            return 0
        print(json.dumps(reply.get("Err", reply)), file=sys.stderr)
        return 1
    print(f"niri shim: unsupported command {cmd!r}; available: validate, msg", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, json.JSONDecodeError) as e:
        print(f"niri shim: {e}", file=sys.stderr)
        sys.exit(1)
EOF
chmod +x "$HOME/.local/bin/niri"

echo ">> Installing the launch agent $LABEL"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/bento</string>
        <string>-p</string>
        <string>$SHELL_DIR/shell-macos.qml</string>
    </array>
    <!-- The compositor exports NIRI_SOCKET via launchctl setenv, but at login
         this agent may start before it does; pin the well-known path so the
         shell finds the compositor regardless of startup order. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>NIRI_SOCKET</key><string>$NIRI_SOCKET</string>
        <key>NIGIRI_SOCKET</key><string>$NIRI_SOCKET</string>
        <key>DMS_SOCKET</key><string>$DMS_SOCKET</string>
        <!-- A launchd agent inherits a bare PATH (/usr/bin:/bin:...) with no
             Homebrew, so the shell's tool probes (e.g. 'command -v cava', which
             decides whether the media widget shows the audio visualizer or the
             music-note fallback) silently fail. Put Homebrew on PATH so those
             features light up the way they do on a normal login. -->
        <!-- ~/.local/bin carries dms-darwin and the `dms` CLI shim the shell
             invokes (e.g. the power menu's "Restart DMS" runs `dms restart`). -->
        <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

echo ">> (Re)starting the agent"
DOMAIN="gui/$(id -u)"
# bootout is asynchronous: bootstrapping again too soon races the teardown and
# fails with "Bootstrap failed: 5: Input/output error". Wait for the label to
# actually leave the domain, then bootstrap (RunAtLoad starts it - no kickstart,
# which would SIGKILL the just-started instance for nothing).
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.3
done
launchctl bootstrap "$DOMAIN" "$PLIST"

echo ""
echo "Done. DankMaterialShell is running and will start at login."
echo "  logs:      $LOG"
echo "  uninstall: $(dirname "$0")/uninstall.sh"
