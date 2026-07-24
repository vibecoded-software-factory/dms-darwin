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
#   dms clipboard copy   copy STDIN to the clipboard (pbcopy)
#   dms dl ...       fetch a URL to stdout (curl), used by location search
#   dms blur check   report whether panel blur is supported (it is not: 'unsupported')
#   dms trash count|put <path>|empty   dock trash over ~/.Trash / Finder
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
clipboard)
    # The Notepad's "copy to clipboard" pipes content in on stdin
    # (NotepadTextEditor.qml). pbcopy reads stdin verbatim.
    if [ "$2" = "copy" ]; then
        pbcopy
        exit 0
    fi
    echo "dms (darwin shim): clipboard subcommand '$2' is not ported" >&2
    exit 1
    ;;
blur)
    # bento does not back panels with a blur surface on macOS yet, so report
    # unsupported. Exit 0 so BlurService.qml does not log a probe failure.
    [ "$2" = "check" ] && { echo unsupported; exit 0; }
    echo "dms (darwin shim): blur subcommand '$2' is not ported" >&2
    exit 1
    ;;
trash)
    # Dock trash over the macOS trash, ALL via Finder: reading ~/.Trash
    # directly is TCC-blocked ("Operation not permitted") without Full Disk
    # Access, but Finder itself has access, so count/put/empty go through it
    # and only need an Automation -> Finder grant (the bundle already declares
    # NSAppleEventsUsageDescription). DMS shows its own confirm before empty.
    case "$2" in
    count)
        osascript -e 'tell application "Finder" to count items of trash' 2>/dev/null || echo 0
        ;;
    put)
        shift 2
        for f in "$@"; do
            [ -e "$f" ] || continue
            osascript -e "tell application \"Finder\" to delete (POSIX file \"$f\" as alias)" >/dev/null 2>&1
        done
        ;;
    empty)
        osascript -e 'tell application "Finder" to empty the trash' >/dev/null 2>&1
        ;;
    *)
        echo "dms (darwin shim): trash subcommand '$2' is not ported" >&2
        exit 1
        ;;
    esac
    ;;
*)
    echo "dms (darwin shim): subcommand '$1' is not ported; available: restart, ipc, cl copy, clipboard copy, dl, blur check, trash" >&2
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
# Sound theme name: macOS has no GTK sound-theme concept, so round-trip the
# value through a state file (AudioService reads it back and resolves sounds
# from the theme dirs). get prints 'value' quoted, as gsettings does.
if [ "$2" = "org.gnome.desktop.sound" ] && [ "$3" = "theme-name" ]; then
    STATE="$HOME/.local/state/dms-sound-theme"
    if [ "$1" = "get" ]; then
        printf "'%s'\n" "$(cat "$STATE" 2>/dev/null)"
        exit 0
    elif [ "$1" = "set" ]; then
        mkdir -p "$(dirname "$STATE")"
        printf '%s' "$4" > "$STATE"
        exit 0
    fi
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
        # parser report. `validate -c <file>` validates a CANDIDATE file (DMS
        # writes a temp config and validates it before applying) - honor it, or
        # nigiri would validate the LIVE config and pass a bad candidate.
        cfg = None
        if "-c" in args:
            i = args.index("-c")
            if i + 1 < len(args):
                cfg = args[i + 1]
        nigiri = find_nigiri()
        if nigiri is None:
            print("niri shim: nigiri binary not found; config not validated", file=sys.stderr)
            return 0
        proc = subprocess.run(
            [nigiri, "check-config"] + ([cfg] if cfg else []), capture_output=True, text=True
        )
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
        elif sub == "action":
            # Request::Action { action: <tagged enum> }. Map the kebab action
            # name to niri's PascalCase tag (load-config-file -> LoadConfigFile)
            # so the request is well-formed; nigiri answers Ok or an honest Err
            # per whether it implements that action.
            if len(args) < 2:
                print("usage: niri msg action <name> [args...]", file=sys.stderr)
                return 1
            tag = "".join(w.capitalize() for w in args[1].split("-"))
            reply = request({"Action": {tag: {}}})
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

# getent: DMS resolves the current user's full name via
# `getent passwd $USER | cut -d: -f5` and enumerates users/groups. macOS uses
# Directory Services; emit the Linux 7-field passwd / 4-field group shape from
# `id`/`dscl`. NOTE: DMS's user-list filter requires uid>=1000 and Linux
# wheel/sudo groups; macOS uids are 500-502 and its admin group is `admin`, so
# the Settings > Users list stays empty by DMS's own assumptions - this shim
# only makes the current-user full name (UserInfoService) resolve, which it does.
cat > "$HOME/.local/bin/getent" <<'EOF'
#!/bin/sh
# getent - darwin stand-in over id/dscl. Generated by install.sh.
db="$1"; key="$2"
emit_passwd() {
    u="$1"
    uid=$(id -u "$u" 2>/dev/null) || return 1
    gid=$(id -g "$u" 2>/dev/null)
    gecos=$(id -F "$u" 2>/dev/null | sed 's/[[:space:]]*$//')
    home=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    shell=$(dscl . -read "/Users/$u" UserShell 2>/dev/null | awk '{print $2}')
    printf '%s:*:%s:%s:%s:%s:%s\n' "$u" "$uid" "$gid" "$gecos" "$home" "$shell"
}
case "$db" in
passwd)
    if [ -n "$key" ]; then
        emit_passwd "$key" || exit 2
        exit 0
    fi
    dscl . -list /Users UniqueID | while read name uid; do
        [ "$uid" -ge 500 ] 2>/dev/null || continue
        emit_passwd "$name"
    done
    ;;
group)
    if [ -n "$key" ]; then
        gid=$(dscl . -read "/Groups/$key" PrimaryGroupID 2>/dev/null | awk '{print $2}')
        [ -z "$gid" ] && exit 2
        members=$(dscl . -read "/Groups/$key" GroupMembership 2>/dev/null | cut -d' ' -f2- | tr ' ' ',')
        printf '%s:*:%s:%s\n' "$key" "$gid" "$members"
        exit 0
    fi
    exit 2
    ;;
*)
    exit 2
    ;;
esac
EOF
chmod +x "$HOME/.local/bin/getent"

# xdg-open: DMS's trash "open" and a few other paths call xdg-open. Map to the
# native `open`, translating the trash URI to ~/.Trash.
cat > "$HOME/.local/bin/xdg-open" <<'EOF'
#!/bin/sh
# xdg-open - darwin stand-in over `open`. Generated by install.sh.
t="$1"
case "$t" in
trash://*|trash:*) exec open "$HOME/.Trash" ;;
file://*)          exec open "${t#file://}" ;;
*)                 exec open "$t" ;;
esac
EOF
chmod +x "$HOME/.local/bin/xdg-open"

# dgop: the real dgop (github.com/AvengeMedia/dgop) is Linux-only (reads
# /proc, /sys). This shim emits the SAME JSON schema DMS DgopService parses,
# from macOS-native sources (Mach host stats via ctypes, sysctl, vm_stat,
# ps, df, netstat, system_profiler). Powers the system monitor, process
# list, and CPU/RAM/temp/disk/network bar widgets. Honest limits: CPU/GPU
# temperature need root so they read 0; cumulative disk I/O has no clean
# macOS counter so the disk-I/O module is empty (rates read 0).
cat > "$HOME/.local/bin/dgop" <<'DGOP_EOF'
#!/usr/bin/env python3
# dgop - darwin stand-in for the dgop system-monitor CLI. Generated by
# DankMaterialShell's macOS install.sh; re-run it to regenerate.
#
# The real dgop (github.com/AvengeMedia/dgop) is Linux-only: it reads /proc and
# /sys directly. This shim emits the SAME JSON schema DMS's DgopService parses,
# sourced from macOS-native tools (Mach host stats via ctypes, sysctl, vm_stat,
# ps, df, netstat, system_profiler). Honest limits: CPU/GPU temperature need
# root (powermetrics/SMC) so they report 0; cumulative disk I/O has no clean
# macOS counter so the `disk` I/O module reports empty (rates read 0).
#
# Subcommands DMS uses: `meta --json --modules <list|all> [--cpu-cursor C]
# [--proc-cursor P] [--sort S] [--limit N]`, `gpu --json`, `hardware --json`,
# and `command -v dgop` for availability.
import base64, ctypes, re, ctypes.util, json, os, subprocess, sys, time

# Absolute paths so PATH pollution (btop shadowing top, homebrew coreutils
# shadowing df/ps) can never feed us wrong data - the shim must use the real
# macOS tools.
_ABS = {
    "sysctl": "/usr/sbin/sysctl", "vm_stat": "/usr/bin/vm_stat", "ps": "/bin/ps",
    "df": "/bin/df", "netstat": "/usr/sbin/netstat", "top": "/usr/bin/top",
    "system_profiler": "/usr/sbin/system_profiler", "sw_vers": "/usr/bin/sw_vers",
    "scutil": "/usr/sbin/scutil", "uname": "/usr/bin/uname", "hostname": "/bin/hostname",
}
def sh(cmd):
    if cmd and cmd[0] in _ABS:
        cmd = [_ABS[cmd[0]]] + cmd[1:]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""

def sysctl(name):
    return sh(["sysctl", "-n", name]).strip()

# ---------- CPU ticks via Mach (for instantaneous usage through the cursor) ----------
_libc = None
def libc():
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL(ctypes.util.find_library("System"))
    return _libc

def cpu_ticks():
    """Per-core [user, system, idle, nice] tick counters, or None on failure."""
    try:
        c = libc()
        c.mach_host_self.restype = ctypes.c_uint
        host = c.mach_host_self()
        PROCESSOR_CPU_LOAD_INFO = 2
        STATES = 4
        ncpu = ctypes.c_uint(0)
        info = ctypes.POINTER(ctypes.c_int)()
        cnt = ctypes.c_uint(0)
        if c.host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                 ctypes.byref(ncpu), ctypes.byref(info), ctypes.byref(cnt)) != 0:
            return None
        n = ncpu.value
        out = [[int(info[i * STATES + s]) for s in range(STATES)] for i in range(n)]
        c.vm_deallocate(c.mach_task_self(), ctypes.cast(info, ctypes.c_void_p), cnt.value * 4)
        return out
    except Exception:
        return None

def enc_cursor(obj):
    return base64.b64encode(json.dumps(obj).encode()).decode()

def dec_cursor(s):
    try:
        return json.loads(base64.b64decode(s.encode()).decode())
    except Exception:
        return None

def busy_pct(cur, prev):
    # (user+sys+nice) over total, across the delta of two tick snapshots.
    du = sum(c[0] for c in cur) - sum(p[0] for p in prev)
    dsy = sum(c[1] for c in cur) - sum(p[1] for p in prev)
    di = sum(c[2] for c in cur) - sum(p[2] for p in prev)
    dn = sum(c[3] for c in cur) - sum(p[3] for p in prev)
    total = du + dsy + di + dn
    return round(100.0 * (du + dsy + dn) / total, 1) if total > 0 else 0.0

def core_busy(cur, prev):
    out = []
    for i in range(min(len(cur), len(prev))):
        du = cur[i][0] - prev[i][0]
        dsy = cur[i][1] - prev[i][1]
        di = cur[i][2] - prev[i][2]
        dn = cur[i][3] - prev[i][3]
        total = du + dsy + di + dn
        out.append(round(100.0 * (du + dsy + dn) / total, 1) if total > 0 else 0.0)
    return out

def cpu_module(cursor_in):
    count = int(sysctl("hw.ncpu") or 1)
    model = sysctl("machdep.cpu.brand_string") or sysctl("hw.model") or ""
    freq_hz = sysctl("hw.cpufrequency")  # Intel only; Apple Silicon returns ""
    freq = round(int(freq_hz) / 1_000_000) if freq_hz.isdigit() else 0
    cur = cpu_ticks()
    usage, core = 0.0, []
    if cur is not None:
        prev = dec_cursor(cursor_in) if cursor_in else None
        if prev and len(prev) == len(cur):
            usage = busy_pct(cur, prev)
            core = core_busy(cur, prev)
        else:
            # first sample: since-boot approximation
            zero = [[0, 0, 0, 0] for _ in cur]
            usage = busy_pct(cur, zero)
            core = core_busy(cur, zero)
    return {
        "usage": usage,
        "frequency": freq,
        "temperature": 0,  # needs powermetrics/SMC (root) - honest 0
        "count": count,
        "model": model,
        "coreUsage": core,
        "cursor": enc_cursor(cur) if cur is not None else "",
    }

def memory_module():
    page = int(sysctl("hw.pagesize") or 4096)
    total_b = int(sysctl("hw.memsize") or 0)
    stats = {}
    for line in sh(["vm_stat"]).splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            v = v.strip().rstrip(".")
            if v.isdigit():
                stats[k.strip()] = int(v)
    free_pages = stats.get("Pages free", 0)
    spec = stats.get("Pages speculative", 0)
    inactive = stats.get("Pages inactive", 0)
    # "available" ~= free + inactive + speculative (reclaimable), like Activity Monitor's headroom
    avail_b = (free_pages + spec + inactive) * page
    free_b = free_pages * page
    used_b = max(0, total_b - avail_b)
    swap = sysctl("vm.swapusage")  # "total = 2048.00M  used = 512.00M  free = 1536.00M"
    def swp(tok):
        try:
            part = swap.split(tok, 1)[1].split("=")[1].strip().split()[0]
            return int(float(part.rstrip("KMG")) * (1024 if part.endswith("M") else 1024*1024 if part.endswith("G") else 1))
        except Exception:
            return 0
    swaptotal = swp("total")
    swapfree = swp("free")
    return {
        "total": total_b // 1024,
        "available": avail_b // 1024,
        "free": free_b // 1024,
        "used": used_b // 1024,
        "usedPercent": round(100.0 * used_b / total_b, 1) if total_b else 0.0,
        "swaptotal": swaptotal // 1024,
        "swapfree": swapfree // 1024,
    }

def network_module():
    out = []
    seen = set()
    for line in sh(["netstat", "-ibn"]).splitlines()[1:]:
        f = line.split()
        if len(f) < 11 or "." in f[0]:  # skip per-address rows (Link rows carry totals)
            continue
        name = f[0]
        if name in seen or name == "lo0":
            continue
        # columns vary; find the two large cumulative byte counters (Ibytes, Obytes)
        try:
            ibytes = int(f[6]); obytes = int(f[9])
        except (ValueError, IndexError):
            continue
        seen.add(name)
        out.append({"name": name, "rx": ibytes, "tx": obytes})
    return out

def diskmounts_module():
    out = []
    for line in sh(["df", "-H"]).splitlines()[1:]:
        f = line.split()
        if len(f) < 9 or not f[0].startswith("/dev/"):
            continue
        size, used, avail, pct, mount = f[1], f[2], f[3], f[4], " ".join(f[8:])
        if not (mount == "/" or mount.startswith("/Volumes/")):
            continue
        out.append({"mount": mount, "size": size, "used": used, "avail": avail, "percent": pct})
    return out

def system_module():
    la = sysctl("vm.loadavg")  # "{ 1.23 1.10 0.98 }"
    loadavg = la.strip("{} ").strip()
    nproc = len([l for l in sh(["ps", "-A", "-o", "pid="]).splitlines() if l.strip()])
    threads = 0
    m = re.search(r"(\d[\d,]*)\s+threads", sh(["top", "-l", "1", "-n", "0"]))
    if m:
        threads = int(m.group(1).replace(",", ""))
    boottime = sysctl("kern.boottime")  # "{ sec = 1690000000, usec = 0 } ..."
    bsec = ""
    if "sec =" in boottime:
        try:
            bsec = boottime.split("sec =")[1].split(",")[0].strip()
        except Exception:
            bsec = ""
    return {"loadavg": loadavg, "processes": nproc, "threads": threads, "boottime": bsec}

def processes_module(limit, sort):
    # ps gives everything DMS reads; %cpu is a lifetime average (instantaneous
    # per-proc deltas would need a proc cursor - honest v1 limitation).
    # command= LAST (only field that holds spaces); comm= is omitted because a
    # system process can have an empty comm, which collapses a positional split.
    rows = sh(["ps", "-A", "-o", "pid=,ppid=,%cpu=,%mem=,rss=,user=,command="]).splitlines()
    procs = []
    for line in rows:
        f = line.split(None, 6)
        if len(f) < 7:
            continue
        pid, ppid, pcpu, pmem, rss, user, command = f
        short = os.path.basename(command.split()[0]) if command.strip() else ""
        try:
            procs.append({
                "pid": int(pid), "ppid": int(ppid),
                "cpu": float(pcpu), "memoryPercent": float(pmem),
                "memoryKB": int(rss),
                "command": short, "fullCommand": command, "username": user,
            })
        except ValueError:
            continue
    key = {"cpu": lambda p: -p["cpu"], "memory": lambda p: -p["memoryKB"],
           "pid": lambda p: p["pid"], "name": lambda p: p["command"].lower()}.get(sort, lambda p: -p["cpu"])
    procs.sort(key=key)
    if limit and limit > 0:
        procs = procs[:limit]
    return procs

def gpu_list():
    out = []
    txt = sh(["system_profiler", "-json", "SPDisplaysDataType"])
    try:
        data = json.loads(txt).get("SPDisplaysDataType", [])
    except Exception:
        data = []
    for i, g in enumerate(data):
        name = g.get("sppci_model") or g.get("_name") or "GPU"
        vraw = g.get("spdisplays_vendor", "") or ""
        vendor = (vraw.replace("sppci_vendor_", "").replace("_", " ").strip()
                  or ("Apple" if name.startswith("Apple") else ""))
        out.append({
            "driver": g.get("spdisplays_metalfamily", ""),
            "vendor": vendor,
            "displayName": name,
            "fullName": name,
            "name": name,
            "pciId": g.get("spdisplays_device-id", "") or f"gpu{i}",
            "temperature": 0,  # needs powermetrics (root) - honest 0
        })
    return out

def hardware_obj():
    prod = sh(["sw_vers", "-productName"]).strip() or "macOS"
    ver = sh(["sw_vers", "-productVersion"]).strip()
    return {
        "hostname": (sh(["scutil", "--get", "ComputerName"]).strip()
                     or sh(["hostname"]).strip()),
        "kernel": sh(["uname", "-r"]).strip(),
        "distro": f"{prod} {ver}".strip(),
        "arch": sh(["uname", "-m"]).strip(),
        "bios": {"motherboard": sysctl("hw.model") or "", "version": ""},
    }

def parse_flags(args):
    flags = {}
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            if i + 1 < len(args) and not args[i + 1].startswith("--"):
                flags[a[2:]] = args[i + 1]; i += 2
            else:
                flags[a[2:]] = True; i += 1
        else:
            i += 1
    return flags

def main(argv):
    if not argv:
        print("usage: dgop <meta|gpu|hardware|cpu|memory|...> [--json ...]", file=sys.stderr)
        return 1
    cmd = argv[0]
    flags = parse_flags(argv[1:])

    if cmd == "gpu":
        print(json.dumps({"gpus": gpu_list()})); return 0
    if cmd == "hardware":
        print(json.dumps(hardware_obj())); return 0

    if cmd == "meta":
        mods = flags.get("modules", "")
        want = set(["cpu", "memory", "network", "disk", "diskmounts", "processes", "system", "gpu-temp"]) \
            if mods == "all" else set(m.strip() for m in str(mods).split(",") if m.strip())
        out = {}
        if "cpu" in want:
            out["cpu"] = cpu_module(flags.get("cpu-cursor"))
        if "memory" in want:
            out["memory"] = memory_module()
        if "network" in want:
            out["network"] = network_module()
        if "disk" in want:
            out["disk"] = []  # no clean cumulative macOS counter - rates read 0 (honest)
        if "diskmounts" in want:
            out["diskmounts"] = diskmounts_module()
        if "system" in want:
            out["system"] = system_module()
        if "gpu-temp" in want or "gpu" in want:
            out["gpu"] = {"gpus": gpu_list()}
        if "processes" in want:
            try:
                limit = int(flags.get("limit", 0))
            except (ValueError, TypeError):
                limit = 0
            out["processes"] = processes_module(limit, flags.get("sort", "cpu"))
        print(json.dumps(out)); return 0

    # single-module one-shots (dgop supports `dgop cpu --json` etc.)
    single = {
        "cpu": lambda: {"cpu": cpu_module(flags.get("cpu-cursor"))},
        "memory": lambda: {"memory": memory_module()},
        "network": lambda: {"network": network_module()},
        "diskmounts": lambda: {"diskmounts": diskmounts_module()},
        "system": lambda: {"system": system_module()},
        "processes": lambda: {"processes": processes_module(int(flags.get("limit", 0) or 0), flags.get("sort", "cpu"))},
    }
    if cmd in single:
        print(json.dumps(single[cmd]())); return 0
    print(f"dgop shim: unsupported subcommand {cmd!r}", file=sys.stderr)
    return 1

if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:
        print(f"dgop shim: {e}", file=sys.stderr)
        sys.exit(1)
DGOP_EOF
chmod +x "$HOME/.local/bin/dgop"

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
