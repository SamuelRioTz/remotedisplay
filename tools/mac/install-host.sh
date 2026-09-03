#!/bin/bash
# Installs the headless Remote Display host on the Mac (run ON the Mac).
# Usage: bash install-host.sh <permanent-password>
#
# Headless alternative (no menu bar) to server-mac/'s "Remote Display Server.app".
# The two share port 21118 and the IPC socket, so they are MUTUALLY EXCLUSIVE:
# this script boots out the app before starting to avoid a double bind.
set -e

PASS="${1:?Usage: install-host.sh <password>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# Engine binary. Override with ENGINE_BIN=<path>. Defaults to trying the repo's
# build (engine/rustdesk) and, failing that, the legacy mirror checkout.
INSTALL_DIR="$HOME/.local/share/remotedisplay"
CONF_DIR="$HOME/Library/Preferences/RemoteDisplay"
UID_NUM="$(id -u)"

if [ -n "${ENGINE_BIN:-}" ]; then
    BIN_SRC="$ENGINE_BIN"
elif [ -x "$DIR/../../engine/rustdesk/target/release/rustdesk" ]; then
    BIN_SRC="$DIR/../../engine/rustdesk/target/release/rustdesk"
else
    BIN_SRC="$HOME/dev/rustdesk/target/release/rustdesk"
fi
test -x "$BIN_SRC" || { echo "ERROR: engine binary does not exist: $BIN_SRC (did it build? use ENGINE_BIN=<path>)"; exit 1; }

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$HOME/Library/LaunchAgents"
cp -f "$BIN_SRC" "$INSTALL_DIR/rustdesk"

# Sign with a stable identity if one exists (TCC permissions survive rebuilds).
# Create it once with Keychain Access: a "Code Signing" certificate named RemoteDisplaySign.
if security find-identity -v -p codesigning 2>/dev/null | grep -q RemoteDisplaySign; then
    codesign --force --sign RemoteDisplaySign --identifier app.remotedisplay.engine "$INSTALL_DIR/rustdesk"
    echo "Binary signed with RemoteDisplaySign"
else
    echo "WARNING: no RemoteDisplaySign certificate — the TCC permission is invalidated on every rebuild (see README)"
fi

# Config locked to LAN (before the first launch)
cp -f "$DIR/RemoteDisplay2.toml" "$CONF_DIR/RemoteDisplay2.toml"

# Avoid conflicting with "Remote Display Server.app" (same port/IPC socket).
launchctl bootout "gui/$UID_NUM/app.remotedisplay.server" 2>/dev/null || true

# LaunchAgent: starts with the session
# The plist is a template: absolute paths for the real user (portable).
sed -e "s#__INSTALL_DIR__#$INSTALL_DIR#g" -e "s#__HOME__#$HOME#g" "$DIR/app.remotedisplay.engine.plist" > "$HOME/Library/LaunchAgents/app.remotedisplay.engine.plist"
launchctl bootout "gui/$UID_NUM/app.remotedisplay.engine" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/app.remotedisplay.engine.plist"
launchctl kickstart -k "gui/$UID_NUM/app.remotedisplay.engine"

# Permanent password: the --password flag is blocked by the is_installed()/is_root()
# gate (the engine doesn't live in /Applications/RustDesk.app).
# --set-lan-password is used instead, which talks IPC to the engine ALREADY running —
# so we have to wait for the daemon to bring up the socket.
PW_OK=0
for i in $(seq 1 15); do
    if "$INSTALL_DIR/rustdesk" --set-lan-password "$PASS" 2>&1 | grep -q "Done!"; then
        PW_OK=1
        echo "Permanent password set"
        break
    fi
    sleep 1
done
[ "$PW_OK" = "1" ] || { echo "ERROR: could not set the password (did the engine start? check $INSTALL_DIR/rustdesk.log)"; exit 1; }

echo "OK: host running on port 21118 (log: $INSTALL_DIR/rustdesk.log)"
