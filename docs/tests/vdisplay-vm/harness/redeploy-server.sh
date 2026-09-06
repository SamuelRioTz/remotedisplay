#!/bin/zsh
# Rebuilds the server engine + app bundle from the working tree and swaps it into the
# Tart server VM (`remotedisplay-test-server`), then relaunches it. TCC grants survive
# (same signing identity and requirement). Usage: redeploy-server.sh [--no-build]
set -e
cd "$(dirname "$0")"; . ./vm.sh
ROOT=$(cd ../../../.. && pwd)
if [ "$1" != "--no-build" ]; then
  ( cd "$ROOT/engine/rustdesk" && VCPKG_ROOT="${VCPKG_ROOT:-$HOME/vcpkg}" cargo build --release --features hwcodec --bin rustdesk 2>&1 | grep -E "^error|Finished" )
fi
( cd "$ROOT/server-mac" && make sign ENGINE_BIN="$ROOT/engine/rustdesk/target/release/rustdesk" 2>&1 | tail -2 )
T=$(mktemp -d); tar -C "$ROOT/server-mac/.build" -czf "$T/server-app.tgz" "Remote Display Server.app"
vcp $SRV "$T/server-app.tgz" /Users/admin/server-app.tgz; rm -rf "$T"
vssh $SRV 'launchctl bootout gui/501/app.remotedisplay.server 2>/dev/null || true; pkill -x RemoteDisplayServer || true; pkill -f "remotedisplayd --server" || true; sleep 1
  sudo rm -rf "/Applications/Remote Display Server.app"; sudo tar -C /Applications -xzf ~/server-app.tgz; sudo chown -R admin:staff "/Applications/Remote Display Server.app"
  xattr -dr com.apple.quarantine "/Applications/Remote Display Server.app" 2>/dev/null || true
  nohup open "/Applications/Remote Display Server.app" >/dev/null 2>&1 &
  sleep 10; ps -A -o pid,etime,args | grep -E "remotedisplayd --server|RemoteDisplayServer$" | grep -v grep | cut -c1-100
  (nc -z -w 3 127.0.0.1 21118 && echo "21118 open") || echo "21118 CLOSED"'
