#!/bin/zsh
# Test rig helpers (source it: . vm.sh). Server = Tart VM `remotedisplay-test-server` (admin/admin),
# client = Windows 11 QEMU VM in /Volumes/sam-ex/windows-qemu (ssh -p 2222 user/user, QMP via qmp.py).
# The build Mac runs the real server on 21118, so the VM server is bridged on 21119 ("LAN" route) and
# 21120 ("Tailscale" route via the host's 100.x address): see bridges() below.
export TART_HOME=/Volumes/sam-ex/macOS-tart
SSHOPTS=(-o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8)
vip()  { tart ip "$1" 2>/dev/null; }
_retry() { local n; for n in 1 2 3; do "$@" && return 0; sleep 2; done; return 1; }
vssh() { local vm="$1"; shift; _retry sshpass -p admin ssh "${SSHOPTS[@]}" admin@"$(vip "$vm")" "$@"; }
vcp()  { local vm="$1" src="$2" dst="$3"; _retry sshpass -p admin scp -q -r "${SSHOPTS[@]}" "$src" admin@"$(vip "$vm")":"$dst"; }
vget() { local vm="$1" src="$2" dst="$3"; _retry sshpass -p admin scp -q -r "${SSHOPTS[@]}" admin@"$(vip "$vm")":"$src" "$dst"; }
SRV=remotedisplay-test-server
# Windows 11 QEMU VM (ssh -p 2222 user@127.0.0.1, pass user; QMP via /Volumes/sam-ex/windows-qemu/qmp.py)
W() { sshpass -p user ssh -p 2222 -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR user@127.0.0.1 "$@"; }
Q() { (cd /Volumes/sam-ex/windows-qemu && python3 qmp.py qmp.sock "$@"); }
# Bridges host:21119 and host:21120 (all interfaces) -> server VM :21118. Re-run after a reboot.
bridges() { pkill -f "ssh.*-L 0.0.0.0:21119" 2>/dev/null; sleep 1; local ip; ip=$(vip $SRV)
  sshpass -p admin ssh "${SSHOPTS[@]}" -o ServerAliveInterval=15 -o ExitOnForwardFailure=yes -f -N \
    -L 0.0.0.0:21119:127.0.0.1:21118 -L 0.0.0.0:21120:127.0.0.1:21118 admin@"$ip" && echo "bridges up -> $ip"; }
# Screenshot of the Windows VM (QMP screendump only writes inside the QEMU folder) -> $1
wshot() { Q shot /Volumes/sam-ex/windows-qemu/_shot.png >/dev/null && cp /Volumes/sam-ex/windows-qemu/_shot.png "$1"; }
# Click at 1920x1080 guest coordinates.
wclick() { Q click "$1" "$2" 1920 1080 >/dev/null; }
