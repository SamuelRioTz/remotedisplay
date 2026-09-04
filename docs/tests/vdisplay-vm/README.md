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
