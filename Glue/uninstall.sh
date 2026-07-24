#!/bin/sh
# Tear down the DankMaterialShell login agent installed by install.sh.
# Leaves this repo and the bento build in place; only stops and unregisters the
# agent and removes the app bundle. Re-run install.sh to bring it back.
set -e

LABEL="dev.bento"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Bento.app"

echo ">> Stopping the agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo ">> Removing $PLIST"
rm -f "$PLIST"

echo ">> Removing $APP"
rm -rf "$APP"

echo "Done. DankMaterialShell will no longer start at login."
