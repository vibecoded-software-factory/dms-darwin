#!/bin/sh
# Install DankMaterialShell as the macOS login shell, rendered by bento-box
# (the quickshell macOS port) under the nigiri compositor.
#
# What it sets up:
#   - ~/Applications/Bento.app         a signed bundle of the bento binary, so
#                                      the login agent has a stable TCC identity
#                                      (the same reason nigiri ships as an .app)
#   - ~/.local/share/dms-darwin/shell  the assembled shell root: one symlink per
#                                      entry of the DankMaterialShell checkout,
#                                      plus our own entry point and wallpaper
#                                      bridge (Glue/qml) as real files
#   - ~/Library/LaunchAgents/dev.bento.plist   runs it at login, kept alive
#
# Re-runnable: rebuilds, re-bundles, reassembles the staging root, and restarts
# the agent. `uninstall.sh` tears it back down.
set -e

# This script is VERSIONED IN dms-darwin (Glue/) and run AGAINST the DMS
# checkout, which is third-party and strictly READ-ONLY: it is only ever read
# from - never patched, never written into. Our own QML lives in Glue/qml and
# reaches bento through the staging root below.
# Default assumes the standard sibling layout; override with DMS_DIR.
DMS_DIR="${DMS_DIR:-$(cd "$(dirname "$0")/../../DankMaterialShell" && pwd)}"
SHELL_DIR="$DMS_DIR/quickshell"
# Our own QML, versioned here rather than in DMS - see the staging tree below.
GLUE_QML="$(cd "$(dirname "$0")" && pwd)/qml"
# The assembled shell root bento is actually pointed at. NOT inside DMS: that
# checkout is third-party and read-only.
STAGE_DIR="${DMS_STAGE_DIR:-$HOME/.local/share/dms-darwin/shell}"
# Same sibling assumption as DMS_DIR, and resolved the same way: the previous
# default was an absolute path from the machine this was written on, so a clone
# anywhere else failed on the first run. Override with BENTO_REPO.
BENTO_REPO="${BENTO_REPO:-$(cd "$(dirname "$0")/../../bento-box" && pwd)}"
# The bundle and the agent label are bento-box's to create - these two are here
# only because the `dms` CLI shim below has to point at them (`dms ipc` runs the
# bundled binary; `dms restart` kickstarts the label). The build dir, the plist
# path and the log path are NOT here: they belong to bento-box's installer, and
# a second copy of them is what let the two scripts drift apart.
APP="$HOME/Applications/Bento.app"
LABEL="dev.bento"
NIRI_SOCKET="${NIRI_SOCKET:-/tmp/nigiri-msg.sock}"
# The darwin system daemon (dms-darwin) serving brightness/night/etc over
# the DMS daemon protocol; installed by its own repo's Scripts/install.sh.
DMS_SOCKET="${DMS_SOCKET:-/tmp/dms-darwin.sock}"

# Shared with Scripts/install.sh - see there for why this is not inlined.
. "$(cd "$(dirname "$0")/../Scripts" && pwd)/lib-launchd.sh"


# Drift guard: Glue/qml/shell-macos.qml embeds a copy of upstream shell.qml's
# body (QML has no include; the wrapper adds the Mac bridge + audio tap around
# the same loaders). If upstream shell.qml changes, that copy must be reviewed -
# warn LOUDLY instead of drifting silently.
SHELL_QML_EXPECTED="e33a870ba8a89c1ac27108ffcbd6a9f2b51e6d0b85df1f827ce0a0f81ab45c19"
SHELL_QML_ACTUAL="$(shasum -a 256 "$SHELL_DIR/shell.qml" | cut -d' ' -f1)"
if [ "$SHELL_QML_ACTUAL" != "$SHELL_QML_EXPECTED" ]; then
    echo "!! WARNING: upstream shell.qml changed since the macOS wrapper was written." >&2
    echo "!!          Review Glue/qml/shell-macos.qml against it, then update" >&2
    echo "!!          SHELL_QML_EXPECTED. Continuing with the old wrapper body." >&2
fi

echo ">> Assembling the shell staging tree in $STAGE_DIR"
# DankMaterialShell is THIRD-PARTY and strictly READ-ONLY: nothing of ours is
# ever written into its tree - not the entry point, not the wallpaper bridge,
# not a patch. `git status` in that checkout must stay clean.
#
# That is not free, because bento roots `import qs.*` and every relative
# `source:` at the DIRECTORY OF THE -p FILE (core/rootwrapper.cpp:
# `auto rootPath = rootFile.dir()`). A wrapper living outside the upstream tree
# and pointing back at it would resolve its imports next to ITSELF and find
# nothing.
#
# So assemble a staging root that IS a valid shell root: one symlink per
# top-level entry of the upstream tree, plus our own files as real files
# beside them. bento's scanner lists a symlink like any other entry
# (core/scan.cpp walks with QDir::Files, which drops nothing unless
# NoSymLinks is passed), so `import qs.Common` resolves through the link into
# DMS while DMS itself is never touched.
#
# Rebuilt from scratch every run: a link to a file upstream has since renamed
# would otherwise linger forever, and a stale QML file is a silent failure.
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
links=0
for entry in "$SHELL_DIR"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    # Never link our own names: they are placed as real files below, and an
    # upstream file that ever took one of these names would win the link.
    case "$name" in
    shell-macos.qml | MacWallpaperBridge.qml) continue ;;
    esac
    ln -sfn "$entry" "$STAGE_DIR/$name"
    links=$((links + 1))
done
# The real files: versioned in THIS repo (Glue/qml), copied in. Editing them
# means re-running this script - which is already how every other change lands.
cp "$GLUE_QML/shell-macos.qml" "$GLUE_QML/MacWallpaperBridge.qml" "$STAGE_DIR/"
echo "   $links links into DMS + 2 files of ours"

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
    # bento backs panel surfaces with a real blur: BackgroundEffect.blurRegion
    # drives an NSVisualEffectView in `behindWindow` blending mode, masked to
    # the region (src/mac/wayland/wayland.cpp + src/mac/bridge.mm). That is the
    # macOS stand-in for ext-background-effect-v1, which is what BlurService is
    # probing for, so report it supported and let the shell enable its blurred
    # surfaces.
    [ "$2" = "check" ] && { echo supported; exit 0; }
    echo "dms (darwin shim): blur subcommand '$2' is not ported" >&2
    exit 1
    ;;
color)
    # `dms color pick --json` -> the DankColorPickerModal eyedropper. The Go
    # CLI samples via Wayland screencopy; the niri path is inert. dms-darwin
    # drives the native NSColorSampler and prints {"hex":"#RRGGBB"}.
    if [ "$2" = "pick" ]; then
        exec dms-darwin color-pick
    fi
    echo "dms (darwin shim): color subcommand '$2' is not ported" >&2
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
    # Everything else (matugen, keybinds, config, setup, update, version, ...)
    # is served by the REAL dms binary, which builds and runs on macOS
    # (dms-real, installed below from DankMaterialShell/core + darwin stubs).
    if [ -x "$HOME/.local/bin/dms-real" ]; then
        exec "$HOME/.local/bin/dms-real" "$@"
    fi
    echo "dms (darwin shim): '$1' needs dms-real (not installed); ran install.sh?" >&2
    exit 1
    ;;
esac
EOF
sed -i '' -e "s|__LABEL__|$LABEL|g" -e "s|__APP__|$APP|g" -e "s|__SHELL_DIR__|$STAGE_DIR|g" "$HOME/.local/bin/dms"
chmod +x "$HOME/.local/bin/dms"

echo ">> Ensuring matugen (Material-You color generation) is on PATH"
# matugen drives DMS's dynamic theming (via `dms matugen queue`). It must be on
# the launchd agent PATH (~/.local/bin, /opt/homebrew/bin). Prefer brew; else
# cargo install + symlink into ~/.local/bin.
if ! command -v matugen >/dev/null 2>&1; then
    brew install matugen >/dev/null 2>&1 \
        || { command -v cargo >/dev/null 2>&1 && cargo install matugen >/dev/null 2>&1; }
fi
if ! [ -x /opt/homebrew/bin/matugen ] && [ -x "$HOME/.cargo/bin/matugen" ]; then
    ln -sf "$HOME/.cargo/bin/matugen" "$HOME/.local/bin/matugen"
fi

echo ">> Building the real dms CLI (dms-real: matugen/keybinds/config)"
# The dms CLI subcommands the shim forwards (matugen queue, keybinds, config,
# setup, update) are Go and BUILD+RUN on macOS - only 5 tiny darwin platform
# stubs are missing from DankMaterialShell/core. Build the real binary from the
# local DMS checkout's core + these stubs. matugen theming (BIN-2), keybinds
# (BIN-3) and config (BIN-12) then work with the real tool.
DMS_CORE="$DMS_DIR/core"
command -v go >/dev/null 2>&1 || brew install go >/dev/null 2>&1 || true
if [ -d "$DMS_CORE" ] && command -v go >/dev/null 2>&1; then
    DMSBUILD=$(mktemp -d)
    cp -R "$DMS_CORE/." "$DMSBUILD/"
    cat > "$DMSBUILD/internal/wayland/shm/fd_darwin.go" <<'GO_EOF'
package shm

import (
	"os"

	"golang.org/x/sys/unix"
)

// macOS has no memfd/SHM_ANON; a deleted temp file gives an anonymous fd. Only
// needs to link: the Wayland manager that uses it never inits on macOS.
func CreateAnonFd(name string) (int, error) {
	f, err := os.CreateTemp("", name+"-*")
	if err != nil {
		return -1, err
	}
	os.Remove(f.Name())
	fd, err := unix.Dup(int(f.Fd()))
	f.Close()
	if err != nil {
		return -1, err
	}
	return fd, nil
}
GO_EOF
    cat > "$DMSBUILD/internal/matugen/signal_darwin.go" <<'GO_EOF'
package matugen

import (
	"os/exec"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

func signalByName(name string, sig syscall.Signal) {
	signame := strings.TrimPrefix(unix.SignalName(sig), "SIG")
	exec.Command("pkill", "-"+signame, "-x", name).Run()
}
GO_EOF
    cat > "$DMSBUILD/internal/server/trayrecovery/suspend_darwin.go" <<'GO_EOF'
package trayrecovery

import "time"

func timeSuspended() time.Duration { return 0 }
GO_EOF
    cat > "$DMSBUILD/internal/trash/mounts_darwin.go" <<'GO_EOF'
package trash

import "golang.org/x/sys/unix"

func readMountPoints() []string {
	n, err := unix.Getfsstat(nil, unix.MNT_NOWAIT)
	if err != nil || n == 0 {
		return nil
	}
	stats := make([]unix.Statfs_t, n)
	n, err = unix.Getfsstat(stats, unix.MNT_NOWAIT)
	if err != nil {
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for _, st := range stats[:n] {
		mp := unix.ByteSliceToString(st.Mntonname[:])
		if mp == "" || skipMountPoint(mp, seen) {
			continue
		}
		seen[mp] = true
		out = append(out, mp)
	}
	return out
}
GO_EOF
    cat > "$DMSBUILD/internal/server/brightness/native_darwin.go" <<'GO_EOF'
package brightness

import "github.com/AvengeMedia/DankMaterialShell/core/internal/log"

// No sysfs/DDC backlight on macOS; brightness is served by the Swift
// dms-darwin daemon (DisplayServices). Stays hollow so the Go build links.
func (m *Manager) initNative() {
	log.Debug("brightness: no native backend on macOS (served by dms-darwin)")
}
GO_EOF
    ( cd "$DMSBUILD" && GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/dms-real" ./cmd/dms ) \
        && echo "   dms-real built" || echo "!! dms-real build failed" >&2
    # dms-serve: the headless Go daemon (server.New().Listen().Serve()) - the
    # portable half of the DMS daemon on macOS, fronted by the mux.
    mkdir -p "$DMSBUILD/cmd/dms-serve"
    cat > "$DMSBUILD/cmd/dms-serve/main.go" <<'GO_EOF'
package main

import (
	"log"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/server"
)

func main() {
	s := server.New()
	if err := s.Listen(); err != nil {
		log.Fatal(err)
	}
	log.Println("dms-serve on", s.SocketPath())
	if err := s.Serve(false); err != nil {
		log.Fatal(err)
	}
}
GO_EOF
    ( cd "$DMSBUILD" && GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/dms-serve" ./cmd/dms-serve ) \
        && echo "   dms-serve built" || echo "!! dms-serve build failed" >&2
    rm -rf "$DMSBUILD"
else
    echo "!! dms-real: no go or no DMS core; matugen/keybinds stay off" >&2
fi
# The dms CLI resolves the niri config via macOS UserConfigDir
# (~/Library/Application Support/niri); the ecosystem uses ~/.config/niri.
# Bridge them so keybinds/config read the real file.
APPSUP="$HOME/Library/Application Support"
mkdir -p "$APPSUP"
[ -e "$APPSUP/niri" ] || ln -s "$HOME/.config/niri" "$APPSUP/niri"

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

# cp: DMS runs GNU-only flags (cp --no-preserve=mode, in NiriService's blur-rule
# copy) that BSD cp rejects with a usage error (exit 64). Strip the GNU-only
# flags and delegate to the real cp; plain cp passes through unchanged.
cat > "$HOME/.local/bin/cp" <<'CP_EOF'
#!/bin/sh
args=""
for a in "$@"; do
    case "$a" in
    --no-preserve=*|--preserve=*|--reflink*|--sparse=*) ;;
    *) args="$args \"$a\"" ;;
    esac
done
eval exec /bin/cp $args
CP_EOF
chmod +x "$HOME/.local/bin/cp"

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

# notify-send: DMS raises its own alerts (battery, portal errors) through
# notify-send, as can any app/script. Deliver each to the DMS NotificationServer
# socket (bento's Quickshell.Services.Notifications backend) so DMS's own popups
# and notification center light up - the macOS analog of being the freedesktop
# notification server. Fall back to the system Notification Center when the
# shell is not running so nothing is silently lost.
cat > "$HOME/.local/bin/notify-send" <<'NS_EOF'
#!/bin/sh
SOCK=/tmp/dms-notifications.sock
urgency=1; app=""; icon=""; timeout=-1; replace=0; title=""; body=""
while [ $# -gt 0 ]; do
    case "$1" in
    -u|--urgency)
        case "$2" in low) urgency=0 ;; critical) urgency=2 ;; *) urgency=1 ;; esac
        shift 2 ;;
    -a|--app-name) app="$2"; shift 2 ;;
    -i|--icon) icon="$2"; shift 2 ;;
    -t|--expire-time) timeout="$2"; shift 2 ;;
    -r|--replace-id) replace="$2"; shift 2 ;;
    -c|--category|-h|--hint) shift 2 ;;
    -e|-p|-w|--*) shift ;;
    *) if [ -z "$title" ]; then title="$1"; else body="$1"; fi; shift ;;
    esac
done

if [ -S "$SOCK" ] && \
    SOCK_PATH="$SOCK" APP="$app" ICON="$icon" URG="$urgency" TO="$timeout" \
    REPL="$replace" TITLE="$title" BODY="$body" python3 -c '
import os, socket, json, sys
o = {"appName": os.environ["APP"] or "notify-send", "appIcon": os.environ["ICON"],
     "summary": os.environ["TITLE"], "body": os.environ["BODY"],
     "urgency": int(os.environ["URG"]), "expireTimeout": float(os.environ["TO"]),
     "replacesId": int(os.environ["REPL"] or 0)}
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(1)
    s.connect(os.environ["SOCK_PATH"]); s.sendall((json.dumps(o) + "\n").encode()); s.close()
except Exception:
    sys.exit(1)
' 2>/dev/null; then
    exit 0
fi

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
osascript -e "display notification \"$(esc "$body")\" with title \"$(esc "$title")\""
NS_EOF
chmod +x "$HOME/.local/bin/notify-send"

# dgop: the real dgop (github.com/AvengeMedia/dgop) is officially cross-platform
# and ships signed macOS release binaries, so install the REAL tool - no shim,
# no port. Powers the system monitor, process list, and CPU/RAM/temp/disk/
# network widgets. Pinned to a known-good release, sha256-verified.
DGOP_VERSION="${DGOP_VERSION:-v0.2.3}"
DGOP_ARCH=$(uname -m); case "$DGOP_ARCH" in arm64) DGOP_ARCH=arm64;; x86_64) DGOP_ARCH=amd64;; esac
DGOP_URL="https://github.com/AvengeMedia/dgop/releases/download/$DGOP_VERSION/dgop-darwin-$DGOP_ARCH.tar.gz"
DGOP_TMP=$(mktemp -d)
if curl -sfL -o "$DGOP_TMP/d.tar.gz" "$DGOP_URL" \
    && curl -sfL -o "$DGOP_TMP/d.sha256" "$DGOP_URL.sha256"; then
    if [ "$(cut -d' ' -f1 "$DGOP_TMP/d.sha256")" = "$(shasum -a 256 "$DGOP_TMP/d.tar.gz" | cut -d' ' -f1)" ]; then
        tar xzf "$DGOP_TMP/d.tar.gz" -C "$DGOP_TMP"
        DGOP_BIN=$(find "$DGOP_TMP" -type f -name 'dgop*' ! -name '*.gz' ! -name '*.sha256' | head -1)
        [ -n "$DGOP_BIN" ] && cp "$DGOP_BIN" "$HOME/.local/bin/dgop" \
            && chmod 0755 "$HOME/.local/bin/dgop" \
            && echo "   dgop $DGOP_VERSION installed"
    else
        echo "!! dgop: sha256 mismatch, not installing (system monitor stays off)" >&2
    fi
else
    echo "!! dgop: download failed, system monitor stays off ($DGOP_URL)" >&2
fi
rm -rf "$DGOP_TMP"

echo ">> Installing ghostty (terminal for the launcher and tmux/mux)"
# DMS launches a terminal for `run in terminal` desktop entries and tmux
# attach; it probes for ghostty/kitty/... on PATH. ghostty ships a macOS build.
[ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ] || brew install --cask ghostty >/dev/null 2>&1 || true
if [ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]; then
    ln -sf /Applications/Ghostty.app/Contents/MacOS/ghostty "$HOME/.local/bin/ghostty"
    echo "   ghostty CLI linked"
fi

echo ">> Installing dsearch (filesystem search for the launcher)"
# danksearch ships no macOS release binary, but its Go source builds and runs
# on darwin (Bleve index, cross-platform). Build the pinned release from source
# (needs go; installed via brew). DMS queries the index via `dsearch search`;
# it does NOT start the indexer, so we run `dsearch serve` as a launch agent.
command -v go >/dev/null 2>&1 || brew install go >/dev/null 2>&1 || true
DSEARCH_VERSION="${DSEARCH_VERSION:-v0.3.2}"
DSEARCH_SRC=$(mktemp -d)
if git clone --quiet --depth 1 --branch "$DSEARCH_VERSION" \
    https://github.com/AvengeMedia/danksearch "$DSEARCH_SRC" 2>/dev/null; then
    ( cd "$DSEARCH_SRC" && GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/dsearch" ./cmd/dsearch ) \
        && echo "   dsearch $DSEARCH_VERSION built" || echo "!! dsearch build failed" >&2
else
    echo "!! dsearch: clone failed, launcher file search stays off" >&2
fi
rm -rf "$DSEARCH_SRC"
if [ -x "$HOME/.local/bin/dsearch" ]; then
    DSEARCH_PLIST="$HOME/Library/LaunchAgents/dev.dsearch.plist"
    cat > "$DSEARCH_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.dsearch</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/dsearch</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>/tmp/dsearch.log</string>
    <key>StandardErrorPath</key><string>/tmp/dsearch.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST_EOF
    restart_agent dev.dsearch "$DSEARCH_PLIST" || true
fi

echo ">> Installing dcal (calendar: local, Google, Microsoft, CalDAV, iCloud)"
# dankcalendar ships no macOS release binary, but its Go source builds and runs
# on darwin out of the box (native iCloud/Google/CalDAV support). Build from
# source and run `dcal daemon` (the UI-less IPC mode; the `run` mode DMS calls
# needs an embedded UI our source build lacks) as a launch agent. DMS discovers
# the socket via XDG_RUNTIME_DIR, which the bento plist above pins to the same
# dir. Add your calendar account with `dcal account add icloud` (interactive).
command -v go >/dev/null 2>&1 || brew install go >/dev/null 2>&1 || true
mkdir -p "$HOME/.local/state/dms-run" && chmod 700 "$HOME/.local/state/dms-run"
DCAL_SRC=$(mktemp -d)
if git clone --quiet --depth 1 https://github.com/AvengeMedia/dankcalendar "$DCAL_SRC" 2>/dev/null; then
    # Built from core/, not the repo root: upstream keeps go.mod in core/, so a
    # build launched from the root fails with "cannot find main module" and the
    # install silently kept whatever old dcal happened to be on disk.
    ( cd "$DCAL_SRC/core" && GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/dcal" ./cmd/dcal ) \
        && echo "   dcal built" || echo "!! dcal build failed" >&2
else
    echo "!! dcal: clone failed, calendar backend stays off" >&2
fi
rm -rf "$DCAL_SRC"
if [ -x "$HOME/.local/bin/dcal" ]; then
    DCAL_PLIST="$HOME/Library/LaunchAgents/dev.dcal.plist"
    cat > "$DCAL_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.dcal</string>
    <key>ProgramArguments</key>
    <array><string>$HOME/.local/bin/dcal</string><string>daemon</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>XDG_RUNTIME_DIR</key><string>$HOME/.local/state/dms-run</string>
        <!-- Post-capture screenshot editor: open in Preview (has markup). -->
        <key>DMS_SCREENSHOT_EDITOR</key><string>open -a Preview %path%</string>
        <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>/tmp/dcal.log</string>
    <key>StandardErrorPath</key><string>/tmp/dcal.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST_EOF
    restart_agent dev.dcal "$DCAL_PLIST" || true
    echo "   (add a calendar account with: dcal account add icloud)"
fi

echo ">> Building dms-mux and wiring the daemon coexistence"
# The Go daemon (dms-serve) serves the portable capabilities; the Swift daemon
# (dms-darwin) serves the macOS-native ones. DMS talks to ONE socket, so a mux
# owns $DMS_SOCKET, dials both, merges their capability handshakes, and routes
# by service. See Glue/dms-mux/.
MUX_SRC="$(cd "$(dirname "$0")" && pwd)/dms-mux"
if [ -d "$MUX_SRC" ] && command -v go >/dev/null 2>&1; then
    ( cd "$MUX_SRC" && GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/dms-mux" . ) \
        && echo "   dms-mux built" || echo "!! dms-mux build failed" >&2
fi
XRD="$HOME/.local/state/dms-run"; mkdir -p "$XRD"
DMS_REAL_SOCKET="${DMS_SOCKET:-/tmp/dms-darwin.sock}"
DMS_NATIVE_SOCKET="/tmp/dms-darwin-native.sock"
if [ -x "$HOME/.local/bin/dms-serve" ] && [ -x "$HOME/.local/bin/dms-mux" ]; then
    # (a) move the Swift daemon (dev.dms) to the native side socket
    if [ -f "$HOME/Library/LaunchAgents/dev.dms.plist" ]; then
        /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:DMS_SOCKET $DMS_NATIVE_SOCKET" \
            "$HOME/Library/LaunchAgents/dev.dms.plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DMS_SOCKET string $DMS_NATIVE_SOCKET" \
               "$HOME/Library/LaunchAgents/dev.dms.plist"
        restart_agent dev.dms "$HOME/Library/LaunchAgents/dev.dms.plist" || true
    fi
    # (b) the Go daemon
    cat > "$HOME/Library/LaunchAgents/dev.dms-go.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.dms-go</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/dms-serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>XDG_RUNTIME_DIR</key><string>$XRD</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>/tmp/dms-go.log</string><key>StandardErrorPath</key><string>/tmp/dms-go.log</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST_EOF
    restart_agent dev.dms-go "$HOME/Library/LaunchAgents/dev.dms-go.plist" || true
    sleep 2
    # (c) the mux on the real $DMS_SOCKET
    cat > "$HOME/Library/LaunchAgents/dev.dms-mux.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.dms-mux</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/dms-mux</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>DMS_SOCKET</key><string>$DMS_REAL_SOCKET</string>
    <key>DMS_GO_SOCKET</key><string>$XRD/danklinux-*.sock</string>
    <key>DMS_SWIFT_SOCKET</key><string>$DMS_NATIVE_SOCKET</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>/tmp/dms-mux.log</string><key>StandardErrorPath</key><string>/tmp/dms-mux.log</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST_EOF
    restart_agent dev.dms-mux "$HOME/Library/LaunchAgents/dev.dms-mux.plist" || true
    echo "   daemon coexistence wired (swift=native, go, mux on $DMS_REAL_SOCKET)"
fi

echo ">> Installing bento (delegated to bento-box)"
# The bento half - build, bundle, sign, plist, agent - belongs to bento-box and
# is done by ITS installer. This script used to carry a second copy of all of
# it, and the copy had drifted: it signed ad-hoc when it could not find the
# certificate (silently dropping every TCC grant), never verified what it had
# signed, and wrote a plist missing DMS_SCREENSHOT_EDITOR. Running the two in
# either order overwrote the other's work.
#
# What stays here is what is genuinely ours: the staging root assembled above,
# the shims, the daemons and their coexistence. Everything bento-specific is
# passed in as environment, which is exactly the interface that script already
# documents.
# BENTO_AGENT_PATH is deliberately NOT passed: bento-box already defaults it to
# the same list, and a second copy here is how this file drifted from that one
# in the first place.
BENTO_SHELL_QML="$STAGE_DIR/shell-macos.qml" \
DMS_SOCKET="$DMS_SOCKET" \
NIRI_SOCKET="$NIRI_SOCKET" \
XDG_RUNTIME_DIR="$XRD" \
    "$BENTO_REPO/Scripts/install.sh"

echo ""
echo "Done. DankMaterialShell is running and will start at login."
echo "  uninstall: $(dirname "$0")/uninstall.sh"
