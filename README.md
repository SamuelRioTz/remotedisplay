<p align="center">
  <img src="tools/branding/out/master-macos-1024.png" width="112" alt="Remote Display">
</p>

<h1 align="center">Remote Display</h1>

<p align="center">
  Remote desktop for your Mac from Windows, iPad or another Mac — <b>direct, discovered, no accounts</b>.
</p>

<p align="center">
  <a href="https://remotedisplay.app">remotedisplay.app</a> ·
  <a href="https://github.com/SamuelRioTz/remotedisplay/releases/latest">Downloads</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="LICENSE">AGPL-3.0</a>
</p>

---

Remote Display is a self-hosted remote desktop for macOS hosts, built on the
[RustDesk](https://github.com/rustdesk/rustdesk) engine (AGPL-3.0). It started as a
fork to control a Mac Studio from a Windows PC over Tailscale without signing up
anywhere: a direct connection with a password, machines discovered on the LAN, and the
same Mac reachable from outside. It shows the Mac's displays as they are; the monitors
themselves are the Mac's business (add virtual ones with
[SimpleDisplay](https://github.com/SamuelRioTz/SimpleDisplay) if you want them).

## Features

- **Any display, any window.** Pick which of the Mac's displays you see, open each one
  in its own window, or show them all at once (desktop clients).
- **Works with SimpleDisplay.** Want a monitor the size of your window? Add a virtual
  display on the Mac with SimpleDisplay or macOS itself; Remote Display shows it like any
  other display and never changes the Mac's configuration.
- **Finds your Mac, at home and away.** Computers on your LAN show up by themselves, and
  the Mac tells clients its Tailscale address, so it stays reachable from other networks.
  Pick the network per computer; passwords are remembered per address.
- **iPad with an external monitor.** Put one of the Mac's displays on the connected
  monitor and keep another on the iPad. Trackpad-style touch input.
- **No accounts, no cloud, no IDs.** Direct connection over your LAN or VPN
  (Tailscale works well), with a password you set. Nothing leaves your network.
- Clients for **Windows, macOS, Android and iOS** (Flutter); server for **macOS 14+**
  on Apple silicon (menu-bar app, notarized).

## Downloads

Binaries are on the [Releases](https://github.com/SamuelRioTz/remotedisplay/releases)
page: Windows installer and portable zip, macOS client and server DMGs, Android APK,
iOS IPA (development signing for now).

The macOS builds are Apple silicon only for now (the engine is not built for Intel).
Since 1.0.4 the client and server DMGs are signed with a Developer ID certificate and
notarized by Apple, so macOS opens them without Gatekeeper warnings.

## Quick start

1. On the Mac, install **Remote Display Server** from the DMG, open it, turn the service
   on, grant Screen Recording and Accessibility, and set a password.
2. On the client, tap the Mac in *Your computers* (or connect to its IP, port `21118`, with
   that password). Machines on the same LAN are discovered automatically, and the server
   tells the client its Tailscale address too, so the Mac stays reachable from other
   networks. Each computer lists its addresses (LAN, Tailscale) with whether they answer
   from where you are: tap a chip to pick the network, the card to connect; the gear
   renames the computer, adds an address or forgets a password.
3. Open the display menu in the toolbar: pick a display, open it in a new window, or
   show all of them. Want a virtual monitor? Add it on the Mac with SimpleDisplay; it
   shows up as one more display.

## How it works

- `server-mac/` — the macOS menu-bar server (SwiftUI) bundling the engine as
  `remotedisplayd`, a per-user service. It shows the Mac's displays as macOS reports
  them (physical ones and any virtual display added with SimpleDisplay) and ignores the
  reconfiguration noise a hardware mirror produces, so a mirrored display no longer
  restarts the video every second.
- `engine/rustdesk/` — a vendored fork of RustDesk 1.4.9 with the changes listed in
  [`HOOKS.md`](HOOKS.md) and [`tools/patches/`](tools/patches/): serverless LAN
  discovery with the Tailscale address advertised, and stability work around macOS
  display reconfiguration (mirrored displays, Retina capture with several clients).
- `client/` — the Flutter client (new UI on top of the engine's `flutter_hbb` package).
- `docs/tests/` — measurements, VM harnesses and verification notes behind the macOS 26
  quirks we hit (mirror sets, per-process display lists, capture streams going silent),
  including the virtual display backend this project shipped up to 1.0.8 and then
  handed back to SimpleDisplay.
- `website/` — the landing page for [remotedisplay.app](https://remotedisplay.app):
  static HTML with EN/ES/DE strings in `website/l10n/`.

Build recipes: [`tools/README.md`](tools/README.md) (Windows and Mac),
[`release/README.md`](release/README.md) (how the release artifacts are produced).

## Known limitations

- Remote Display does not create virtual monitors or change the Mac's display
  configuration; use SimpleDisplay or macOS for that.
- "All displays" is available on the desktop clients (Windows, macOS); the iPad shows one
  display at a time, plus one on an external monitor.
- Connections are direct (no relay yet). Use a LAN or a VPN.

## Contact

Questions, feedback or anything else: **info@remotedisplay.app**. Bugs and feature
requests are best reported as [GitHub issues](https://github.com/SamuelRioTz/remotedisplay/issues).
For security problems please email instead of opening a public issue (see
[`SECURITY.md`](SECURITY.md)).

## License

Remote Display is free software under the **GNU Affero General Public License v3.0**
(see [`LICENSE`](LICENSE)). It contains a modified copy of
[RustDesk](https://github.com/rustdesk/rustdesk) (© RustDesk contributors, AGPL-3.0);
see [`NOTICE.md`](NOTICE.md). RustDesk is a trademark of its owners; this project is not
affiliated with them.
