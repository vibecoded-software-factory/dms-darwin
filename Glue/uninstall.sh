#!/bin/sh
# Tear down the DankMaterialShell login agent installed by install.sh.
# Leaves this repo and the bento build in place; stops and unregisters the
# agent, and removes what install.sh created outside the repos. Re-run
# install.sh to bring it back.
set -e

LABEL="dev.bento"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Bento.app"
# The assembled shell root. Entirely install.sh's output - symlinks into the
# read-only DMS checkout plus copies of Glue/qml - so removing it destroys
# nothing that is not regenerated on the next run. Kept in step with install.sh.
STAGE_DIR="${DMS_STAGE_DIR:-$HOME/.local/share/dms-darwin/shell}"

echo ">> Stopping the agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo ">> Removing $PLIST"
rm -f "$PLIST"

echo ">> Removing $APP"
rm -rf "$APP"

echo ">> Removing the shell staging root $STAGE_DIR"
# Symlinks are removed as links: rm -rf on a directory of symlinks unlinks them
# and never follows into the DMS checkout they point at.
rm -rf "$STAGE_DIR"

echo "Done. DankMaterialShell will no longer start at login."
