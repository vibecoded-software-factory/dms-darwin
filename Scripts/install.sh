#!/bin/sh
# Build dms-darwin in release, install the binary, and (re)start the
# per-user launchd agent `dev.dms`. The socket path is exported for the
# shell by the DMS installer; this agent serves it.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="${DMS_SOCKET:-/tmp/dms-darwin.sock}"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/dev.dms.plist"

cd "$REPO"
swift build -c release
mkdir -p "$BIN_DIR"
install -m 755 .build/release/dms-darwin "$BIN_DIR/dms-darwin"

# A stable code-signing identity keeps the Bluetooth TCC grant alive across
# rebuilds; an ad-hoc signature re-pins to the per-build hash and macOS
# re-prompts every install (the same reason bento ships as a signed bundle).
# Reuse bento's self-signed "bento codesign" cert if present.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "bento codesign"; then
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
		-k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	codesign --force --sign "bento codesign" --identifier dev.dms.darwin \
		"$BIN_DIR/dms-darwin" 2>/dev/null || true
fi

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

launchctl bootout "gui/$(id -u)/dev.dms" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "dms-darwin installed and started (socket: $SOCKET, log: /tmp/dms-darwin.log)"
