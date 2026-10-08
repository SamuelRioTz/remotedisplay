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

## 2026-09-23 — 1.0.13: the same Mac listed twice, grouping by engine id, dark title bar on Windows

Symptom on Sam's Windows client (1.0.12): the home showed "samuels-mac-studio" (LAN .115 + Tailscale)
and a second computer "mac" (LAN .119, unreachable) — the same Mac Studio. On the PC the second card
came only from the recent peer saved on 09-16 for 192.168.1.119: `hostname = 'mac.lan'`, user sam,
Mac OS; the discovered-peers cache had no .119 at all and nothing answers there today.

Diagnosis: the Mac has no fixed HostName (only LocalHostName "Samuels-Mac-Studio"), and in that
case macOS derives the kernel hostname from the router's reverse DNS of the current address, falling
back to LocalHostName.local. Sam's router hands out "Mac.lan" (today it maps it to .161): on the
09-16 lease the Studio announced `mac.lan`, today `samuels-mac-studio.local`. The engine used that
kernel hostname in both the discovery reply (`lan.rs`) and the login response (`connection.rs`), the
client grouped addresses into cards by hostname label only, the vendored `lan.rs` threw away the
stable engine id the discovery reply carries (`id` became the IP), and nothing expires recent peers.

Changes:
- `common.rs` `whoami_hostname()`: on macOS returns the LocalHostName (`SCDynamicStoreCopyLocalHostName`,
  new `platform::local_hostname()`), falling back to the kernel hostname. Covers discovery, login
  response and the generic `hostname()`.
- `DiscoveryPeer` and `PeerInfoSerde` (hbb_common `config.rs`) gain `machine_id` (serde default, old
  TOML files still load). `lan.rs` keeps the pong's `id` in it (also for the advertised Tailscale
  addresses; the bare port-scan entry does not erase it). `connection.rs` adds `machine_id` to
  `platform_additions` of the login response; `client.rs` `handle_peer_info` saves it with the peer;
  `ui_interface.rs` passes `machine_id` (and `online` for discovered peers) to Flutter; `Peer` model
  gets `machineId` and `online`.
- `home.dart` `_machines()`: cluster by machine id first (the id's name is the first seen: discovered
  entries, then recent peers newest first, so it is the host's current name; an address with only a
  name joins the id that announced that name), hostname/Tailscale/manual/IP as before. The card key
  stays a hostname label so aliases, selected networks and manual addresses keep working. Old
  addresses that do not answer, were not found by this scan and are not manual are hidden while the
  machine answers elsewhere; a machine that is off still shows every address.
- Windows runner `win32_window.cpp`: the native title bar (kept since 1.0.12) opts into DWM's
  immersive dark mode following `AppsUseLightTheme`, like Flutter's runner template (attribute 20,
  fallback 19; refreshed on `WM_DWMCOLORIZATIONCOLORCHANGED` and `WM_SETTINGCHANGE ImmersiveColorSet`);
  `dwmapi` linked in `CMakeLists.txt`. Before, the bar was always white over the dark home.
- `home.dart`: on desktop the home follows a system light/dark switch while it is open
  (`onPlatformBrightnessChanged` → `Get.changeThemeMode`, as the engine's own App does). The client
  runs its own root widget, which evaluated the theme once at start, so the title bar (live) and the
  content (static) diverged until a restart.
- `release-mac.sh --skip-client`; READMEs: Rosetta requirement (macOS 27 came without it, so the macOS
  client, iOS and Android builds could not be made on this Mac for 1.0.13), PC bindgen gotcha.

Verification (two fresh VMs: Tart clone of `macos-tahoe-base` 26.6.2 with the notarized
`RemoteDisplay-Server-1.0.13-macos.dmg` installed by `ditto` + `xattr -cr`, config + LaunchAgent
written as the app does, TCC granted by sqlite, password over stdin; Windows 11 QEMU restored to
`base-limpio` with the portable zip built on the PC from the same sources, engine DLL included).
Server VM LocalHostName set to `Test-Mac-Server`; the Windows guest reaches the server through
two loopback forwards on the Mac, 21119 and 21120 → VM:21118, so the same server is seen at two
"addresses". Screenshots and logs in `to_remove/capturas-1.0.13/`:
- Discovery reply (probe script `discover_probe.py`, UDP 21119 from the Mac): `hostname =
  'test-mac-server'`, `id = '436411194'`. With `sudo scutil --set HostName mac.lan` (what the router
  imposed on Sam's Mac) the reply is unchanged; renaming the LocalHostName to `Renamed-Mac` changes
  it to `renamed-mac` at once, no engine restart (01-discovery-pong-hostname.txt).
- Login path: after `--connect 10.0.2.2:21119` the saved peer has `hostname = 'test-mac-server'`,
  `machine_id = '436411194'` (02). After the rename, `--connect 10.0.2.2:21120` saves
  `renamed-mac` with the same id (03-recent-peers-after-rename.txt): two recent peers, two names,
  one id — the pre-fix situation, which 1.0.12 shows as two cards.
- Home: ONE card "renamed-mac", admin · Mac OS, chips `LAN · 10.0.2.2:21120` and `LAN · 10.0.2.2:21119`,
  both reachable (04). Forwarder 21120 killed + refresh: only 21119 on the card (05); forwarder back +
  refresh: both again (06). Reconnecting through 21119 with the kernel hostname still `mac.lan`
  saves `renamed-mac`, not `mac.lan` (07).
- Windows dark mode (`AppsUseLightTheme=0`) + fresh launch: dark title bar over the dark home (08);
  light mode: light bar over the light home (04–06). Toggling the setting while the home is open
  (registry + `WM_SETTINGCHANGE ImmersiveColorSet` broadcast from an interactive scheduled task): bar
  and content switch together to dark (10) and back to light (10b). With the first build the bar
  switched and the content did not (09) — the `home.dart` theme change above came from that run.
- Not exercised in this rig: the discovery path on the client side (QEMU user networking carries no
  broadcast to the Tart VM; the pong content was checked from the Mac, the client-side storage of
  `machine_id` from the pong is code-reviewed only), the macOS/iOS/Android clients (not built).
- Rig notes: `screen -X quit` on a `bash -c "sshpass ssh -L …"` session leaves the ssh alive — kill the
  forwarder with `pkill -f`. A `WM_SETTINGCHANGE` broadcast sent from an ssh session (session 0) does not
  reach the interactive desktop; send it from a scheduled task. Old macOS `screen` has no `-Logfile`.
  The Tart VM's sshd rejects the first password attempt now and then — retry.

## 2026-10-06 — 1.0.14: the home lists only the computers that answer from this network

Symptom on Sam's Windows client (1.0.13): every computer the client had ever known stayed on the
home — Luz's Mac twice (a live `luzs-mbp` card and a `luzs-macbook-pro` card with four old addresses,
hotspot, two old leases and an offline Tailscale IP, all struck through, "Not reachable from this
network right now"). Sam wants to see only what answers from the network he is on.

Diagnosis of the ghost card: a recent peer saved by a pre-1.0.13 client (no `machine_id`) under the
hostname the router gave Luz's Mac back then; none of its addresses answers, so the 1.0.13 grouping has
nothing to join it with, and recent peers never expire. Luz's Mac also still runs an older server (its
pong says `luzs-mbp.lan`, the kernel hostname, not the LocalHostName a 1.0.13 server announces).

Change (`client/lib/home.dart`, `client/lib/machines.dart`):
- `Machine.available` = some route answered the TCP probe. The home lists only available machines;
  the rest are counted in one muted line under the cards ("N computers do not answer from this
  network · Show/Hide"; the whole line is the toggle, 44 pt tall on touch). Shown, they are the same
  dimmed cards as before, so Forget (gear or long press) and "add a Tailscale address" still work. The
  toggle is not persisted and folds again once nothing is left to show.
- `_probe()` no longer resets a known address to "unknown" while re-checking: `_reach` keeps the last
  verdict and a new `_probing` set (→ `MachineRoute.probing`) marks the probe in flight. `null` now
  means "never probed" (the chips' "Checking…" dot). `Machine.unknown` (some address without a first
  verdict) is what the home judges on — the empty-state text, the note and a card's dimmed look;
  `Machine.probing` (in flight or unknown) is informational. Judging on `probing` made the note, the
  empty text and the dimmed look blink for up to 1.5 s on every 20-second round, i.e. the same blink
  the change set out to remove, moved from the cards to the note.
- A verdict that arrives after the address was forgotten is dropped (the entry is no longer in
  `_probing`), and the connect is capped at twice the probe timeout so a slow resolver for a hostname
  typed by hand cannot hold the first verdict for long.
- `_probeNew()` also re-probes, on every peers change, the addresses the engine reports online while
  our last verdict said no: a machine that came back is listed on the engine's next discovery push
  instead of waiting up to 20 s hidden.
- Empty states: while a scan runs or an address has no first verdict, "Looking for computers on your
  network…"; then "No computers answer from this network right now." when there are hidden ones, else
  the original "No computers yet…" text. The manual-connection card still opens by itself only when
  nothing at all is known. The note is held back only until every known address has a first verdict.
- Pre-existing, fixed on the way: the old-tailnet ghost filter compared the full id with the bare
  tailnet IPs, so a Tailscale address with a port (`100.64.0.2:21120`) was dropped from the list.
- Docs: README quick start, website `how_client_desc` (en/es/de) and the static copy in
  `website/index.html`.

Verification: `flutter analyze` with the project's Flutter 3.24.5 (`/Users/sam/flutter`) on the Mac —
20 issues, all pre-existing infos, none on changed lines. Released as **1.0.14 (15)**: Windows client
built on the PC with `release/release-windows.ps1` (`gh` there is unauthenticated, so the zip and the
installer were copied to the Mac with `scp` and uploaded from there); server DMG rebuilt, signed and
notarized on the Mac from the same engine binary as 1.0.13 (server code unchanged, version only — the
website resolves its download buttons against the latest release, so the Mac button needs the DMG in
it). The three Flutter clients followed the same day once Rosetta was back —
`softwareupdate --install-rosetta --agree-to-license` ran fine WITHOUT sudo on macOS 27.0 — and after
three fixes the first macOS 27 / Xcode 27 / Android 15 build round forced:
- Xcode 27 rejects the deployment targets the Flutter templates carried (`MACOSX_DEPLOYMENT_TARGET`
  10.14 in the client's Runner project and the plugin pods, 10.13 in some pods: "the range of supported
  deployment target versions is 12.0 to 27.0"; the iOS SDK's floor is 15.0). `client/macos`: Podfile
  `platform :osx, '12.0'` + a post_install hook forcing `MACOSX_DEPLOYMENT_TARGET = '12.0'` on every
  pod, Runner.xcodeproj 10.14 → 12.0. `client/ios`: `platform :ios, '15.0'`, the existing hook and the
  Runner project 14.0 → 15.0.
- Xcode 27's linker refuses the engine dylib cargo produces with `strip = true`: "ld: mis-aligned
  LINKEDIT string pool" — rustc's strip leaves `stroff` 4-byte aligned (25511404 % 8 = 4), Xcode's
  `strip -x` leaves it 8-byte aligned. `release-mac.sh` now links `liblibrustdesk.dylib` with
  `CARGO_PROFILE_RELEASE_STRIP=false` and runs `strip -x` on it (same final size, 25.7 MB).
- Android 15 (Lenovo TB373FU, Play services current): Play Protect REJECTS the sideload of the APK —
  "Unsafe app blocked: This app was built for an older version of Android and doesn't include the
  latest privacy protections" (logcat `VerifyApps … result=REJECT`, `INSTALL_FAILED_VERIFICATION_FAILURE`).
  The APK targets SDK 33 (`client/android/app/build.gradle`, same as the engine's). Not changed in this
  release (a targetSdk bump needs a run of the Android client first: foreground-service types, etc.);
  installed with the verifier paused for adb (`settings put global verifier_verify_adb_installs 0`,
  then `settings delete …` to restore the default). Pending: target SDK 34/35.
Not exercised: a two-VM run with screenshots (the Windows VM has no broadcast path to the Tart server).
Sam checks the build on his PC against the Studio and Luz's Mac.

## 2026-10-06 — Server 1.0.13 on Sam's Studio: in-place upgrade, `open` reaches the engine instead of the UI

Server 1.0.13 replaced 1.0.12 on Sam's Mac Studio (macOS 27.0) while a session from the PC was open:
about one second of downtime, the client reconnected on its own. Sequence that worked, unattended,
with automatic rollback:
1. Swap the bundle on disk first: `mv` the installed app out to a backup, `mv` the staged, verified
   copy from the notarized DMG (`gh release download`, so no quarantine; `codesign --verify --deep
   --strict`, `spctl -a -t exec`, `stapler validate`) into /Applications. The running processes keep
   their open inodes. App Management did not object from the VS Code shell.
2. `kill -TERM` the menu-bar app. AppKit has no SIGTERM handler, so it exits without the quit path
   (`stopEngineForQuit`), the engine keeps serving and the app's `ensureDesiredState` timer dies with
   it, so nothing re-bootstraps the agent mid-swap. No `osascript … quit` (an Automation prompt from
   the shell's host app would need a click).
3. `launchctl bootout gui/501/app.remotedisplay.server`, wait until `remotedisplayd --server` is gone,
   `pkill -KILL` the orphaned `--cm-no-ui` (it ignores SIGTERM and a new server would reuse it over
   `ipc_cm`), then `launchctl bootstrap` the unchanged plist (its program path is the /Applications
   one). Not `kickstart -k`: the new server must start after the old connection manager is gone.
4. Verify: LISTEN on 21118 and UDP 21119 by the new pid, `/tmp/RemoteDisplay-501/ipc.pid`, the perms
   json `{"accessibility":true,"screen":true}` with a fresh mtime (the engine rewrites it every 2 s),
   sha256 of `RemoteDisplay.toml` and `RemoteDisplay2.toml` unchanged (`RemoteDisplay_hwcodec.toml`
   changes on every start), the discovery pong (`discover_probe.py`) now `samuels-mac-studio` with the
   Tailscale address. The audio/encode/SWITCH ERROR lines in the server log are normal.

Finding: with the engine running and the menu-bar app closed, `open "/Applications/Remote Display
Server.app"` does nothing visible. `remotedisplayd --server` runs an NSApplication inside the same
bundle, so LaunchServices lists it as the running "Remote Display Server" (same bundle, same bundle id),
matches it as the already running application and sends it a reopen event; `open -W` never returns.
`open -n` (new instance) launches the UI. Anyone opening the app from Finder or Spotlight in that state
hits the same thing (normally the app starts first and starts the engine, so it only shows when the
engine outlives the app). The engine probably needs its own bundle identity. Anchored patterns for
`pgrep`/`pkill` (`/Contents/MacOS/remotedisplayd --server$`): an unanchored `-f` matches unrelated
shells whose command line contains the words.

## 2026-10-06 — iOS 27 SDK: the client must adopt the UIScene life cycle (1.0.14 iPad build)

Symptom: the 1.0.14 IPA, the first one built with Xcode 27 (iOS 27.0 SDK), installs on Sam's iPad Pro
(iPadOS 27.0) and is terminated at launch; the 1.0.12 IPA from Xcode 26 runs on the same iPad. Six
crash reports (`Runner-2026-10-06-18xxxx.ips`): EXC_BREAKPOINT in
`UIKitCore ___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke`, called from
`-[UIApplication workspace:didCreateScene:…]`, before any app code (frame 23 is `UIApplicationMain`).
Apple (TN3187, UIKit release notes): apps linked against the iOS 27 SDK must adopt the UIScene life
cycle; there is no opt-out. Flutter 3.24.5 has no scene support of its own (no `FlutterSceneDelegate`,
`grep -i scene` over the pinned Flutter.framework headers: 0 hits), and `client/ios/Runner/Info.plist`
had no `UIApplicationSceneManifest`.

Change (`client/ios/Runner`):
- `Info.plist`: `UIApplicationSceneManifest` with `UIApplicationSupportsMultipleScenes = false`; the
  Application role keeps `Main.storyboard` (`UISceneStoryboardFile`), so `RunnerFlutterViewController`
  is still created by UIKit through `initWithCoder` exactly as before, with
  `$(PRODUCT_MODULE_NAME).SceneDelegate`; the `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
  role points at `ExternalDisplaySceneDelegate`. `UIViewControllerBasedStatusBarAppearance` flips to
  true: the iOS 27 SDK makes `UIApplication.statusBarHidden/statusBarStyle` setters no-ops, which is the
  path Flutter 3.24.5 takes when the key is false, so the session's status-bar hiding would have
  silently stopped working; with true Flutter drives `FlutterViewController.prefersStatusBarHidden`.
- `SceneDelegate.swift` (new): under scenes UIKit never fills `FlutterAppDelegate.window` and the
  storyboard controller exists only AFTER `didFinishLaunching`. The scene delegate hands the window to
  the app delegate, calls `attachFlutter()`, replays the launch options UIKit no longer passes
  (`connectionOptions.urlContexts` → `launchOptions[.url]`, so uni_links keeps the cold-start
  `remotedisplay://` link) and forwards `openURLContexts` / `continue userActivity` to the
  `UIApplicationDelegate` methods FlutterAppDelegate still implements. No lifecycle forwarding is
  needed: FlutterViewController and the plugin life-cycle delegate observe the UIApplication
  notifications, which UIKit keeps posting under scenes.
- `AppDelegate.swift`: `didFinishLaunching` keeps only the bundling dummy + `super` (`window` is nil
  there now; the old `window?.rootViewController` gate would silently skip every channel and hand nil
  registrars to the plugins). Plugin registration, the `remotedisplay/pointer` channel and the
  `PointerCaptureBridge` moved verbatim into `attachFlutter()`, keyed on the controller's identity:
  UIKit builds a new storyboard controller (and implicit FlutterEngine) on every scene connection.
- `ExternalDisplayController.swift` (new, replaces the UIScreen/`UIWindow(frame:).screen` code): in a
  scene-based app every window belongs to a `UIWindowScene`, and the supported way to replace mirroring
  is a window attached to the scene with the `windowExternalDisplayNonInteractive` role. iPadOS 16–26:
  the system connects that scene by itself (Info.plist role) and the controller adopts it; iPadOS 27:
  the system no longer offers it, so the host controller registers a `UISceneAccessory`
  (`.externalNonInteractive`), disabled until Dart attaches; presence = `registration.isAvailable`,
  read from `RunnerFlutterViewController.updateProperties()`. The Dart contract
  (`remotedisplay/extdisplay`: isConnected · screenSize · attach · detach · setDisplay · cursorPos;
  events connected/disconnected; `remotedisplay/extview`: setDisplay · cursorPos · dispose) is
  unchanged, so `client/lib` needed no change.
- `project.pbxproj`: the two new files in the Runner target.

Also fixed on the way (same Xcode 27 round): deployment targets ≥ 12.0 (macOS) / 15.0 (iOS) in both
Podfiles and Runner projects; the macOS client dylib linked without cargo's strip (see the 1.0.14
section above).

Verification so far: the IPA builds (Xcode 27, 15.0 deployment target) and installs on the iPad; its
Info.plist carries the manifest (`Runner.SceneDelegate` + `Main`, `Runner.ExternalDisplaySceneDelegate`).
The launch test itself is PENDING: the iPad locked itself before the first attempt and iPadOS refuses to
launch apps on a locked device (`FBSOpenApplicationErrorDomain error 7: the device was not, or could
not be, unlocked`; a `devicectl` screenshot of a locked iPad is black). A retry loop (`devicectl device
process launch --console`, alive after 25 s, screenshot, new `Runner-*.ips`) runs until the iPad is
unlocked. The iOS Simulator is no substitute here: only the iOS 26.5 runtime is installed (the trap needs
27), and the engine does not build for `aarch64-apple-ios-sim` anyway (`coreaudio-sys` bindgen rejects
the triple — `BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim=--target=arm64-apple-ios15.0-simulator`
gets past it — then `libsodium-sys` fails). Until the iPad run passes, the 1.0.14 release carries no
IPA and the notes say why; 1.0.12 is what runs on the iPad when the new build is not installed.
Also: `tools/build-ios.sh` now exports `IPHONEOS_DEPLOYMENT_TARGET=15.0` for the Rust library, matching
the app.
End of day: the iPad stayed locked for the whole evening (three retry windows, ~2.5 h). On the last
window the launch attempt failed with a `devicectl` transport error instead of the lock error (the iPad
had moved from USB to the network pairing: `com.apple.dt.CoreDeviceError error 3`, "connection was
invalidated"); the loop's fallback took that as an early exit and reinstalled 1.0.12, so the iPad is
back on the known-good build. The UIScene IPA stays at `release/out/RemoteDisplay-1.0.14-ios.ipa`
(25.2 MB, 19:32), to be installed and launched with the iPad unlocked and on USB; the v1.0.14 release
gets its IPA after that run.

## 2026-10-07 — 1.0.15: one card per computer, even when discovery replies never arrive

Symptom on Sam's Windows client (1.0.14): the Mac Studio listed twice — `mac` with its Tailscale address
100.64.0.2 and `samuels-mac-studio` with its LAN address 192.168.1.115, both answering, same user.

Diagnosis (on the Studio itself, server 1.0.14): the UDP discovery reply is right — pinged on the LAN
address it carries the engine id, the LocalHostName and `misc {"addrs":["100.64.0.2"]}`; pinged over
Tailscale, id and name. The shipped Windows DLL contains the matching client code. So the home would have
grouped both routes the moment any identified entry for 100.64.0.2 reached it. The only identity the PC
had for that address was a recent peer saved when the server was 1.0.12: hostname `mac` (the router's
reverse-DNS name of that lease) and no `machine_id`. The LAN entry had been refreshed by a 1.0.13+ login
(new name + id). No shared id, different names → two cards. The replies evidently never reach that PC
(its TCP probes do: the server log shows them from 192.168.1.149 and 100.64.0.4 every 20 s); a firewall
rule on the PC is the usual cause, not verified there (`tools/scripts/discovery-diag.ps1` now dumps what
would settle it).

A second fact found on the way, and the base of the fix: on a direct connection the host speaks first —
`Connection::on_open` sends `Hash{salt, challenge}` before reading anything (the direct listener in
`rendezvous_mediator.rs` runs `create_tcp_connection(.., secure=false, ..)`, no `SignedId`). The salt is
generated once per installation (`Config::get_salt`, `RemoteDisplay.toml`) and came back identical on
127.0.0.1, 192.168.1.115 and 100.64.0.2 (45-byte frame; `docs/tests/vdisplay-vm/harness/discover-probe.py`'s
sibling `first_frame.py` lives in the session scratchpad, the captured frame is in
`client/test/first_frame_test.dart`). Any server version sends it, and the client's 20-second probe is
already a TCP connect to that port.

Change:
- **Client fingerprint** (`client/lib/first_frame.dart`, `home.dart` `_probe`, `machines.dart`
  `groupMachines`): the probe reads the first frame (bounded to 1 s) and keeps ip → salt in the local
  option `rd-fingerprints`. `groupMachines()` — the former `_machines()`, moved to `machines.dart` as a
  pure function over `GroupingInput` so it can be unit-tested — ties an address without an engine id to
  the machine whose other address answered with the same salt (it takes that machine's id), or keys the
  machine by `fp:<salt>` when no id is known anywhere. Guards: an empty salt links nothing; a salt seen
  with two different engine ids links nothing; a fingerprint-linked address only adds a name where the
  machine has none and never maps its (stale) name to the id, so another computer called `mac` stays its
  own card. `MachineRoute.identity` + `Machine.donorFor()` restrict password borrowing between routes: the
  borrowing route must carry the engine id on its own (`ownId`: from its discovery reply or a login
  through it) and share it with the donor — a route tied in by the salt alone, or by name, asks for the
  password once (the salt is public: a rogue port echoing it must not be lent a password hash). After
  that login the engine has saved the route's identity and it borrows like any other.
  `_migrateKeys()` (`movedKeys` in machines.dart) moves aliases, remembered route and manual addresses
  stored under a key that vanished (`mac`) to the key its addresses sit under now (`rd-last-keys`, and
  the remembered route's own address for the first run) — only while the address still answers as the
  same host (probe finished, same salt as recorded in `rd-last-fingerprints`), so an address re-leased
  to another computer moves nothing; a key kept alive only by a manual address does not block the move.
- **Login propagation** (engine, `remotedisplay:`-marked): `server/connection.rs` adds `addrs` (the
  host's Tailscale addresses, the same set the discovery reply advertises; after authentication; only
  while `enable-lan-discovery` is on) next to `machine_id` in the login response; `client.rs`
  `spread_identity` files that identity (hostname, platform, user, id) into the peer file of every such
  address — healing the stale `mac` entry on the first LAN connection and learning the Tailscale route
  without UDP — never touching passwords or options (`lan.rs` `host_tailscale_addrs`/`login_addrs`,
  unit-tested).
- **Diagnostics**: `lan.rs` tallies each discovery run (replies to the UDP pings vs hosts the port scan
  found; `discover done: N replies, M port hits` in the client log), `flutter_ffi.rs` adds it as the
  `discovery` key of the `load_lan_peers` event, and the home shows a muted line after two finished runs
  with port hits and no reply: "No reply to network discovery: computers are found by their open port
  only. A firewall on this computer may be blocking the UDP replies to Remote Display (allow the app for
  inbound UDP)." (The replies come from the host's port 21119 to the ephemeral port the ping left from,
  so a local-port rule changes nothing; a per-program inbound UDP rule for remotedisplay.exe does.)
  `tools/scripts/discovery-diag.ps1` (read-only) dumps the PC's discovered peers, recent peers, home
  options, firewall rules naming remotedisplay.exe and the last discovery log lines.
- Fixed on the way: `Peers._updatePeers` (engine Flutter model, HOOKS.md row 2) overwrote the engine's
  `online` flag with the previous list's state, so the home's `found` set and `_probeNew` never saw it;
  peers that carry the flag (`Peer.onlineKnown`) now keep it.
- Also seen, left for its own change: every 20-second probe runs `create_tcp_connection` on the Mac,
  which spawns `caffeinate -u -t 5` and a full `Connection` — a client home left open keeps the Mac's
  display awake.

Review: three adversarial reviewers (engine, Dart, security/compatibility) with one skeptic per finding
confirmed 12 of 15 findings, all fixed before the release: the dual-stack listener reports the local
address as IPv4-mapped IPv6, so the server-side exclusion never matched (`to_canonical`); the discovery
tally is tagged with its run so an overlapping run cannot corrupt it; `spread_identity` refreshes the
recent peers off the thread that holds the session lock and never re-identifies a file already tied to
another engine id; `_migrateKeys` moves nothing for an address that answers as another host and is not
blocked by a manual-only card; a salt-only identity yields to the shared-name rule (the other probe may
not have finished) unless that id answers with another salt; a route tied in by the salt alone borrows
no password (`ownId`); the note no longer names a local UDP port; the PowerShell script is pure ASCII
(Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page). Refuted: unbounded growth of
`rd-fingerprints` (bounded by the known addresses, pruned on Forget), preset-salt sharing (no preset
password in this product).

Verification: `cargo test --release --lib --features flutter,hwcodec advertised_addrs_tests` — 5 passed
(`pick_tailscale_addrs` incl. the mapped-IPv6 exclusion, `login_addrs` cases); `flutter test` in
`client/` — 30 passed (`first_frame_test.dart`: the captured frame, trailing bytes, truncation, no Hash
member, odd salt, 2-byte header; `machines_test.dart`: the reported case with and without fingerprints,
password borrowing before and after the identity is saved, a one-sided salt, a different salt under one
name, the mirror case, one salt with two ids, empty salt, two bare addresses with one salt, the stale
name pulling nobody in, name-joins-id, a machine that is off, own/other tailnet filtering, a rogue port
echoing the salt, `movedKeys` upgrade/last-key/re-leased/live/manual-only cases, the discovery tally);
`flutter analyze` — the 20 pre-existing infos only.

Released as **1.0.15 (16)**, tag `v1.0.15` on `62f6dda`, five assets: Windows installer + portable
(built on the PC: `tools\windows\build-dll.cmd` for the engine DLL, then `release\release-windows.ps1`,
both run through one-shot `schtasks` jobs because a process started with `Start-Process` from the ssh
session dies with it; the zip and the installer copied to the Mac with `scp` and uploaded from there),
macOS client DMG and server DMG (notarized, stapled, `spctl` = Notarized Developer ID), Android APK —
all from `release/release-mac.sh`. Checked before publishing: version 1.0.15 (16) in both DMGs and the
IPA; the engine inside the server app, the client dylib and the Windows DLL carry the new strings
(`discover done`, `not re-identifying`), the Dart snapshots of the macOS and Windows clients carry the
new home (`No reply to network discovery`, `rd-fingerprints`, `rd-last-keys`). Gotcha found on the way:
`vcvars64.bat` (VS 17.6+) sets `VCPKG_ROOT` to the vcpkg bundled with Visual Studio, so the DLL build
failed on missing opus/vpx/ffmpeg headers until `build-dll.cmd` set ours after it (`62f6dda`). The iOS
build (`release/out/RemoteDisplay-1.0.15-ios.ipa`) stays out of the release until the UIScene
adoption is verified on the iPad, which was not connected. The website resolves its download buttons
against the latest release, so it needed no deploy.
