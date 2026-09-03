# remotedisplay — my fork of RustDesk (serverless, LAN-only)

Our own fork of **RustDesk 1.4.9**. **The fork lives in [`../engine/rustdesk`](../engine/rustdesk)** (Rust
code in `engine/rustdesk/src` and `engine/rustdesk/libs`, Flutter UI in `engine/rustdesk/flutter`); this
`remotedisplay/` folder holds the deployment tooling. Working branch: `remotedisplay`.
The build commands in this README are run from `engine/rustdesk/` (they used to be the repo root).
The native macOS server lives in [`../server-mac`](../server-mac).

## What the fork contains (branch `remotedisplay`, our own commits)

| Change | Where | What it does |
|--------|-------|----------|
| Serverless | `libs/hbb_common/src/config.rs` | rendezvous → `127.0.0.1`, official server's public key blanked out: it **never** talks to external servers |
| No update check | `src/common.rs` | `check_software_update()` returns immediately |
| Headless CM | `src/core_main.rs` + `src/server/connection.rs` | connection manager with no UI (the non-flutter build has no Sciter; it used to crash on every connection) |
| No chat | `src/server/connection.rs` | the host ignores chat messages |
| Server listens for LAN discovery in serverless mode | `src/rendezvous_mediator.rs` | upstream only starts `lan::start_listening()` if `platform::is_installed()` (= `/Applications/RustDesk.app`); our headless `remotedisplayd` isn't installed that way → the server never answered pings and clients saw it as a bare IP until the 1st connection. Now it also starts if `is_serverless_lan()`. |
| Silent serverless mode + `--check-perms` | `src/common.rs`, `src/server.rs`, `src/hbbs_http/sync.rs`, `src/core_main.rs` | in serverless mode: no NAT test against 127.0.0.1:21116, no 30 config-sync retries with the root `ipc_service` (nor the 3 s startup wait), no heartbeat/sysinfo to 21114 (the lazy `SENDER` had `signal_receiver()` start it on every connection, skipping the `start()` gate), no remote auditing. `remotedisplayd --check-perms` prints `{"accessibility":..,"screen":..}` from a fresh process (TCC caches Screen Recording per process). |
| Auto codec picks VP9 on LAN | `libs/scrap/src/common/codec.rs`, `libs/hbb_common/src/config.rs` | shared `Config::is_serverless_lan()`; with *Auto* preference the server picks VP9 in serverless mode (AV1 only when explicitly requested). |
| Discovery without broadcast | `src/lan.rs` | besides UDP broadcast: **unicast** discovery ping to every host on the local subnets (+ Tailscale peers) and a TCP scan of the direct port; on iOS (broadcast doesn't go out without the multicast entitlement) interfaces are read with `getifaddrs` (`default_net` isn't available) and there's no Tailscale CLI |
| `showToolbar` / `keyHelpHorizontal` on the MOBILE RemotePage | `flutter/lib/mobile/pages/remote_page.dart` | like the desktop flag: hides the bar/FAB/gesture help; `MobileRemotePageController` (open/close keyboard + `isKeyboardShown`, real state also with a physical keyboard); `KeyHelpTools(horizontal:)` = auxiliary keys in ONE row with horizontal scroll instead of 3 rows. Used by `client/` on Android/iOS to put up ITS OWN toolbar. |
| Keyboard stays alive across background/reconnect (mobile) | `flutter/lib/mobile/pages/remote_page.dart` | reconnection dialogs steal focus with their own `FocusScopeNode` and nobody gives it back (they aren't routes), and the OS invalidates the IME connection on going to background → both virtual AND physical keyboard dead until the session is closed. Fix: `_restoreKeyboardFocus()` on `resumed` and in the first-frame callback (which re-fires on every reconnect; it no longer calls `_disableAndroidSoftKeyboard` while `_showEdit` is active, which left `FLAG_ALT_FOCUSABLE_IM` blocking the IME), and `onPointerDown` on the canvas restores focus like on desktop. |

The full diff against upstream (the only source of truth for "what's ours") is generated with
`bash engine/diff.sh` (or `--stat`); see [`../engine/SYNC.md`](../engine/SYNC.md).

## Deploying the host on the Mac (whenever you want)

```bash
# 1. Copy the fork to the Mac (from the repo root on this PC).
#    Includes remotedisplay/ (brings install-host.sh); excludes .git and target:
rsync -a --exclude=.git --exclude=target \
  ./ <user>@<mac>:~/dev/remotedisplay/

# 2. On the Mac — build (toolchain already installed: rust, vcpkg, llvm@17, nasm, ninja):
cd ~/dev/rustdesk
export VCPKG_ROOT=$HOME/vcpkg SDKROOT=$(xcrun --show-sdk-path)
export LIBCLANG_PATH=/opt/homebrew/opt/llvm@17/lib
export BINDGEN_EXTRA_CLANG_ARGS="-isysroot $SDKROOT"
$VCPKG_ROOT/vcpkg install --x-install-root=$VCPKG_ROOT/installed   # only the first time
cargo build --release

# 3. SIGN with a stable certificate BEFORE granting permissions (see below) and install:
bash ~/dev/rustdesk/remotedisplay/mac/install-host.sh <password>
```

### The permissions (TCC) trap — lesson learned

macOS identifies unsigned binaries by **cdhash** (a fingerprint of the exact build): every
rebuild invalidates the Screen Recording/Accessibility permissions already granted
(the toggle stays "on" but points at the old binary → `Failed to create capturer`).

**Fix**: create a self-signed code-signing certificate on the Mac once
(Keychain Access → Certificate Assistant → Create a Certificate → type "Code Signing",
name `RemoteDisplaySign`) and sign every build before installing:

```bash
codesign --force --sign RemoteDisplaySign --identifier app.remotedisplay.engine \
  ~/.local/share/remotedisplay/rustdesk
```

With a stable identity, permissions are granted **only once** and survive rebuilds.
There are 2 permissions, physically on the Mac: Screen Recording and Accessibility.

## Default codec: VP9 (server)

Upstream's auto codec picks AV1 if the client supports it; on LAN that buys nothing and its decode at
1080p/4K hangs modest clients (a 4-vCPU VM: endless "Connecting…" / black screen). Patch 06
(`libs/scrap/src/common/codec.rs` + `Config::is_serverless_lan()` in hbb_common): in serverless
mode with *Auto* preference the engine uses **VP9**; the client can still pick AV1
explicitly from Display → Codec. NOTE: `av1-test` in RemoteDisplay2.toml is NOT a preference
(it's the AV1 capability probe, which the engine rewrites to `'Y'`).

## LAN-only config (a second lock on top of the patch)

`mac/RemoteDisplay2.toml` and `windows/RemoteDisplay2.toml`: rendezvous/relay/api pointed at `127.0.0.1`,
`direct-server=Y` (port 21118), update-check disabled. Connection: direct IP
(`192.168.1.117` on LAN, `100.68.94.32` over Tailscale — both routes already tested).

## Building the Windows CLIENT (tested recipe — August 2026)

Prerequisites: VS Build Tools 2022 (C++), Rust, vcpkg. **Gotchas solved:**

1. **Rust toolchain = MSVC** (not gnullvm): `rustup override set stable-x86_64-pc-windows-msvc`
   at the repo root. This PC's default is gnullvm and it breaks the link with vcpkg.
2. **vcpkg deps** (triplet `x64-windows-static`, baseline `120deac`), classic mode without ffmpeg:
   ```
   vcpkg install opus:x64-windows-static libvpx:x64-windows-static libyuv:x64-windows-static aom:x64-windows-static libjpeg-turbo:x64-windows-static
   ```
3. **bindgen needs LLVM 18** (not 22): `LIBCLANG_PATH=C:\Users\sam\llvm-18.1.8\bin`
   and `BINDGEN_EXTRA_CLANG_ARGS=--target=x86_64-pc-windows-msvc`, and **remove llvm-mingw from PATH**
   (it contaminates with MinGW headers). With clang 22 the aom/vpx structs come out opaque.
4. **FFI bridge**: `cargo install flutter_rust_bridge_codegen --version 1.80.1`, then
   `flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --llvm-path "C:\Program Files\LLVM"`
   (ffigen needs libclang; install LLVM.LLVM).
5. **DLL**: `VCPKG_ROOT=C:\Users\sam\vcpkg cargo build --locked --features flutter --lib --release` → `target/release/librustdesk.dll`
6. **Flutter 3.24.5** (NOT the system's 3.44/stable — breaks on DialogTheme/extended_text):
   now via fvm: `C:\Users\sam\fvm\versions\3.24.5\bin` first in PATH (the old folder
   `C:\Users\sam\flutter-3.24.5` was left empty), `flutter build windows --release`. If the build
   fails with "CMakeCache.txt directory ... is different", delete `flutter\build\windows`
   (cache from an old checkout path).
7. **Assemble**: copy `target/release/librustdesk.dll` to
   `flutter/build/windows/x64/runner/Release/` (next to `rustdesk.exe`).

The final .exe: `flutter/build/windows/x64/runner/Release/rustdesk.exe` + LAN-only config in `%APPDATA%\RustDesk\config\RemoteDisplay2.toml`.

## Building for Android (tablet/phone → Mac) — tested recipe, August 2026

Two possible arm64 APKs, both with the same serverless Rust lib (`config.rs` → 127.0.0.1, direct IP only)
and both can be installed side by side. Everything is built **on the Mac**:
- **Our client** (`client/`, default): `tools/build-android.sh [--install SERIAL]` →
  `tools/out/remotedisplay-client-android-arm64.apk`, `applicationId app.remotedisplay.client`, label
  "Remote Display". Own home screen (one card per machine with a **saved** badge = remembered password, one tap connects;
  long press = forget device; manual connection) and its own session, `MobileSessionScreen`: the engine's
  **mobile** `RemotePage` (touch gestures, virtual keyboard, rendering) with `showToolbar: false`
  (patch 03) + our own `SessionToolbar`. Pill (desktop and mobile): `‹ · peer · [minimize] · fullscreen ·
  fit to screen · Input · Display · ✕`. **Input** = how I interact: Touch/Cursor mode and View only (mobile), virtual keyboard and
  **key help bar** (independent toggles, the bar via the controller's `setKeyHelpOverride`), cursor/key
  options (`toolbarCursor`, `toolbarKeyboardToggles`) and session options (audio, clipboard, lock, privacy).
  **Display** = what I see: monitors, View, Quality,
  Codec and Image (true color, quality monitor, multi-monitor; filtered out of `toolbarDisplayToggle` by label).
  Fit to screen (direct button) = adaptive style + `canvasModel.reset()`. Persistence: codec/quality/view and
  cursor/session toggles are saved by the engine per peer; touch mode in `kOptionTouchMode` (local, read by the engine
  on open); key help bar and fullscreen in our own local options (`remotedisplay-key-help-bar`,
  `remotedisplay-mobile-fullscreen`); the virtual keyboard isn't persisted. The key help bar ONLY obeys its own toggle. Local pointer (iPad trackpad / Android mouse) hidden over the
  remote canvas: on Android via `MouseRegion(cursor: none)`; on iOS Flutter does NOT implement cursors (the engine already sets
  `SystemMouseCursors.none` and does nothing) → the Runner (`client/ios/Runner/AppDelegate.swift`) uses
  `UIPointerInteraction` with `hidden` style, and Dart sends it the pill's rect over the `remotedisplay/pointer` channel
  along with whether a menu is open (there the pointer is visible). Persistent toggle `remotedisplay-hide-local-pointer`.
  Language: the whole client UI is in English and the engine is forced to `lang=en` (`mainSetLocalOption`) on startup.
  Disconnect (✕) on mobile closes without confirmation (`closeConnection()`; the RemotePage's dispose closes the session). Fullscreen on mobile = the system's status/navigation bar; with a physical keyboard (iPad) the engine doesn't
  restore it when the keyboard opens (`showToolbar:false` + iOS). The `client/android/` runner is a copy of the engine's with
  `applicationId`, label and paths (`cargo metadata` and protos → `engine/rustdesk`) adapted; `main.dart`
  has a `_runMobile()` branch (without window_manager/multi_window) and `home.dart` saves using `isDesktop`.
- **Engine** (`--engine`): upstream `flutter_hbb` (RustDesk's mobile UI, `com.carriez.flutter_hbb`)
  → `tools/out/remotedisplay-engine-android-arm64.apk`. Useful for isolating client bugs.

Steps the script performs (in case they need to be run by hand):
1. `vcpkg install --triplet arm64-android --x-install-root=~/vcpkg/installed-android` with `ANDROID_NDK_HOME=<sdk>/ndk/28.2.13676358`
   (+ symlink `installed/arm64-android`) → aom, ffmpeg mediacodec, libvpx, libyuv, opus, oboe, libjpeg, cpu-features. ~5 min.
2. `cargo ndk --platform 21 --target aarch64-linux-android build --locked --release --features flutter,hwcodec`
   → `target/aarch64-linux-android/release/liblibrustdesk.so`.
3. Copy the .so as `flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so` + `libc++_shared.so` from the NDK
   (`toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/`).
4. `flutter build apk --release --target-platform android-arm64 --split-per-abi` in `engine/rustdesk/flutter`.

**Gotchas solved:**
- Gradle 7.6.4 (the engine's) **doesn't run with the JDK 21** that ships with Android Studio → `brew install openjdk@17`
  and `flutter config --jdk-dir /opt/homebrew/opt/openjdk@17`.
- `build_android_deps.sh` isn't executable in the checkout: run it with `bash`.
- `build.gradle` signs the release with `signingConfigs.release` reading `android/key.properties` (gitignored,
  needed in `engine/rustdesk/flutter/android/` AND in `client/android/`); without that file the release build fails. Our own stable keystore: `~/.remotedisplay/android-release.jks`
  (alias `remotedisplay`, password `changeit`), so `adb install -r` updates without uninstalling.
- `~/.gradle/gradle.properties` with `org.gradle.jvmargs=-Xmx4g` (the repo's ships with 1 GB, too little for R8).
- **Unresolved libsodium**: `libsodium-sys` runs `./configure` with only `CC`/`CFLAGS` and uses macOS's
  `ar`/`ranlib` on ELF objects (warnings "not a mach-o file"); `libsodium.a` ends up without an index, the binaries don't
  link and the `.so` comes out with `sodium_*` **undefined** (doesn't load on the device). Fix: export
  `AR`/`RANLIB` = the NDK's `llvm-ar`/`llvm-ranlib` (the script does this) and, if it was already built wrong,
  `cargo clean -p libsodium-sys --release --target aarch64-linux-android`. Verify with
  `llvm-nm -D --undefined-only liblibrustdesk.so | grep sodium` (should be empty).
- Build with `--lib`: the binaries (`rustdesk`, `naming`, `service`) aren't used on Android.
- **client/: `flutter_plugin_android_lifecycle` pinned to 2.0.17** (dependency_overrides, same as the engine):
  2.0.26 compiles against android-35 and AGP 7.3.1's aapt2 fails with "RES_TABLE_TYPE_TYPE entry offsets
  overlap" when reading that `android.jar`. If that error shows up, look for which plugin bumped its version relative
  to the engine's lock.
- **vcpkg deletes packages from ANOTHER triplet**: in manifest mode, `vcpkg install --triplet arm64-ios
  --x-install-root=installed` wiped out all of `arm64-android` under the same root (and vice versa) → "could not find native
  static library `vpx`". One install-root per platform (`~/vcpkg/installed-android`, `~/vcpkg/installed-ios`;
  `installed/` stays for macOS) + symlinks `installed/arm64-android` and `installed/arm64-ios` pointing to them, which is
  where the build.rs scripts look. `build-android.sh`/`build-ios.sh` do this. Do NOT use the engine's
  `flutter/build_android_deps.sh` (it installs into `installed/`).
- **iOS: `___chkstk_darwin` undefined when linking the Rust lib**: cc-rs compiles the C objects (aom in `scrap`) for the
  SDK's iOS (26.x) while rustc links with a minimum of 10.0. Export `IPHONEOS_DEPLOYMENT_TARGET=14.0` before `cargo build`
  (and the same value in `client/ios` Runner/Podfile); if it was already built wrong, `rm -rf target/aarch64-apple-ios`.
- **client/android/app/build.gradle**: `cargo metadata`'s `workingDir` resolves against `client/android`
  → use `rootProject.file("../../engine/rustdesk")`; the protos (`sourceSets`) resolve against `app/`
  → `../../../engine/rustdesk/libs/hbb_common/protos`.
- The CI's `flutter_3.24.4_dropdown_menu_enableFilter.diff` patch isn't needed to build.

Usage on the tablet: open the app, type the Mac's IP in the ID field (`192.168.1.117` on LAN,
`100.68.94.32` over Tailscale; no port → uses 21118), the server's permanent password.
Pick codec **VP9** in the session bar if auto picks AV1.

## Building the CLIENT for iPad/iPhone (iOS) — August 2026

`tools/build-ios.sh [--deps] [--install [UDID]]`: vcpkg `arm64-ios` deps → static Rust lib
`target/aarch64-apple-ios/release/liblibrustdesk.a` (`--features flutter,hwcodec --lib`) → `flutter build ios --release`
in `client/` → installs and launches with `xcrun devicectl` (works with the device paired over Wi‑Fi, no USB needed).
Runner `client/ios/` = a copy of the engine's with bundle id `app.remotedisplay.client`, team `K45698KZ4W`
(Samuel Rioja, automatic signing), `liblibrustdesk.a` pointing at `engine/rustdesk/target`,
`bridge_generated.h` copied from the macOS runner (upstream's CI generates it for iOS), Info.plist with
`NSLocalNetworkUsageDescription` (iOS asks for local network permission on first use) and empty entitlements
(no `aps-environment`/`wifi-info`, which the client doesn't use and which require capabilities on the App ID).
Same Dart as Android (`_runMobile()` + `MobileSessionScreen`); the engine already carries the iOS
keyboard workarounds. No screenshots possible from the Mac (iOS 17+ requires a root tunnel for screenshots): verify
from the server side instead (`lsof -iTCP:21118`, `remotedisplayd` log).
**Empty "On your network" on iOS** (25-08-2026): UDP broadcast doesn't go out without `com.apple.developer.networking.multicast`
and the fork's port scan was compiled out on iOS. Fix in `lan.rs`: scanning enabled on iOS
(`getifaddrs`) + unicast discovery ping to every host (all platforms → the Mac shows up
identified without a prior connection). What's still missing on iOS is the Tailscale peer listing (no CLI available).

## Building the macOS HOST as `RustDesk.app` (normal, with permissions via assistant)

Instead of the headless binary (which requires granting permissions by hand = "black magic"), we
build the real app. When opened, RustDesk asks for Screen Recording + Accessibility
with the normal dialogs. Recipe (on the Mac):

1. Flutter 3.24.5 (`~/flutter`), CocoaPods, Xcode. `flutter config --enable-macos-desktop`.
2. Copy from the Windows build (or generate): `flutter/lib/generated_bridge.dart`,
   `flutter/lib/generated_bridge.freezed.dart`, `src/bridge_generated.rs`,
   and **the C header** `flutter/macos/Runner/bridge_generated.h`
   (`flutter_rust_bridge_codegen ... --c-output flutter/macos/Runner/bridge_generated.h`).
   Without the freezed file and the header, `flutter build macos` fails (empty bundle / input not found).
3. `cargo build --features flutter --lib --release` (llvm@17 env, same as the host) → `liblibrustdesk.dylib`.
4. `cd flutter && flutter build macos --release` → `build/macos/Build/Products/Release/RustDesk.app`.
5. Ad-hoc sign and remove quarantine: `codesign --force --deep --sign - RustDesk.app; xattr -dr com.apple.quarantine RustDesk.app`.
6. Package the DMG: `hdiutil create -volname Remote Display -srcfolder <folder with app+Applications symlink> -format UDZO RemoteDisplay-Install.dmg`.

Installation (user): open the DMG → drag to Applications → open → accept the
permissions → set a permanent password → Settings → enable "Direct IP Access" (port 21118).
The Windows client connects via direct IP (192.168.1.117 / Tailscale 100.68.94.32).

## Pending / roadmap

- **macOS client** (to control the Mac FROM another Mac). Today: host=Mac, client=Windows.
- Remove more features in the fork (file transfer, printer, etc. if they get in the way)
  and also remove chat from the Flutter UI (`flutter/lib/desktop`) — the engine already ignores it.
- Backup of the old self-hosted server's keys: `~/dev/backup-rustdesk-server-viejo.tgz` (Mac).
- The Mac was left 100% clean (Aug 2026): no binaries, no daemons, TCC permissions reset.

## Decision history

- Moonlight+Lumen: dropped by the user. The reported lag was AWDL (AirDrop) injecting
  100ms spikes on the Mac's Wi-Fi — without an Ethernet cable, `sudo ifconfig awdl0 down`
  fixes it (it re-enables on reboot). With an active stream the LAN gives 2ms.
- Old self-hosted server (hbbs/hbbr) on the Mac: removed — this fork doesn't use a server.

## Updating the engine from upstream

Moved to [`../engine/`](../engine/SYNC.md) — scripts + tracking of
syncs with upstream RustDesk.

## Releases (binaries for all platforms)

Binaries are NOT committed (60–100 MB each would blow up the repo): they go to **GitHub Releases**
of the private repo, one tag per version (`v<version from client/pubspec.yaml>`).

| Artifact | Built on | Script |
|---|---|---|
| `RemoteDisplay-Setup-<ver>.exe` (Inno Setup) + `RemoteDisplay-<ver>-windows-x64-portable.zip` | Windows PC | `release/release-windows.ps1 -Upload` |
| `RemoteDisplay-<ver>-android-arm64.apk` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-macos-client.dmg` and `RemoteDisplay-Server-<ver>-macos.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-ios.ipa` (development signature; install with `xcrun devicectl device install app`) | Mac | `release/release-mac.sh` |

Flow: on the Mac `release-mac.sh` leaves everything in `release/out/`; from the PC,
`release/release-fetch-mac.ps1` fetches them via scp and uploads them to the Release with `gh` (authenticated
on the PC; the Mac doesn't have gh). The portable zip runs from any folder without installing;
the config still lives in `%APPDATA%\RustDesk`.
