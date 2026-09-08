# Tart VM tests — macOS virtual displays (2026-09-01)

Verification of the dynamic virtual displays feature (in-process CGVirtualDisplay
in the engine) done on 2 clean Tart VMs with
`ghcr.io/cirruslabs/macos-tahoe-base` (macOS 26.6.2, SIP off).

## What was tested and the result

1. **Native harness** (`harness/vdisplay_test.mm`, links the real `macos.mm`):
   create/hot-resize with a stable displayID/destroy; dynamic main
   (primary virtual + mirrored physical), resize with an active mirror, clean
   OFF, 2 full cycles. **26/26 PASS** in the guest.
2. **Rust integration test** (`harness/rusttest/`): the exact `mac_vdisplay`
   wrappers that `Connection` invokes (plug_in/out, routing of
   the dynamic main's index -2, `change_resolution_if_is_virtual_display`,
   `reset_all`). **ALL OK** in the guest.
3. **Real client↔server**: headless engine on VM1 (TCC via sqlite, SIP off),
   Flutter app on VM2 connected through an SSH tunnel via the host (Tart VMs
   can't see each other). Screenshots in `capturas/`.

## Screenshots (not included in the public repo)

- `client1.png` first attempt: Local Network prompt + connection failure
  (Tart's VM-VM isolation, solved with a tunnel via the host).
- `c4.png` **connected**: "127.0.0.1" session with VM1's desktop behind
  the prompts.
- `c5.png`-`c7.png` cascade of macOS 26 permission prompts on the client;
  VM1's remote desktop streaming live.
- `c8.png` clean session: VM1's full desktop in the client
  window, toolbar pill visible.
- `c9.png`-`c11.png` toolbar navigation (per-pixel clicking on the Flutter
  canvas turned out to be fragile; the menu→backend leg was covered instead by the
  deterministic Rust test).

## Runtime findings (macOS 26) the code already handles

- Destroying a CGVirtualDisplay that was a mirror master leaves a permanent
  ghost display → the dynamic main's virtual is cached disabled
  (`CGSConfigureDisplayEnabled`) and recycled; it dies with the process.
- `applySettings` doesn't switch the mode if the display is main or a mirror
  master → conditional commit-nudge + escalation to `CGConfigureDisplayWithDisplayMode`.
- Re-promoting the physical display after turning off the dynamic main must be explicit and
  awaited; chaining mirror configs without letting them settle produces cycles (screen
  with 0 active displays).

## Re-running

On a Tart VM (or a test Mac — it creates/destroys real displays):

```sh
# native harness
xcrun clang++ -std=c++17 -fobjc-exceptions harness/vdisplay_test.mm \
  ../../../engine/rustdesk/src/platform/macos.mm -o /tmp/vdisplay_test \
  -framework Foundation -framework CoreGraphics -framework AppKit \
  -framework AVFoundation -framework IOKit -framework Security -framework CoreMedia
codesign --force --sign - /tmp/vdisplay_test && /tmp/vdisplay_test

# Rust test (compiles against the engine's macos.mm)
cd harness/rusttest && cargo run --release
```

Mirror-mode harness (also links the engine's real `macos.mm` and reconfigures displays
for real; because everything uses `kCGConfigureForSession`, any mirror left behind
reverts on logout):

```sh
xcrun clang++ -std=c++17 -fobjc-exceptions harness/mirror_mode_test.mm \
  ../../../engine/rustdesk/src/platform/macos.mm -o /tmp/mirror_mode_test \
  -framework Foundation -framework CoreGraphics -framework AppKit \
  -framework AVFoundation -framework IOKit -framework Security -framework CoreMedia -framework ColorSync
codesign --force --sign - /tmp/mirror_mode_test && /tmp/mirror_mode_test        # or: /tmp/mirror_mode_test 3440 1440
```

| Harness | What it measures | Expected |
|---|---|---|
| `mirror_mode_test.mm` | Creates a virtual display (default 3440×1440), turns the main physical display off (it ends up mirroring the virtual), resizes the virtual twice with the mirror active, turns the physical back on and destroys the virtual. Prints the physical display's mode at every step. | The physical display keeps its pixel mode in every step (`PASS`). Without the fix, on the Mac Studio the J560T09 dropped to 800×500 and the panel froze. |

## End-to-end test from Windows (2026-09-02)

**Real Windows 11 ARM64** client (QEMU/HVF, `RD-WIN11`, account `user`) connected
through the host bridge to a **clean macOS Tart** server (`remotedisplay-server`,
freshly cloned `macos-tahoe-base` image, server commit b0f0e1c+). Everything clicked
in the real UI via QMP (`click100.py`, in the VM rig, outside the repo).

| What | Result |
|---|---|
| Connection and MONITORS menu (physical/virtual, switch, trash) | OK — `capturas/win11-conectado-server-tart.png`, `win11-monitors-virtual-basurero.png` |
| Open a monitor in another window / close that window (" · open" + ✕) | OK — `win11-monitors-abrir-ventana.png`, `win11-monitors-ventana-abierta.png` |
| Delete the virtual currently being viewed → falls back to the physical display and the title updates | OK |
| Fit to screen on the physical display → dynamic main (primary virtual sized to the window, physical mirrored "off"); the switch undoes it | OK — `win11-fit-fisico-main-dinamico.png` |
| Per-client profile: server restart (0 virtuals) → on connecting, the client recreates the saved virtual (1284×701) | OK — `win11-perfil-aplicado-al-conectar.png` |
| Server restart with the session open → automatic reconnect → profile re-applied | OK — `win11-perfil-reaplicado-reconexion.png` |
| Per-virtual scale (tap on the dimension → 100/125/150/200% popup) | OK — `win11-escala-popup.png` |
| Fit @200% → 642×351 pts · 150% → 856×468 · 100% → 1284×702 (exact, `dispinfo` on the server) | OK — `win11-escala-100.png` |
| 200% with 2×points ≥ 1920 → real Retina (1284×702 pts / 2568×1404 px) | OK — `win11-escala-200-retina.png` |
| 200% on the dynamic main in a 1284 px window → 1x fallback 642×351 (UI doubled, no Retina); 100% → 1284×702 | OK — `win11-escala-200-zoom-main-dinamico.png`, `win11-escala-final-menu.png` |
| Full profile after server restart: dynamic main 1284×702 + virtual 1284×702 + physical off, mirror repaired after the resize | OK — `win11-perfil-completo-main-dinamico.png` |
| Profile saved with scale (v2): `{"virtuals":[{1284,702,100}],"dynamicMain":true,"dynamicMainSpec":{1284,702,100}}` | OK |
| "Create virtual monitor" is born at the window's size | OK — 1284×701 with the default window |
| **100 create → delete cycles** (939 s) | OK — `stress-100-ciclos.log` |
| `.icc` profiles in `/Library/ColorSync/Profiles/Displays` | **2 constant** (Apple Virtual + 1 Remote Display reused via the stable serial). 0 accumulation |
| `colorsyncd`/`displayservices` CPU | **0%** across all 12 measurements |
| Server process RSS | 385 MB → 512 MB at cycle 1 (encoder buffers) → 552 MB at the end: slight drift with ups and downs (538→521), not conclusive as a leak |
| Final state | only Monitor 1 — no leftover virtuals (`win11-stress-final-menu.png`) |

Comparison: with the random serial (before b0f0e1c) 100 cycles left ~56
`.icc` files behind and `colorsyncd` at a sustained 100%.

## Monitor semantics (agreed 2026-09-02)

- **Fit to screen** is the only trigger for dynamic resolution. On a
  **virtual**: it takes the window's size. On a **physical** display (macOS peer):
  it activates the *dynamic main* — the physical display ends up mirrored onto a primary virtual
  that does follow the window. It's undone by switching the physical display off or with the
  dynamic virtual's trash icon (the engine never destroys that virtual: on macOS
  26 it would leave a ghost display; it hides and recycles it instead).
- **Persistence = a PER-CLIENT profile, per peer**, saved on the client
  (`client/lib/session/monitor_profile.dart`, peer option
  `mac_monitor_profile`): virtuals with size, dynamic main and its size. It's
  captured from the server's real state ~2.5 s after every toolbar action.
  On connect and on every reconnect (`FfiModel.peerInfoEpoch`), the main
  window reconciles the server: deletes extras, creates missing ones, adjusts
  sizes. Another client (PC vs iPad) applies its own → override.
- **The headless server runs an NSApplication (Prohibited) on the main thread**, not
  a bare `CFRunLoopRun()`: CoreGraphics delivers display-reconfiguration notifications
  through AppKit's event loop; without pumping them, after the dynamic main's mirror
  transaction the process stopped seeing displays
  created afterward (`harness/mirror_enum_test2.mm`).
- **macOS 26 dissolves the dynamic main's mirror whenever the mode of any
  other display changes** (`harness/mirror_stability_test.mm`): after resizing another
  virtual the engine re-mirrors on its own; if the mirror breaks from outside and can't
  be repaired, it turns off the dynamic main (physical goes back to being primary, virtual hidden).
- The macOS server **does not destroy** virtuals when the last connection closes (only
  Windows/IDD does `reset_all`); reconnecting from the same client doesn't touch anything.
- **Per-virtual-monitor scale** (tap on its dimension → 100/125/150/200%). The
  framebuffer follows the viewer window's PHYSICAL pixels (canvas ×
  devicePixelRatio) and points = pixels/scale. **Real Retina (2x backing)
  only when 2×points > 1920 px** (a measured limitation of CGVirtualDisplay on
  macOS 26, see `harness/hidpi_test2..5.mm`): below that the display stays at 1x
  with fewer points (bigger UI, somewhat smoother), which is the reliable option. If the
  Retina mode doesn't settle (e.g. the dynamic main's virtual, which is primary and
  mirror master), the engine falls back to 1x with the same points: the chosen
  scale is always honored.
  Default for new virtuals and the dynamic main: the client's scale (DPR snap). Protocol: `ToggleVirtualDisplay` with index ≥ 1,000,000 + id = HiDPI
  on/off; platform addition `mac_hidpi_displays`. The per-client profile saves the
  scale (v2).
- Names `Monitor 1..N` by position; ⧉ opens a monitor in another window and ✕ closes
  it; tapping the row always changes this window's view (or brings to the
  front the window that's already showing it).

## VM rig (Windows QEMU + Mac Tart)

The full test rig (how to bring up the Windows client in QEMU, the
macOS server in Tart, the network bridge, and the **golden snapshots** to avoid
reinstalling) lives outside the repo (local VM rig, not published).

Includes the gotchas that cost hours (ramfb vs virtio-gpu for installing
Windows ARM, booting the installer via the UEFI shell, Tart's network isolation).

## Note 2026-09-03 — HiDPI flag (requested vs actual)

- The server distinguishes `hidpiRequested` (what the client asked for; it's what
  `mac_hidpi_displays` publishes and what the scale label uses) from `hidpi`
  (the actual backing, measured at the end of the resize with
  `CGDisplayModeGetPixelWidth == 2 × points`, 5 s wait). The HiDPI toggle
  only declares the mode; the resize that follows applies and verifies it.
- A toggle with the same points doesn't change the bounds (960×505 at 1× and 2×):
  the wait is keyed on pixels and points, not on bounds.
- On this VM real Retina doesn't kick in at 960 pt (= 1920 px, right at the
  threshold): the display stays at 1× with the same points (UI doubled). It did
  kick in at 1284 pt / 2568 px (evidence table above). The engine log
  (`rustdesk.log`, line `resize … (hidpi=N)`) shows the actual backing.

## 2026-09-03 — displays restored when the last client leaves

Two fresh Tart VMs from `macos-tahoe-base` (macOS 26.6.2, SIP off):
`remotedisplay-test-server` (Remote Display Server.app + engine) and
`remotedisplay-test-client` (macOS client), client → server through an SSH
reverse tunnel via the host. Driven with Tart's `--vnc-experimental` VNC server
and `vncdotool` (on 26.6.2, `osascript`/`screencapture` launched over ssh no
longer reach the GUI session, even with TCC rows in place). Display state read
with a small `CGGetOnlineDisplayList` tool inside the server VM.

Result: every scenario restored the Mac within ~3 s of the client process being
killed (`kill`, i.e. a dropped connection, not a clean close):

| Scenario before the kill | After the kill |
|---|---|
| Dynamic main ON (virtual 1600x900 main, physical mirroring it) + virtual 1280x720 | physical active + main + 1920x1080, virtual destroyed, dynamic-main virtual hidden |
| Same, second connection (recycled dynamic-main virtual) | same |
| Flat profile (virtual 1280x720) + physical turned off from the toolbar switch | physical active + main + 1920x1080, virtual destroyed |

Engine log lines to look for: `mac_vdisplay: last client left, restoring the
displays` → `dynamic main OFF (physical N main, virtual M hidden)` /
`physical N turned on` / `destroyed ID M` → `mac_vdisplay: displays reset`.
The client re-applies its saved monitor profile on the next connection, so
nothing is lost.

Fixed along the way (found by the second cycle): the mode remembered for the
mirrored physical was taken while macOS had already re-mirrored it onto the
recycled virtual, so the "restore" put the physical at the virtual's 1600x900.
`rdRememberPhysicalMode` now records only a standalone display's mode (and is
called before the virtual is touched), the memory is kept across cycles, and
`rdRestorePhysicalMode` watches for two seconds and re-applies the mode if macOS
flips it again after the unmirror.

Also fixed: the macOS client (1.0.0) died on launch with exit code 141 (SIGPIPE
from a write to a closed socket during LAN discovery; a Rust cdylib inside a
Flutter app does not ignore SIGPIPE the way a Rust binary does). The Runner now
ignores SIGPIPE before the first Rust call. Note for testing: on desktop a
`remotedisplay://` link or `--connect` only takes effect as launch arguments
(`open RemoteDisplay.app --args --connect <ip> --password <pw>`); sending it to
an already running client does nothing.

Server-app permission flow verified in the same VM: the first *Grant…* tap shows
only the macOS dialog (System Settings not launched), a second tap while the
permission is still missing opens the Settings panel; same for Accessibility.

### Follow-ups verified the same day

- **Service turned off while a client is connected** (`launchctl bootout` of the
  agent, which is what the app's toggle runs; SIGTERM to the engine): the engine
  now restores the displays before exiting (`signal 15: restoring the displays
  before exiting` → `dynamic main OFF` → `displays restored, exiting`, 2.2 s),
  the physical came back active, main and at 1920x1080. Implemented as a GCD
  signal source in `MacRunHeadlessAppLoop` calling `remotedisplay_reset_displays`
  (Rust, `virtual_display_manager.rs`); SIGINT is handled the same way.
- **Links while the desktop client is already running**: both
  `open "remotedisplay://connection/new/<ip>?password=<pw>"` and
  `RemoteDisplay --connect <ip> --password <pw>` from a second process opened a
  session in the running app (the second one travels over the engine's `_url`
  IPC as the `on_url_scheme_received` global event). The client's main now
  subscribes to global events and to the uni_links stream, as upstream's server
  page does.

### Quitting the menu bar app (2026-09-03, later)

Sam hit "the item is in use" when replacing the app in /Applications after *Quit*:
the engine kept running inside the bundle. Verified in the same VMs with a client
connected and the dynamic main active: a quit Apple event addressed to the app's
PID (`osascript -l JavaScript -e 'Application(<pid>).quit()'`, the same path as
the menu bar item) now boots the agent out, the engine logs `signal 15: restoring
the displays before exiting` → `dynamic main OFF` → `displays restored, exiting`,
the app exits 2 s later (trace in `~/Library/Logs/RemoteDisplayServer/app.log`)
and the bundle can be renamed. Gotchas: a quit Apple event by *name*
(`tell application "Remote Display Server" to quit`) reaches the ENGINE, which
shares the bundle id — it now handles it by restoring the displays first
(`RDHeadlessAppDelegate`); and the app's engine lookup is anchored on
`/Contents/MacOS/remotedisplayd --server$`, since a plain `pgrep -f
"remotedisplayd --server"` also matched shells mentioning the name.

### iPad: external monitor for macOS hosts (2026-09-04, real devices)

Sam's iPad Pro (iPadOS 26.6.1) with an external monitor, connected to his Mac
Studio (one physical + one virtual display): the MONITORS menu had no way to put
the other monitor on the iPad's external display. The external-display action
(`ExternalScreenController.attachDisplay`/`detach`) was only wired in the
generic DISPLAYS section used for Windows/Linux hosts; the macOS section only
knew the desktop "open in new window" slot. Fixed in `session_toolbar.dart`: on
mobile with a monitor connected, each non-current row shows the external-display
icon (or ✕ while it is out there, with " · external" in the detail).

Verified on the real iPad with WebDriverAgent (`~/dev/WebDriverAgent`, screenshots of
both screens via `/screenshot` and the added `/wda/screenshot/<displayId>`): tap →
the external monitor switched to its native 2560x1600 and showed the Mac's
Display 2 with the "192.168.1.115 | Display 2" pill, the iPad kept Monitor 1;
✕ → the monitor went back to the iPadOS desktop.

Follow-ups on the same iPad: (1) the external view used `Center(FittedBox(contain))`,
and under loose constraints FittedBox only shrinks, so a remote display smaller
than the monitor (2048x1280 on 2560x1600) sat 1:1 with black borders — now it
fills the monitor (`SizedBox.expand`); (2) the action uses the same icon as the
desktop "open in new window"; (3) "Fit to screen" and sending a *virtual* display
to the external monitor size that virtual to the monitor's pixels (a temporary
2816x1940 · 200% virtual became 2560x1600 · 200%, shown 1:1); (4) the external
pill kept its old "Display N" label because the page body lives in
BlockableOverlay's initial OverlayEntry (setState does not rebuild it) — the label
is a ValueNotifier now.
(5) Deleting the virtual that the external monitor was showing left the external
view open on the engine's "display is plugged out" prompt, with no menu row left
to close it: the trash now detaches the external view first, and the controller
detaches on its own whenever the display it shows disappears (verified: the
monitor went back to the iPadOS desktop).

## 2026-09-04 — two-VM run for the 1.0.3 batch (Windows client + macOS server)

Rig: macOS server VM (`macos-tahoe-base`, Tart, 4 GB) and the Windows 11 QEMU VM restored to
its `base-limpio` snapshot (4 GB), joined by the ssh bridge on port 21119. Both VMs at 8 GB
starved the host (16 GB compressed, 4 GB of swap): the Windows guest looked hung — black
480x270 screendump, ssh banner timeouts, QEMU RSS 80 MB — until both were cut to 4 GB.

Verified:
- **Hardware codecs** (`hwcodec` on the macOS engine, the macOS client and the Windows DLL):
  the server negotiates H265 and creates `hevc_videotoolbox` encoders even inside the VM; the
  Windows client logs `create H265 decoder success`. Before, everything was VP9 in software.
- **Odd sizes broke hardware encoding**: a virtual created at a 1284x701 window made
  `hevc_videotoolbox` fail ("new hw encoder failed … clear config") and the connection fell
  back to VP9 for good; the client then persisted `codec-preference = 'vp9'` for the peer.
  Fixed by rounding every virtual size down to even (engine and client): the same action now
  yields 1284x700 and stays on HEVC. Clients that already saved VP9 must pick *Auto* again in
  the codec menu once.
- **Capture loop counters**: `video loop for display N started: X alive, Y started since
  launch`; five full disconnect/reconnect cycles with the dynamic main and a virtual left the
  engine at 94–106 MB RSS, 33–35 threads, and always 1 loop alive — no leak there. The
  topology settle path fired once (`display topology settled after N ms`).
- **Per-monitor window closes when its display is deleted**: the virtual opened in a second
  window and deleted from that window's menu; the window closed by itself (id-based, since
  deleting a lower display shifts the indices — the index-based first attempt left the window
  showing the next display).
- **Password over stdin**: `printf 'x\n' | remotedisplayd --set-lan-password` → `Done!`.
- The server's disconnect reset also fires when the Windows client is killed.
- The macOS notice for the server now reads "Software from “Samuel Rioja”" (personal team).

QEMU gotcha: `qmp.py … shot <path>` only works with a path inside the QEMU folder; copy the
PNG afterwards.

## 2026-09-04 — 1.0.4: Developer ID signing and notarization (server VM + Windows client)

The macOS client and server are now signed with the personal team's *Developer ID
Application* certificate (hardened runtime, secure timestamp), notarized and stapled, DMGs
included. Verified:

- Build Mac (Gatekeeper on): `spctl -a -t exec` on both apps and `spctl -a -t open
  --context context:primary-signature` on both DMGs → `accepted, source=Notarized Developer
  ID`; `stapler validate` passes for apps and DMGs; all four notarytool submissions `Accepted`.
- Server VM (`macos-tahoe-base`): the DMG copied in with a Safari-style quarantine attribute is
  accepted as *Notarized Developer ID*, and so is the app inside it. Launching the copied
  bundle showed macOS' first-open sheet for downloads — "Apple checked it for malicious software
  and none was detected" — instead of the old "unidentified developer" block. Note for tests: a
  bundle copied with `cp -R` from a quarantined DMG keeps the flag and runs *translocated*
  (`/private/var/folders/…/AppTranslocation/…`), so the LaunchAgent engine does not start; a
  Finder drag-install is not translocated. `xattr -dr com.apple.quarantine` reproduces that.
- The relaunched 1.0.4 server ran from `/Applications` with the engine under the LaunchAgent,
  port 21118 open, permissions reported granted. The Windows 11 client VM (QEMU, `--connect
  10.0.2.2:21119` through the host bridge) connected: HEVC via `hevc_videotoolbox`, one video
  loop alive, engine at 99 MB; killing the client logged `last client left, restoring the
  displays` and the loop ended with 0 alive.
- Requirement check on the build Mac: the Developer ID build satisfies the new explicit
  requirement (`identifier "app.remotedisplay.server" and anchor apple generic and certificate
  leaf[subject.OU] = K45698KZ4W`), a copy re-signed with the *Apple Development* identity
  satisfies it too (TCC grants shared between development and release builds), and the
  Developer ID build does NOT satisfy the 1.0.3 requirement (which pinned the certificate's CN),
  hence the one-time permission prompt when upgrading from 1.0.3.

## 2026-09-05 — known computers, per-address reachability, connect sheet (Windows client + macOS server)

Motivation: from another network the iPad still showed the Mac's LAN entry (cached discovery,
never re-validated) and could not find its Tailscale address (iOS has no Tailscale CLI, so
the engine never probed it). The home now lists every known computer with all its addresses,
probes each one on every refresh, remembers the network used per computer and asks again when
that network is gone.

Rig: same two VMs; the build Mac runs the real server on 21118, so the VM server is reached
through host bridges on 21119 ("LAN" route, `10.0.2.2:21119` from the Windows guest) and 21120
("Tailscale" route through the host's CGNAT address `100.64.0.2:21120`). Helpers in
`harness/vm.sh` (`bridges`, `wshot`, `wclick`) and `harness/run-win11-4g.sh`.

Verified in the Windows VM (screenshots `to_remove/routes-*.png` during the run):
- Discovery entries that do not answer a TCP probe are greyed with "Not reachable from this
  network"; reachable ones get a green dot. The engine's own `online` flag is not used (it only
  marks duplicates).
- Manual connection to `10.0.2.2:21119` with "remember" produced a card grouped by hostname
  (`manageds-virtual-machine`, admin · Mac OS) with the key icon; the per-peer flag
  `rd-remember = 'Y'` was written and the engine saved the password.
- Settings (gear): the address list with status, "Add address" → `100.64.0.2:21120` appeared as
  "Tailscale · Reachable · added by you"; both routes then showed on the card.
- Connecting through the Tailscale route without its own password borrowed the LAN one
  (`rd-copy-password-from`): a second peer file appeared and the server opened the session.
- A computer with two networks and none chosen opens the connect sheet (radio options with
  status, "Password saved for this address", "Connect via LAN/Tailscale"); choosing Tailscale
  connected (window title `100.64.0.2:21120`) and the card marked that chip as selected.
- Dropping the 21120 bridge + refresh: the selected Tailscale chip turned grey with "Tailscale
  does not answer here · tap to choose another network"; tapping the card opened the sheet with
  the banner "Tailscale · 100.64.0.2:21120, used last time, does not answer from this network.
  Choose another one." and LAN preselected; connecting via LAN made LAN the selected network
  (`rd-preferred-routes = {"manageds-virtual-machine":"10.0.2.2:21119"}`).
- Bug found on the way: the reachability probe ignored a `host:port` id (connected to
  `10.0.2.2:21119` on port 21118) and showed the route as unreachable; fixed by splitting the
  port off the id.

Real iPad (2026-09-06, WebDriverAgent over Wi-Fi, screenshots `to_remove/ipad-routes-*.png`),
against the VM server through the same host bridges (`192.168.1.115:21119` as "LAN",
`100.64.0.2:21120` as "Tailscale" — the iPad reaches the host's CGNAT address through its
Tailscale app, so this exercises the real iOS path):
- Home listed the two real Macs of the LAN with green dots; no Tailscale route existed for the
  Mac Studio because the iPad had never connected through it — that is exactly the "only local
  things" picture Sam saw away from home.
- Manual connection with "remember" → card `manageds-virtual-machine` with the key icon;
  settings → add `100.64.0.2:21120` → "Tailscale · Reachable · added by you".
- Card tap with two networks and none chosen → chooser sheet (radio, "Password saved for this
  address", "Connect via LAN"); picking Tailscale connected (pill `100.64.0.2:21120`) and the
  card marked that chip.
- Bridge 21120 dropped + refresh: chip struck through, hint "Tailscale does not answer here ·
  tap to choose another network"; the card tap opened the sheet with the banner "…used last
  time, does not answer from this network. Choose another one." and LAN preselected; connecting
  via LAN made LAN the selected network. "Forget this computer" removed the test machine.
- WDA gotchas: the on-screen keyboard shifts the layout (tap fields after hiding it or type with
  a trailing "\n"); the session pill toggles with its "<"/">" button and the × only works once
  the pill is expanded and idle; touches inside the session go to the remote trackpad.

## 2026-09-06 — 1.0.6: Tailscale address learned from discovery, UX round (VMs + real iPad)

Rig change: the Tart server VM now runs **bridged** (`tart run --net-bridged=en1`), so it sits on
the real LAN (192.168.1.208) and the iPad discovers it directly — no host bridges needed for
the LAN route. `tart ip` needs `--resolver=arp` for a bridged VM (`harness/vm.sh` does it).
A CGNAT alias (`ifconfig en0 alias 100.64.99.1 255.192.0.0`, lost on reboot) stands in for the
Mac's Tailscale address. On the first LAN traffic macOS 26 in the VM showed the *Local Network*
privacy prompt for the server (our `NSLocalNetworkUsageDescription`); answer Allow.

- **Server advertises its Tailscale address**: `harness/discover-probe.py <ip>` (UDP 21119, the
  discovery port is `RENDEZVOUS_PORT + 3`) shows `misc = {"addrs":["100.64.99.1"]}` in the pong;
  unit tests `lan::advertised_addrs_tests` cover the payload parsing.
- **Real iPad learns it**: a fresh launch listed the VM found on the LAN with two routes, LAN
  192.168.1.208 (green) and Tailscale 100.64.99.1 (grey, struck through: not routable here), with
  no manual step (`to_remove/ux-ipad-1-home-learned.png`).
- Chips now select: tapping the Tailscale chip marked it (check) without connecting; the card tap
  then opened the sheet with the "used last time, does not answer" banner, password field with
  the eye, Remember toggle, "Connect via LAN" — centered and capped at 560 pt on the iPad.
- Rename from settings ("VM de prueba" on the iPad, "VM Windows test" on Windows) shows on the
  card; names have their own line, user · platform below.
- Collapsed session pill shows [>][×]; the × disconnected from the collapsed state.
- Windows VM: same checks (two-line names, chip select, rename) with the 1.0.6 client.


## 2026-09-06 — 1.0.8: monitors configured on the Mac only (SimpleDisplay model), display manager

Rig: Tart server VM on NAT (192.168.64.6) with host bridges 21119/21120, Windows 11 QEMU client
(`C:\RemoteDisplayTest`, a 1.0.5 build, deliberately OLD to exercise the refusal path).

What changed: every display mutation (server virtual monitor, "main screen follows remote", a
client's Fit/scale on a virtual, the reset on SIGTERM) goes through one worker thread
(`engine/rustdesk/src/server/display_manager.rs`). While it works, the display service holds
its broadcast and the video loop leaves its capturer alone; when macOS has settled it announces
ONCE. The menu-bar app reads `~/Library/Application Support/remotedisplay-displays.json`
(written by the manager) instead of spawning `--plug-virtual status` every 4 s, and its toggles
show a working state until the engine answers. Clients no longer create/delete virtuals, turn
physicals off, or make the physical dynamic; cached per-index sizes are never applied on macOS
hosts; nothing is restored when the last client leaves (there is nothing of theirs to restore).

- **Server toggles (no client)**: `--plug-virtual on` 1.7 s, `on` again = no-op in 0 ms,
  `--dynamic-main on` 4.1 s, `off` 7.6 s, `--plug-virtual off` 1.5 s (the removal is
  asynchronous in WindowServer: the manager waits up to 3 s for the topology to reflect a
  change it made). State file correct after each step; `status` for both = the file.
- **Server toggles with the Windows client connected, per action**: exactly 1 "Displays
  changed", 1 refresh, 1 SWITCH, 0 extra topology restarts, 1 video loop started — for plug
  on, dynamic main on, dynamic main off and plug off alike. Before the manager the same
  actions cost 3–5 restarts each (the 1.0.7 log of Sam's Mac shows 4 in 4 s for one toggle).
- **Client disconnect/reconnect**: the virtual stayed (state file `virtual_ids:[7]` before and
  after); the log shows only "Connection closed"; no restore, no dynamic-main change, no
  resolution attempt on reconnect.
- **Old client taps Fit on the physical display**: server log `ToggleVirtualDisplay -2 on=true
  refused: monitors are managed on the Mac`; the client gets the "Monitors are set up on the
  Mac itself" message box; the Mac's screen is untouched.
- **Service stop** (bootout during the redeploy): `ResetAll` through the manager, "displays
  reset", state file back to all-off at the next start.
- Swift app: the main window's new *Monitors* section (both toggles + footer) seen in the VM
  through the remote session; the menu-bar toggles read the same state.
- **Black virtual after a dynamic-main cycle (found by these tests, fixed before publishing)**:
  `--dynamic-main on` → `off` → `--plug-virtual on` → the new virtual showed BLACK at the client
  (old and new client alike, fresh connections too) while `screencapture -D 2` inside the VM had
  the content and `#displays=2 … name:16` proved the capturer was on the right display: the
  CGDisplayStream of a CGVirtualDisplay created while a *disabled* display exists (the cached,
  hidden dynamic-main virtual) never delivers a frame. Re-enabling the hidden one (dynamic main
  on again) streamed fine, and the black one started streaming after that transaction. A clean
  sequence (no dynamic-main cycle first) always streamed, on 1.0.7 and 1.0.8. Fix: virtual
  displays are never destroyed while the service runs — a removed one is *parked* (disabled,
  kept in the registry) and the next create re-enables it, so a brand-new display is only made
  when nothing is disabled (at most two per process). This also removes the ghost-display risk of
  destroying an ex mirror master.
- **Menu-bar app crash (1.0.7, seen on Sam's Mac 2026-09-06 20:24 local, fixed in 1.0.8)**:
  `RemoteDisplayServer-…ips` shows SIGABRT from an uncaught AppKit exception thrown by
  `-[NSWindow _postWindowNeedsLayout]` during the display cycle while `NSMenuTrackingSession`
  was running — the SwiftUI `MenuBarExtra` menu was open and the 2 s refresh changed the
  observable state it shows. The engine kept running (LaunchAgent); only the icon vanished.
  Fix: the controller does not touch observable state while a menu is tracking
  (`NSMenu.didBeginTracking`/`didEndTracking`; updates are deferred until 0.3 s after it
  closes, with a 120 s safety net) and the menu labels are fixed.
  Verified over VNC (`tart run --vnc-experimental`, vncdotool; status icon at 1672,15 on 1920x1080):
  menu held open across several refresh ticks and a `--plug-virtual on` from ssh → app alive,
  `app.log` shows "menu opened: updates on hold" / "menu closed: 1 deferred update(s) resume", the
  toggle showed the new state only after the menu was reopened.
- **Launch behaviour (1.0.8)**: opening the app yourself always shows the window; the automatic
  launch at login stays in the menu bar unless the setup needs attention. On macOS 26 the launch
  Apple event does NOT tell the two apart (both `aevt/oapp`, no `keyAELaunchedAsLogInItem`;
  measured with the `launch:` trace in app.log), so the app uses Open at Login enabled + start
  within 90 s of the console login (utmpx). VM: `open` → `loginItem=false sinceLogin=124s` and
  the window; reboot with Open at Login → `loginItem=true sinceLogin=4s`, menu bar only. Also
  fixed: `start()` now records the auto-start so `ensureDesiredState()` no longer bootstraps
  the engine a second time 2 s later (two "service on requested" at login).

## 2026-09-07 — 1.0.9: virtual displays removed (SimpleDisplay owns them), Retina gate fix

Sam's call after a day of 1.0.7/1.0.8 surprises: Remote Display no longer creates, resizes,
mirrors or removes displays on the Mac. SimpleDisplay does that; the client only picks a
display, opens it in a new window and shows all of them (desktop). Removed: the whole
`CGVirtualDisplay` backend in macos.mm, `mac_vdisplay`, the display manager, the IPC/CLI
toggles, the menu-bar toggles and Monitors section, the client's MONITORS section, Fit resize,
scale menu and the iPad external-monitor resize. Kept: the topology hash (anti-storm gate and
capturer restart for mirrored displays), the headless NSApplication loop, the menu-open
deferral and the launch-behaviour fix.

- **Restart storm on Sam's Mac (1.0.8, 2026-09-06 21:12)**: iPad on display 0 plus a Windows
  client connecting → two video services → RustDesk sets `ENABLE_RETINA=false`
  (`server.rs`) → every display size halves (4096x2560 → 2048x1280) while the topology hash
  does not change → my gate kept SYNC_DISPLAYS stale → capturer/list mismatch → SWITCH every
  1.4 s for 20+ minutes (the Windows client logged `width/height mismatch (4096,2560) !=
  (2048,1280)`; the iPad looked "crazy"). Fix: the Retina flag is part of the gate key. Broke
  the storm on the spot with `launchctl kickstart -k`.
- **Black picture at connect, intermittent (VM, 1.0.9 server, 1.0.8 and 1.0.9 clients)**: about
  1 in 4 fresh sessions stayed black at 15 s although the server logged the usual
  `encode fail: no valid frame, times: 1` and nothing else; as soon as anything changed on the
  VM's screen (the remote cursor over the Dock, Spotlight open/close) the picture appeared.
  Client-side-only interactions (title bar, taskbar) do not help, so it is the server not
  sending a frame: the first capture is invalid or the hardware encoder swallows it, and a
  CGDisplayStream only delivers frames when the screen changes. Safety net in
  `video_service::run` (macOS): if no encoded frame reached a client 2 s after the capturer
  started, restart the loop (fresh stream = fresh initial frame), at most 3 times in a row.
- **Fit to screen, virtual displays only (any app's)**: classifier `MacDisplayIsVirtual` in
  macos.mm. Measured: Sam's two physical displays each have an `IOMobileFramebufferShim` with
  `DisplayAttributes.ProductAttributes` (`LegacyManufacturerID`=2533/25001, `ProductID`=
  10101/8193 = CGDisplayVendorNumber/ModelNumber 0x9e5/0x2775 and 0x61a9/0x2001; the "EDID
  UUID" starts with the same numbers). In the VM a SimpleDisplay virtual (vendor 0x1234,
  product 0x5678) adds NO IOMobileFramebuffer service (count stayed 1); the paravirtual display
  has vendor/model 0 (treated as physical). Dead ends: `CGDisplayIOServicePort` is 0 for
  everything on Apple silicon, and `kDisplayModeNativeFlag` is set on the CGVirtualDisplay's
  declared mode too (`native_modes=1`, 10 modes generated from one declared 1600x1000).
  SimpleDisplay's modes are macOS's scaled variants of the one it declares, so Fit picks the
  largest mode that fits the window (nearest-mode fallback), not an exact size.
- **Fit end to end (VM + Windows client 1.0.9)**: SimpleDisplay virtual 1600x1000 next to the
  paravirtual display. The server announced display "1" with its real size and display "2"
  with a virtual resolution (0x0). Fit on display 2 from a 1284x700 window → server log
  `exact mode 1284x700 not available on '2' … nearest mode for 2: 1284x700 requested,
  1024x640 chosen`, the display went to 1024x640 (probe). Fit on display 1 (physical) sent
  nothing to the server. Menu shows DISPLAYS (two rows, open-in-new-window icon) and All displays.
- **Fit on Sam's Mac with a SimpleDisplay 3440x1440 HiDPI display (1.0.9 first cut)**: the
  server did classify it as virtual and changed its mode, but chose by POINTS against the
  client's PIXELS: a 1002x934 window got 800x600 pt = 1600x1200 px, a 3440x1368 window got
  1600x1200 too (4:3 on an ultrawide). Mode list macOS generates for that display (VM,
  `probe_modes`): declared 3440x1440 at 1x and 2x plus scaled copies of the same aspect
  (1280x536, 1344x562, 1600x670, 1920x804, 1720x720@2x) and the generic 4:3 sizes
  (800x600…1600x1200), 18 in all. `MacSetNearestMode` now scores by aspect ratio first, then
  pixel area: a 1284x700 window → 1600x670 px (verified end to end from the Windows client).
  Exact window sizes stay impossible for a display another app owns: only its creator can
  declare new modes.
- **Refresh storm on Sam's Mac (1.0.9, 2026-09-06 23:47–00:04)**: with the Windows client
  connected, "switch to refresh" every ~0.6–1.5 s for 17 minutes (35–39 video restarts per
  minute), each cycle `encode fail: no valid frame, times: 1` → refresh 0.2 s later. The client
  log showed only its 12 s "Refresh display 0 to reduce delay"; no display list changes were
  broadcast. Restarting the engine ended it and it did not come back; viewing a SimpleDisplay
  display and removing it in the VM did not reproduce it (one restart, client falls back to
  display 1). Two safeguards shipped: every refresh source is now logged
  (`#N refresh: RefreshVideoDisplay(d) from the client` / `RefreshVideo` / `display list
  announced`), and `refresh_video_display` drops refreshes for the same display arriving less
  than 1.5 s after the previous one (logged as `refresh of display d dropped`).

## 2026-09-07 — 1.0.11: frozen picture on the Windows client (FFmpeg WPP deadlock), refresh storm

Symptom on Sam's Mac Studio + Windows PC (RTX 5070 laptop, 24 CPUs), client 1.0.10: the
picture froze (quality monitor: 224 kB/s in, FPS 0) while keyboard and mouse kept working.
Server log: `#1432 refresh: RefreshVideoDisplay(0) from the client` about 10 times a second,
the 1.5 s limiter dropping all but one, each accepted one → `switch to refresh` → new
capturer + `hevc_videotoolbox` encoder → `encode fail: no valid frame, times: 1`; 633 video
loop restarts and 7353 refresh requests in one minute before the engine was restarted.
Restarting the engine did not help: the client reconnected and froze again within a minute.

Diagnosis with two minidumps of the client process (`MiniDumpWriteDump` from PowerShell,
symbolized on the Mac with `dump_syms` + `minidump-stackwalk` against `librustdesk.pdb`,
scratch notes in the session's scratchpad):
- Thread 160 sat inside `scrap::common::codec::Decoder::handle_video_frame` →
  `hwcodec::ffmpeg_ram::decode::Decoder::decode` → `avcodec_send_packet` →
  `hevc_receive_frame` → `hls_slice_data_wpp` in both dumps, 15 minutes apart; three more
  threads (older sessions) were parked in `ff_thread_await_progress2` (pthread_slice.c:235)
  under `hls_decode_entry_wpp`. No thread of the process used 30 ms of CPU over 3 s: a
  deadlock, not slowness.
- Why software decoding at all: the client log said `Failed to get hwcodec config: The system
  cannot find the file specified` and `gpu signature changed, 0 -> …`, then
  `try create CodecInfo { name: "hevc", hwdevice: AV_HWDEVICE_TYPE_NONE }`. The check that
  finds the GPU decoders is run by the local server process and handed over IPC; the
  client-only Windows install has no server, the one-shot IPC attempt (50 ms) failed, and no
  `RemoteDisplay_hwcodec.toml` was ever written. `codec_thread_num(16)` gave 8 slice threads
  and the VideoToolbox HEVC stream carries WPP entry points → FFmpeg's WPP path.
- The chain: decoder deadlocks → the 120-frame queue fills → `io_loop.rs` asks for a refresh
  on every evicted frame (unlogged path) → the server recreates capturer and encoder once per
  1.5 s → the client never decodes anything anyway.

Changes (1.0.11):
- Software HEVC decoding uses one thread (`HwRamDecoder::new`): no WPP slice threading.
- `ipc::hwcodec_process` stores the result with `HwCodecConfig::set` (config file) besides
  sending it over IPC; the client-only process starts the check at launch
  (`start_server` no_server branch) and `client::get_hwcodec_config` runs it itself when IPC
  fails, waiting up to 10 s for the file on the first launch (`scrap::hwcodec::config_ready`).
- A full video queue asks for a refresh at most once a second (logged `video queue of
  display N full: asking for a refresh`); the server logs dropped refreshes at debug level.
- Tried and dropped: encoding the first picture again immediately when VideoToolbox returns
  nothing for it — the second call fails too (`times: 2`, the encoder has not finished) and a
  third miss would disable the hardware encoder. The repeat-on-WouldBlock path already sends
  the keyframe within a frame period; the old "no keyframe" theory was wrong, the client was
  simply deadlocked.

Verification (VM rig, Windows 11 ARM64 QEMU client under x64 emulation, no GPU):
- 1.0.9 Windows client against the 1.0.11 server VM: connected and showed the picture with a
  single video loop start (`encode fail … times: 1` once, no restart, no refresh).
- 1.0.11 client (`C:\RemoteDisplayTest5`, task `rdtest5` = `--connect 10.0.2.2:21119`): picture
  from the first seconds, software `hevc` decoder (`hwdevice: AV_HWDEVICE_TYPE_NONE`, one
  thread), fps control moving between 12 and 25 with clicks driven on the remote screen for
  four minutes; server side: 2 video loop starts in total (one per session), 0 switches, no
  refresh from the client; client log: no `video queue … full` and no `Refresh display … to
  reduce delay`.
- `remotedisplay.exe --check-hwcodec-config` by hand: exits 0 after 6 s and writes
  `RemoteDisplay_hwcodec.toml` (323 bytes: signature 0, software h264/hevc decoders; the MFX
  errors in its log are the Intel QSV probe failing on a VM). Plain launch of the home screen
  (no arguments, file deleted first): `server not started … no_server: true`, the file is
  written 3 s after launch, `Check hwcodec config, exit with: exit code: 0`.
- Not reproducible here: the GPU path. This VM's GPU signature is 0, so the cached default
  matches and `config_ready()` is true at once; on Sam's PC (signature 18014402815439437, no
  file) the client will run the check itself and wait for it, then pick the NVDEC decoder.
  Neither is the WPP deadlock itself reproducible on demand; the fix removes the code path.
- A `--connect …` launch (the test rig's way) skips `start_server`, so only the video-thread
  fallback applies there; the normal launch from the home screen runs the check at startup.
- Real hardware, same day (Sam's PC, RTX 5070 laptop): 1.0.11 installed at 05:36, the
  client wrote `RemoteDisplay_hwcodec.toml` (843 bytes, signature 18014402815439437) one
  second after launch, and every session since creates
  `CodecInfo { name: "hevc", hwdevice: AV_HWDEVICE_TYPE_D3D11VA }` (GPU decode). Mac server
  1.0.11 (12): from 05:36 to 08:37, 11 video loop starts — three codec changes made by hand
  (H265 → VP8 → VP9 → H265) and the "display list announced" refresh at each connection —
  zero refreshes from the client, no restart since 06:15 with the session up.

### "True color (4:4:4)" gone from the Screen menu (2026-09-07, after 1.0.11)

The engine lists the `i444` toggle only while the codec in use is VP9 or AV1
(`toolbarDisplayToggle`, `codec_format == "AV1" || "VP9"`): hardware H264/H265 encode 4:2:0
only. Since `5049873` (hwcodec on the Mac) the automatic codec is H265 by VideoToolbox, so the
switch vanished; CODEC → VP9 brought it back. The Screen menu now always shows "True color
(4:4:4) · VP9" under IMAGE when the engine does not offer its own: turning it on sets the codec
preference to VP9, enables `i444` and calls `sessionChangePreferCodec` (the Mac then encodes VP9
in software: sharper text and colours, more CPU on the Mac). CODEC → Auto returns to H265.
Verified in the VM rig (Windows client rebuilt from `dc493d0`, server VM 1.0.11): with CODEC on
Auto (H265) the Screen menu lists "True color (4:4:4) · VP9"; one click → server log `switch due
to codec changed, H265 -> VP9`, `new encoder: VPX(… VP9 …), i444: true`; the reopened menu shows
CODEC = VP9 and the engine's own "True color (4:4:4)" checked; quality monitor: Codec VP9,
Chroma 4:4:4. Screenshots in to_remove/capturas-1.0.11/.

## 2026-09-08 — 1.0.12: frozen picture when SimpleDisplay changes the display, native window chrome

Symptom on Sam's rig (Mac Studio server 1.0.11, Windows PC client 1.0.11, RTX 5070): opening
SimpleDisplay so that its virtual display takes over froze the picture until the codec was
switched to anything else and back to H265. It looked like "the codec breaks".

Diagnosis from both logs (server: `~/Library/Logs/RemoteDisplay/server/`, client:
`%APPDATA%\RemoteDisplay\log\`):
- 06:06:23 the display list changed: display 0 went from the physical 2048×1280 (id 3) to the
  SimpleDisplay 3440×1440 (id 30), `#displays=1`. The video loop restarted through the
  "display topology changed" branch and created a 3440×1440 `hevc_videotoolbox` encoder — the
  server side was fine. But that branch never announced the new geometry: no `Display … changed`
  (SwitchDisplay) in the log. connection.rs had asked for a refresh on the list announcement,
  which would have carried it, but the new loop clears the pending refresh flag when it starts.
- The client logged `width/height mismatch: (3440,1440) != (2048,1280)` on every frame for 20 s.
  The first pair is the size Flutter already expected (it had processed the display list), the
  second is the decoded picture: the D3D11VA HEVC decoder kept producing 2048×1280 pictures.
  hwcodec's `ffmpeg_ram_decode.cpp` allocates its software frame once (first picture) and never
  unrefs it; `av_hwframe_transfer_data` then copies into that buffer and the frame keeps the old
  dimensions. The renderer (`VideoRenderer::on_rgba`) refuses frames whose size does not match
  the session size, so nothing was drawn. Software decoders (VP8/VP9, software HEVC) output the
  real size, which is why switching codecs "fixed" it: the decoder was recreated.
- Same thing happened on 09-07 at 06:15, 09:09 and 15:03; a second display change seconds later
  sent a SwitchDisplay and hid it.

Changes:
- `video_service.rs`: the topology branch calls `try_broadcast_display_changed(&sp, display_idx,
  &c, true)` before restarting, like the refresh path: old capturer vs fresh list → SwitchDisplay
  → the client recreates its decoder. This restores upstream's invariant (every geometry change
  is announced before the new stream) for every client, including iPad and iPhone.
- Client defence (`flutter.rs`, `ui_session_interface.rs`, `client.rs`): the renderer counts
  consecutive frames refused for their size per display (`rgba_size_mismatches`); after 5 in a
  row over ≥1 s the video thread asks the server for a refresh and recreates the decoder when
  the next **keyframe** arrives (never before: a P-frame on a fresh decoder counts as a failed
  first frame and marks the codec unsupported). 5 s cooldown; cleared by any other reset.
- Home window (Sam: "keep the OS controls only, not maximizable"): the custom minimize/close
  buttons are gone; macOS keeps its traffic lights over the hidden title bar (zoom disabled,
  no full screen: `MainFlutterWindow.swift`), Windows uses its regular title bar
  (`TitleBarStyle.normal`), both `setMaximizable(false)`. The native close now quits the app
  (`onWindowClose` in home.dart: save position, close session windows, terminate on macOS);
  before, with `preventClose` on and no listener, the red button did nothing.

Verification (two fresh VMs: Tart clone of `macos-tahoe-base` 26.6.2 with the server app built
from this tree + SimpleDisplay 1.6.6 and `simpledisplayctl`; Windows 11 QEMU restored to
`base-limpio` with the client built on the PC from the same sources, engine DLL included):
- Steps driven over ssh: `simpledisplayctl create --width 3440 --height 1440`, `mirror --id 1`
  (the VM's 1024×768 display mirrors the virtual one → display 0 becomes the 3440×1440 virtual,
  `#displays=1`, Sam's exact case), `unmirror`, `remove`; 3 cycles plus the first pair.
- Restarts by path: 9 through the refresh path (`Display … changed` then `SWITCH`) and 5 through
  the topology path (`display topology settled …` then `Display … changed` then `display
  topology changed`). Three of the topology ones changed the captured geometry
  (1024×768→3440×1440 on C2 create, 3440×1440→1024×768 on C3 remove, and the first create with
  `#displays` 1→2): all announced, the client logged `reset video handler` within 1 s each time
  and the picture followed (screenshots 12, 13-*). Before the fix that line was missing on this
  path (see the 09-07 logs above).
- Client log over the whole run: 2 `width/height mismatch` lines, both a single frame of the old
  stream right at the switch, followed by the reset within 100 ms (the transient case the code
  comment describes); 0 `refused for their size` warnings — the recovery never triggered
  spuriously. The stuck-decoder case itself needs a GPU decoder and could not be reproduced in
  the VM; the server fix removes its trigger, the client code is reviewed only.
- Windows home: native title bar with minimize, greyed maximize and close, no custom buttons
  (03b). macOS home in the VM: traffic lights only, zoom greyed (06); the red button quits the
  process (`pgrep` empty afterwards).
- Rig notes: QEMU with `-display cocoa` hung twice within a minute of boot (guest dark at 100 %
  CPU, QMP refused) while the Mac's main display was a SimpleDisplay virtual one; `-display none`
  (screenshots via QMP `screendump`) ran fine. Tart's VNC needs `move X Y click 1` in ONE
  `vncdo` call (each call is a new session and the pointer starts at 0,0 → Apple menu). The
  client process started with `--connect` logs under `log\flutter_ffi\`, not the top-level
  `remotedisplay_rCURRENT.log`. `dir` shows stale sizes for open log files on NTFS.
  Screenshots and logs in `to_remove/capturas-1.0.12/`.
