#!/bin/sh
# Build dms-darwin in release, install the binary, and (re)start the
# per-user launchd agent `dev.dms`. The socket path is exported for the
# shell by the DMS installer; this agent serves it.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# `bootout` is asynchronous, and bootstrapping before it finishes leaves the
# agent gone. Shared with Glue/install.sh rather than inlined: both scripts had
# the same bug, and a second copy is how the two drift apart again.
. "$(cd "$(dirname "$0")" && pwd)/lib-launchd.sh"
SOCKET="${DMS_SOCKET:-/tmp/dms-darwin.sock}"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/dev.dms.plist"

APP="$HOME/Applications/DmsDarwin.app"

cd "$REPO"
swift build -c release
mkdir -p "$BIN_DIR"
# `cp`, not `install`: some shells alias `install` to a package manager.
cp .build/release/dms-darwin "$BIN_DIR/dms-darwin"
chmod 755 "$BIN_DIR/dms-darwin"

# The daemon also ships as a .app bundle: the network channel `open`s it in
# `wifi-helper` mode because macOS only unlocks WiFi SSID names for a
# LaunchServices-started app, never a background launchd agent. Same binary,
# same identifier, so the Location/Bluetooth TCC grants are shared.
mkdir -p "$APP/Contents/MacOS"
cp .build/release/dms-darwin "$APP/Contents/MacOS/dms-darwin"
cat > "$APP/Contents/Info.plist" <<'APP_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.dms.darwin</string>
  <key>CFBundleName</key><string>DmsDarwin</string>
  <key>CFBundleExecutable</key><string>dms-darwin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationWhenInUseUsageDescription</key><string>DMS needs your location to read WiFi network names, a macOS requirement for WiFi SSIDs.</string>
  <key>NSLocationUsageDescription</key><string>DMS needs your location to read WiFi network names, a macOS requirement for WiFi SSIDs.</string>
</dict></plist>
APP_PLIST

# A stable code-signing identity keeps the Bluetooth/Location TCC grants alive
# across rebuilds; an ad-hoc signature re-pins to the per-build hash and macOS
# re-prompts every install (the same reason bento ships as a signed bundle).
# Reuse bento's self-signed "bento codesign" cert if present.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "bento codesign"; then
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
		-k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	codesign --force --sign "bento codesign" --identifier dev.dms.darwin \
		"$BIN_DIR/dms-darwin" 2>/dev/null || true
	codesign --force --sign "bento codesign" --identifier dev.dms.darwin \
		"$APP" 2>/dev/null || true
fi
# Register the bundle so `open` (from the network channel) resolves it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>dev.dms</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN_DIR/dms-darwin</string>
		<string>serve</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>DMS_SOCKET</key><string>$SOCKET</string>
	</dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardOutPath</key><string>/tmp/dms-darwin.log</string>
	<key>StandardErrorPath</key><string>/tmp/dms-darwin.log</string>
</dict>
</plist>
PLIST_EOF

# No `|| true`: this daemon IS the install. `set -eu` stops here if it does not
# come up, rather than printing a success line over a dead agent.
restart_agent dev.dms "$PLIST"

echo "dms-darwin installed and started (socket: $SOCKET, log: /tmp/dms-darwin.log)"
