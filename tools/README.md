# remotedisplay — mi fork de RustDesk (serverless, solo LAN)

Fork propio de **RustDesk 1.4.9**. **El fork vive en [`../engine/rustdesk`](../engine/rustdesk)** (código
Rust en `engine/rustdesk/src` y `engine/rustdesk/libs`, UI Flutter en `engine/rustdesk/flutter`); esta carpeta
`remotedisplay/` guarda las herramientas de despliegue. Rama de trabajo: `remotedisplay`.
Los comandos de build de este README se corren desde `engine/rustdesk/` (antes eran la raíz del repo).
El server macOS nativo vive en [`../server-mac`](../server-mac).

## Qué tiene el fork (rama `remotedisplay`, commits propios)

| Cambio | Dónde | Qué hace |
|--------|-------|----------|
| Serverless | `libs/hbb_common/src/config.rs` | rendezvous → `127.0.0.1`, llave pública del server oficial vaciada: **jamás** habla con servidores externos |
| Sin update-check | `src/common.rs` | `check_software_update()` retorna de una |
| CM headless | `src/core_main.rs` + `src/server/connection.rs` | connection manager sin UI (el build sin flutter no tiene Sciter; antes crasheaba en cada conexión) |
| Sin chat | `src/server/connection.rs` | el host ignora mensajes de chat |
| Server escucha descubrimiento LAN en serverless | `src/rendezvous_mediator.rs` | upstream solo arranca `lan::start_listening()` si `platform::is_installed()` (= `/Applications/RustDesk.app`); nuestro `remotedisplayd` headless no lo es → el server nunca respondía pings y los clientes lo veían como IP pelada hasta la 1ª conexión. Ahora también si `is_serverless_lan()`. Patch: `patches/04-lan-discovery-serverless.patch` (incluye lan.rs) |
| Serverless silencioso + `--check-perms` | `src/common.rs`, `src/server.rs`, `src/hbbs_http/sync.rs`, `src/core_main.rs` | en serverless: sin test NAT contra 127.0.0.1:21116, sin 30 reintentos de config-sync con el `ipc_service` root (ni los 3 s de espera al arrancar), sin heartbeat/sysinfo a 21114 (el `SENDER` lazy lo arrancaba `signal_receiver()` en cada conexión, saltando el gate de `start()`), sin auditoría remota. `remotedisplayd --check-perms` imprime `{"accessibility":..,"screen":..}` desde un proceso fresco (TCC cachea Screen Recording por proceso). Patch: `patches/05-serverless-quiet-and-check-perms.patch` |
| Auto-códec VP9 en LAN | `libs/scrap/src/common/codec.rs`, `libs/hbb_common/src/config.rs` | `Config::is_serverless_lan()` compartido; con preferencia *Auto* el server elige VP9 en serverless (AV1 solo explícito). Patch: `patches/06-lan-auto-codec-vp9.patch` |
| Descubrimiento sin broadcast | `src/lan.rs` | además del broadcast UDP: ping de descubrimiento **unicast** a cada host de las subredes locales (+ peers Tailscale) y escaneo TCP del puerto directo; en iOS (sin entitlement de multicast el broadcast no sale) las interfaces se leen con `getifaddrs` (`default_net` no está) y no hay CLI de Tailscale |
| `showToolbar` / `keyHelpHorizontal` en la RemotePage MÓVIL | `flutter/lib/mobile/pages/remote_page.dart` | como el flag de la desktop: oculta barra/FAB/ayuda de gestos; `MobileRemotePageController` (abrir/ocultar teclado + `isKeyboardShown`, estado real también con teclado físico); `KeyHelpTools(horizontal:)` = teclas auxiliares en UNA fila con scroll horizontal en vez de 3 filas. Lo usa `client/` en Android/iOS para poner SU toolbar. Patch: `patches/03-flutter-mobile-remote-page-show-toolbar.patch` |
| Teclado vivo tras background/reconexión (móvil) | `flutter/lib/mobile/pages/remote_page.dart` | los diálogos de reconexión roban el foco con un `FocusScopeNode` propio y nadie lo devuelve (no son rutas), y el SO invalida la conexión IME al ir a background → teclado virtual Y físico muertos hasta cerrar sesión. Fix: `_restoreKeyboardFocus()` en `resumed` y en el callback de primer frame (que se re-dispara en cada reconexión; ya no llama `_disableAndroidSoftKeyboard` con `_showEdit` activo, que dejaba `FLAG_ALT_FOCUSABLE_IM` bloqueando el IME), y `onPointerDown` en el canvas repara el foco como en desktop. Patch: `patches/07-mobile-keyboard-focus-restore.patch` |

Los diffs también están sueltos en [`patches/`](patches/) por si se re-aplican sobre otra versión.

## Desplegar el host en el Mac (cuando quieras)

```bash
# 1. Copiar el fork al Mac (desde la raíz del repo en esta PC).
#    Incluye remotedisplay/ (trae install-host.sh); excluye .git y target:
rsync -a --exclude=.git --exclude=target \
  ./ <user>@<mac>:~/dev/remotedisplay/

# 2. En el Mac — compilar (toolchain ya instalado: rust, vcpkg, llvm@17, nasm, ninja):
cd ~/dev/rustdesk
export VCPKG_ROOT=$HOME/vcpkg SDKROOT=$(xcrun --show-sdk-path)
export LIBCLANG_PATH=/opt/homebrew/opt/llvm@17/lib
export BINDGEN_EXTRA_CLANG_ARGS="-isysroot $SDKROOT"
$VCPKG_ROOT/vcpkg install --x-install-root=$VCPKG_ROOT/installed   # solo la primera vez
cargo build --release

# 3. FIRMAR con certificado estable ANTES de dar permisos (ver abajo) e instalar:
bash ~/dev/rustdesk/remotedisplay/mac/install-host.sh <password>
```

### La trampa de los permisos (TCC) — lección aprendida

macOS identifica binarios sin firma por **cdhash** (huella del build exacto): cada
recompilación invalida los permisos de Grabación de Pantalla/Accesibilidad ya concedidos
(el toggle queda "activado" pero apunta al binario viejo → `Failed to create capturer`).

**Fix**: crear una vez un certificado self-signed de firma de código en el Mac
(Keychain Access → Certificate Assistant → Create a Certificate → tipo "Code Signing",
nombre `RemoteDisplaySign`) y firmar cada build antes de instalar:

```bash
codesign --force --sign RemoteDisplaySign --identifier app.remotedisplay.engine \
  ~/.local/share/remotedisplay/rustdesk
```

Con identidad estable, los permisos se conceden **una sola vez** y sobreviven rebuilds.
Los permisos son 2, físicamente en el Mac: Grabación de pantalla y Accesibilidad.

## Códec por defecto: VP9 (server)

El auto-códec upstream elige AV1 si el cliente lo soporta; en LAN no aporta y su decode a
1080p/4K cuelga clientes modestos (VM de 4 vCPU: "Connecting…" eterno / pantalla negra). Parche 06
(`libs/scrap/src/common/codec.rs` + `Config::is_serverless_lan()` en hbb_common): en modo
serverless con preferencia *Auto* el motor usa **VP9**; el cliente puede seguir eligiendo AV1
explícitamente desde Display → Codec. OJO: `av1-test` en RemoteDisplay2.toml NO es una preferencia
(es la sonda de capacidad AV1, el motor la reescribe a `'Y'`).

## Config LAN-only (doble candado además del parche)

`mac/RemoteDisplay2.toml` y `windows/RemoteDisplay2.toml`: rendezvous/relay/api a `127.0.0.1`,
`direct-server=Y` (puerto 21118), update-check apagado. Conexión: IP directa
(`192.168.1.117` en LAN, `100.68.94.32` por Tailscale — ambas rutas ya probadas).

## Compilar el CLIENTE Windows (receta probada — agosto 2026)

Prerequisitos: VS Build Tools 2022 (C++), Rust, vcpkg. **Trampas resueltas:**

1. **Toolchain Rust = MSVC** (no gnullvm): `rustup override set stable-x86_64-pc-windows-msvc`
   en la raíz del repo. El default de esta PC es gnullvm y rompe el link con vcpkg.
2. **vcpkg deps** (triplet `x64-windows-static`, baseline `120deac`), modo clásico sin ffmpeg:
   ```
   vcpkg install opus:x64-windows-static libvpx:x64-windows-static libyuv:x64-windows-static aom:x64-windows-static libjpeg-turbo:x64-windows-static
   ```
3. **bindgen necesita LLVM 18** (no el 22): `LIBCLANG_PATH=C:\Users\sam\llvm-18.1.8\bin`
   y `BINDGEN_EXTRA_CLANG_ARGS=--target=x86_64-pc-windows-msvc`, y **sacar llvm-mingw del PATH**
   (contamina con headers MinGW). Con clang 22 los structs de aom/vpx salen opacos.
4. **Puente FFI**: `cargo install flutter_rust_bridge_codegen --version 1.80.1`, luego
   `flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --llvm-path "C:\Program Files\LLVM"`
   (ffigen necesita libclang; instalar LLVM.LLVM).
5. **DLL**: `VCPKG_ROOT=C:\Users\sam\vcpkg cargo build --locked --features flutter --lib --release` → `target/release/librustdesk.dll`
6. **Flutter 3.24.5** (NO el 3.44/stable del sistema — rompe por DialogTheme/extended_text):
   ahora via fvm: `C:\Users\sam\fvm\versions\3.24.5\bin` primero en PATH (la carpeta vieja
   `C:\Users\sam\flutter-3.24.5` quedó vacía), `flutter build windows --release`. Si el build
   falla con "CMakeCache.txt directory ... is different", borrar `flutter\build\windows`
   (cache de un path de checkout viejo).
7. **Ensamblar**: copiar `target/release/librustdesk.dll` a
   `flutter/build/windows/x64/runner/Release/` (junto a `rustdesk.exe`).

El .exe final: `flutter/build/windows/x64/runner/Release/rustdesk.exe` + config LAN-only en `%APPDATA%\RustDesk\config\RemoteDisplay2.toml`.

## Compilar para Android (tablet/teléfono → Mac) — receta probada agosto 2026

Dos APKs arm64 posibles, ambos con la misma lib Rust serverless (`config.rs` → 127.0.0.1, solo IP directa)
y que conviven instalados. Todo se compila **en el Mac**:
- **Nuestro client** (`client/`, default): `tools/build-android.sh [--install SERIAL]` →
  `tools/out/remotedisplay-client-android-arm64.apk`, `applicationId app.remotedisplay.client`, label
  "Remote Display". Home propia (tarjetas 1 por máquina con badge **guardado** = contraseña recordada, un toque conecta;
  pulsación larga = olvidar equipo; conexión manual) y sesión propia `MobileSessionScreen`: la
  `RemotePage` **móvil** del engine (gestos táctiles, teclado virtual, render) con `showToolbar: false`
  (parche 03) + nuestra `SessionToolbar`. Pill (desktop y móvil): `‹ · peer · [minimizar] · pantalla completa ·
  ajustar a pantalla · Entrada · Pantalla · ✕`. **Entrada** = cómo interactúo: modo Táctil/Cursor y Solo ver (móvil), Teclado virtual y
  **Barra de teclas** (toggles independientes, la barra vía `setKeyHelpOverride` del controller), opciones de
  cursor/teclas (`toolbarCursor`, `toolbarKeyboardToggles`) y de sesión (audio, portapapeles, bloqueo, privacidad).
  **Pantalla** = qué veo: monitores, Vista, Calidad,
  Códec e Imagen (true color, monitor de calidad, multi-monitor; se filtran de `toolbarDisplayToggle` por label).
  Ajustar a pantalla (botón directo) = estilo adaptive + `canvasModel.reset()`. Persistencia: códec/calidad/vista y
  toggles de cursor/sesión los guarda el engine por peer; modo táctil en `kOptionTouchMode` (local, el engine lo lee
  al abrir); barra de teclas y pantalla completa en opciones locales propias (`remotedisplay-key-help-bar`,
  `remotedisplay-mobile-fullscreen`); el teclado virtual no se persiste. La barra de teclas SOLO obedece a su toggle. Puntero local (trackpad iPad / mouse Android) oculto sobre el canvas
  remoto: en Android vía `MouseRegion(cursor: none)`; en iOS Flutter NO implementa cursores (el engine ya pone
  `SystemMouseCursors.none` y no hace nada) → el Runner (`client/ios/Runner/AppDelegate.swift`) usa
  `UIPointerInteraction` con estilo `hidden`, y Dart le manda por el canal `remotedisplay/pointer` el rect de la pill
  y si hay menú abierto (ahí el puntero se ve). Toggle persistente `remotedisplay-hide-local-pointer`.
  Idioma: toda la UI del client en inglés y el engine forzado a `lang=en` (`mainSetLocalOption`) al arrancar.
  Desconectar (✕) en móvil cierra sin confirmación (`closeConnection()`; el dispose de la RemotePage cierra la sesión). Pantalla completa en móvil = barra de estado/navegación del sistema; con teclado físico (iPad) el engine no la
  restaura al abrir el teclado (`showToolbar:false` + iOS). El runner `client/android/` es copia del del engine con
  `applicationId`, label y rutas (`cargo metadata` y protos → `engine/rustdesk`) adaptados; `main.dart`
  tiene rama `_runMobile()` (sin window_manager/multi_window) y `home.dart` guarda con `isDesktop`.
- **Engine** (`--engine`): el `flutter_hbb` upstream (UI móvil de RustDesk, `com.carriez.flutter_hbb`)
  → `tools/out/remotedisplay-engine-android-arm64.apk`. Sirve para aislar bugs del client.

Pasos que hace el script (por si hay que correrlos a mano):
1. `vcpkg install --triplet arm64-android --x-install-root=~/vcpkg/installed-android` con `ANDROID_NDK_HOME=<sdk>/ndk/28.2.13676358`
   (+ symlink `installed/arm64-android`) → aom, ffmpeg mediacodec, libvpx, libyuv, opus, oboe, libjpeg, cpu-features. ~5 min.
2. `cargo ndk --platform 21 --target aarch64-linux-android build --locked --release --features flutter,hwcodec`
   → `target/aarch64-linux-android/release/liblibrustdesk.so`.
3. Copiar la .so como `flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so` + `libc++_shared.so` del NDK
   (`toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/`).
4. `flutter build apk --release --target-platform android-arm64 --split-per-abi` en `engine/rustdesk/flutter`.

**Trampas resueltas:**
- Gradle 7.6.4 (el del engine) **no corre con el JDK 21** que trae Android Studio → `brew install openjdk@17`
  y `flutter config --jdk-dir /opt/homebrew/opt/openjdk@17`.
- `build_android_deps.sh` no es ejecutable en el checkout: correrlo con `bash`.
- El `build.gradle` firma release con `signingConfigs.release` leyendo `android/key.properties` (gitignored,
  hace falta en `engine/rustdesk/flutter/android/` Y en `client/android/`); sin ese archivo el build release falla. Keystore propio y estable: `~/.remotedisplay/android-release.jks`
  (alias `remotedisplay`, pass `changeit`), así `adb install -r` actualiza sin desinstalar.
- `~/.gradle/gradle.properties` con `org.gradle.jvmargs=-Xmx4g` (el del repo trae 1 GB, poco para R8).
- **libsodium sin resolver**: `libsodium-sys` corre `./configure` solo con `CC`/`CFLAGS` y usa el `ar`/`ranlib`
  de macOS sobre objetos ELF (warnings "not a mach-o file"); el `libsodium.a` queda sin índice, los binarios no
  enlazan y la `.so` sale con `sodium_*` **undefined** (no carga en el dispositivo). Fix: exportar
  `AR`/`RANLIB` = `llvm-ar`/`llvm-ranlib` del NDK (lo hace el script) y, si ya estaba compilado mal,
  `cargo clean -p libsodium-sys --release --target aarch64-linux-android`. Verificar con
  `llvm-nm -D --undefined-only liblibrustdesk.so | grep sodium` (debe estar vacío).
- Compilar con `--lib`: los binarios (`rustdesk`, `naming`, `service`) no se usan en Android.
- **client/: `flutter_plugin_android_lifecycle` pineado a 2.0.17** (dependency_overrides, igual que el engine):
  la 2.0.26 compila contra android-35 y el aapt2 de AGP 7.3.1 falla con "RES_TABLE_TYPE_TYPE entry offsets
  overlap" al leer ese `android.jar`. Si aparece ese error, buscar qué plugin subió de versión respecto
  al lock del engine.
- **vcpkg borra los paquetes de OTRO triplet**: en modo manifest, `vcpkg install --triplet arm64-ios
  --x-install-root=installed` eliminó todo `arm64-android` del mismo root (y viceversa) → "could not find native
  static library `vpx`". Un install-root por plataforma (`~/vcpkg/installed-android`, `~/vcpkg/installed-ios`;
  `installed/` queda para macOS) + symlinks `installed/arm64-android` y `installed/arm64-ios` hacia ellos, que es
  donde buscan los build.rs. Lo hacen `build-android.sh`/`build-ios.sh`. NO usar `flutter/build_android_deps.sh`
  del engine (instala en `installed/`).
- **iOS: `___chkstk_darwin` undefined al enlazar la lib Rust**: cc-rs compila los objetos C (aom en `scrap`) para el
  iOS del SDK (26.x) y rustc enlaza con mínimo 10.0. Exportar `IPHONEOS_DEPLOYMENT_TARGET=14.0` antes de `cargo build`
  (y el mismo valor en `client/ios` Runner/Podfile); si ya se compiló mal, `rm -rf target/aarch64-apple-ios`.
- **client/android/app/build.gradle**: el `workingDir` de `cargo metadata` se resuelve contra `client/android`
  → usar `rootProject.file("../../engine/rustdesk")`; los protos (`sourceSets`) se resuelven contra `app/`
  → `../../../engine/rustdesk/libs/hbb_common/protos`.
- No hace falta el parche `flutter_3.24.4_dropdown_menu_enableFilter.diff` del CI para compilar.

Uso en la tablet: abrir la app, en el campo ID escribir la IP del Mac (`192.168.1.117` en LAN,
`100.68.94.32` por Tailscale; sin puerto → usa 21118), contraseña permanente del server.
Elegir códec **VP9** en la barra de sesión si el auto elige AV1.

## Compilar el CLIENTE para iPad/iPhone (iOS) — agosto 2026

`tools/build-ios.sh [--deps] [--install [UDID]]`: deps vcpkg `arm64-ios` → lib Rust estática
`target/aarch64-apple-ios/release/liblibrustdesk.a` (`--features flutter,hwcodec --lib`) → `flutter build ios --release`
en `client/` → instala y lanza con `xcrun devicectl` (funciona con el dispositivo emparejado por Wi‑Fi, sin USB).
Runner `client/ios/` = copia del del engine con bundle id `app.remotedisplay.client`, equipo `K45698KZ4W`
(Samuel Rioja, firma automática), `liblibrustdesk.a` apuntando a `engine/rustdesk/target`,
`bridge_generated.h` copiado del runner macOS (en iOS upstream lo genera el CI), Info.plist con
`NSLocalNetworkUsageDescription` (iOS pide permiso de red local al primer uso) y entitlements vacíos
(sin `aps-environment`/`wifi-info`, que el cliente no usa y exigen capabilities en el App ID).
Mismo Dart que Android (`_runMobile()` + `MobileSessionScreen`); el engine ya trae los workarounds de
teclado iOS. Sin capturas posibles desde el Mac (iOS 17+ requiere túnel root para screenshots): verificar
del lado del server (`lsof -iTCP:21118`, log de `remotedisplayd`).
**"En tu red" vacío en iOS** (25-08-2026): el broadcast UDP no sale sin `com.apple.developer.networking.multicast`
y el escaneo de puertos del fork estaba compilado fuera en iOS. Fix en `lan.rs`: escaneo habilitado en iOS
(`getifaddrs`) + ping de descubrimiento unicast a cada host (todas las plataformas → el Mac aparece
identificado sin conexión previa). Lo que sigue sin existir en iOS es el listado de peers Tailscale (no hay CLI).

## Compilar el HOST macOS como `RustDesk.app` (normal, con permisos por asistente)

En vez del binario headless (que exige agregar permisos a mano = "magia negra"), se
construye la app real. Al abrirla, RustDesk pide Grabación de Pantalla + Accesibilidad
con los diálogos normales. Receta (en el Mac):

1. Flutter 3.24.5 (`~/flutter`), CocoaPods, Xcode. `flutter config --enable-macos-desktop`.
2. Copiar del build Windows (o generar): `flutter/lib/generated_bridge.dart`,
   `flutter/lib/generated_bridge.freezed.dart`, `src/bridge_generated.rs`,
   y **el header C** `flutter/macos/Runner/bridge_generated.h`
   (`flutter_rust_bridge_codegen ... --c-output flutter/macos/Runner/bridge_generated.h`).
   Sin el freezed y sin el header, `flutter build macos` falla (bundle vacío / input no encontrado).
3. `cargo build --features flutter --lib --release` (env llvm@17 como el host) → `liblibrustdesk.dylib`.
4. `cd flutter && flutter build macos --release` → `build/macos/Build/Products/Release/RustDesk.app`.
5. Firmar ad-hoc y quitar quarantine: `codesign --force --deep --sign - RustDesk.app; xattr -dr com.apple.quarantine RustDesk.app`.
6. Empacar DMG: `hdiutil create -volname Remote Display -srcfolder <carpeta con app+symlink Applications> -format UDZO RemoteDisplay-Install.dmg`.

Instalación (usuario): abrir el DMG → arrastrar a Aplicaciones → abrir → aceptar los
permisos → poner contraseña permanente → Ajustes → activar "Direct IP Access" (puerto 21118).
El cliente Windows conecta por IP directa (192.168.1.117 / Tailscale 100.68.94.32).

## Pendiente / roadmap

- **Cliente macOS** (si quieres controlar el Mac DESDE otra Mac). Hoy: host=Mac, cliente=Windows.
- Quitar más features en el fork (transferencia de archivos, impresora, etc. si estorban)
  y quitar el chat también de la UI Flutter (`flutter/lib/desktop`) — el motor ya lo ignora.
- Backup de las llaves del server viejo auto-hosteado: `~/dev/backup-rustdesk-server-viejo.tgz` (Mac).
- El Mac quedó 100% limpio (ago 2026): sin binarios, sin daemons, permisos TCC reseteados.

## Historial de decisiones

- Moonlight+Lumen: descartado por el usuario. El lag reportado era AWDL (AirDrop) metiendo
  picos de 100ms en el Wi-Fi del Mac — sin cable Ethernet, `sudo ifconfig awdl0 down` lo
  arregla (se re-activa al reiniciar). Con stream activo la LAN da 2ms.
- Servidor auto-hosteado viejo (hbbs/hbbr) del Mac: eliminado — este fork no usa servidor.

## Actualizar el motor desde upstream

Movido a [`../engine/`](../engine/SYNC.md) — scripts + tracking de
sincronizaciones con upstream RustDesk.

## Releases (binarios de todas las plataformas)

Los binarios NO se commitean (60–100 MB cada uno reventarían el repo): van a **GitHub Releases**
del repo privado, una etiqueta por versión (`v<version de client/pubspec.yaml>`).

| Artefacto | Dónde se construye | Script |
|---|---|---|
| `RemoteDisplay-Setup-<ver>.exe` (Inno Setup) + `RemoteDisplay-<ver>-windows-x64-portable.zip` | PC Windows | `release/release-windows.ps1 -Upload` |
| `RemoteDisplay-<ver>-android-arm64.apk` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-macos-client.dmg` y `RemoteDisplay-Server-<ver>-macos.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-ios.ipa` (firma development; instalar con `xcrun devicectl device install app`) | Mac | `release/release-mac.sh` |

Flujo: en el Mac `release-mac.sh` deja todo en `release/out/`; desde la PC,
`release/release-fetch-mac.ps1` los trae por scp y los sube al Release con `gh` (autenticado
en la PC; el Mac no tiene gh). El zip portable corre desde cualquier carpeta sin instalar;
la config sigue viviendo en `%APPDATA%\RustDesk`.
