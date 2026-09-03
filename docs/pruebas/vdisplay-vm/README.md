# Pruebas en VMs Tart — displays virtuales macOS (2026-09-01)

Verificación de la feature de displays virtuales dinámicos (CGVirtualDisplay
in-process en el engine) hecha en 2 VMs Tart limpias con
`ghcr.io/cirruslabs/macos-tahoe-base` (macOS 26.6.2, SIP off).

## Qué se probó y resultado

1. **Harness nativo** (`harness/vdisplay_test.mm`, linkea el `macos.mm` real):
   crear/resize en caliente con displayID estable/destruir; main dinámico
   (virtual principal + físico espejado), resize con espejo activo, OFF
   limpio, 2 ciclos completos. **26/26 PASS** en el guest.
2. **Test de integración Rust** (`harness/rusttest/`): los wrappers
   `mac_vdisplay` exactos que invoca `Connection` (plug_in/out, ruteo del
   índice -2 del main dinámico, `change_resolution_if_is_virtual_display`,
   `reset_all`). **TODO OK** en el guest.
3. **Cliente↔server real**: engine headless en VM1 (TCC por sqlite, SIP off),
   app Flutter en VM2 conectada vía túnel SSH por el host (las VMs de Tart no
   se ven entre sí). Capturas en `capturas/`.

## Capturas (no incluidas en el repo público)

- `client1.png` primer intento: prompt de Red Local + fallo de conexión
  (aislamiento VM-VM de Tart, resuelto con túnel por el host).
- `c4.png` **conectado**: sesión "127.0.0.1" con el escritorio de VM1 detrás
  de los prompts.
- `c5.png`-`c7.png` cascada de prompts de permisos de macOS 26 al cliente;
  el escritorio remoto de VM1 transmitiendo en vivo.
- `c8.png` sesión limpia: escritorio de VM1 completo en la ventana del
  cliente, pill del toolbar visible.
- `c9.png`-`c11.png` navegación del toolbar (el click por píxel sobre el
  canvas Flutter resultó frágil; el tramo menú→backend se cubrió con el test
  Rust determinista).

## Hallazgos de runtime (macOS 26) que el código ya maneja

- Destruir un CGVirtualDisplay que fue master de espejo deja un display
  fantasma permanente → el virtual del main dinámico se cachea deshabilitado
  (`CGSConfigureDisplayEnabled`) y se recicla; muere con el proceso.
- `applySettings` no conmuta el modo si el display es main o master de espejo
  → commit-nudge condicional + escalada a `CGConfigureDisplayWithDisplayMode`.
- La repromoción del físico tras apagar el main dinámico debe ser explícita y
  esperada; encadenar configs de espejo sin asentar produce ciclos (pantalla
  en 0 displays activos).

## Re-ejecutar

En una VM Tart (o un Mac de prueba — crea/destruye displays de verdad):

```sh
# harness nativo
xcrun clang++ -std=c++17 -fobjc-exceptions harness/vdisplay_test.mm \
  ../../../engine/rustdesk/src/platform/macos.mm -o /tmp/vdisplay_test \
  -framework Foundation -framework CoreGraphics -framework AppKit \
  -framework AVFoundation -framework IOKit -framework Security -framework CoreMedia
codesign --force --sign - /tmp/vdisplay_test && /tmp/vdisplay_test

# test Rust (compila contra el macos.mm del engine)
cd harness/rusttest && cargo run --release
```

## Prueba end-to-end desde Windows (2026-09-02)

Cliente **Windows 11 ARM64 real** (QEMU/HVF, `RD-WIN11`, cuenta `user`) conectado
por el puente del host al server **macOS Tart limpio** (`remotedisplay-server`,
imagen `macos-tahoe-base` recién clonada, server commit b0f0e1c+). Todo clickeado
en la UI real por QMP (`click100.py`, en el rig de VMs, fuera del repo).

| Qué | Resultado |
|---|---|
| Conexión y menú MONITORS (físico/virtual, switch, basurero) | OK — `capturas/win11-conectado-server-tart.png`, `win11-monitors-virtual-basurero.png` |
| Abrir un monitor en otra ventana / cerrar esa ventana (" · open" + ✕) | OK — `win11-monitors-abrir-ventana.png`, `win11-monitors-ventana-abierta.png` |
| Borrar el virtual que se está viendo → vuelve al físico y el título se actualiza | OK |
| Fit to screen sobre el físico → main dinámico (virtual principal al tamaño de la ventana, físico espejado "off"); el switch lo deshace | OK — `win11-fit-fisico-main-dinamico.png` |
| Perfil por cliente: reinicio del server (0 virtuales) → al conectar el cliente recrea el virtual guardado (1284×701) | OK — `win11-perfil-aplicado-al-conectar.png` |
| Reinicio del server con la sesión abierta → reconexión automática → perfil re-aplicado | OK — `win11-perfil-reaplicado-reconexion.png` |
| Escala por virtual (tap en la dimensión → popup 100/125/150/200 %) | OK — `win11-escala-popup.png` |
| Fit @200 % → 642×351 pts · 150 % → 856×468 · 100 % → 1284×702 (exactos, `dispinfo` en el server) | OK — `win11-escala-100.png` |
| 200 % con 2×puntos ≥ 1920 → Retina real (1284×702 pts / 2568×1404 px) | OK — `win11-escala-200-retina.png` |
| 200 % sobre el main dinámico en ventana de 1284 px → fallback 1x 642×351 (UI al doble, sin Retina); 100 % → 1284×702 | OK — `win11-escala-200-zoom-main-dinamico.png`, `win11-escala-final-menu.png` |
| Perfil completo tras reinicio del server: main dinámico 1284×702 + virtual 1284×702 + físico off, espejo reparado tras el resize | OK — `win11-perfil-completo-main-dinamico.png` |
| Perfil guardado con escala (v2): `{"virtuals":[{1284,702,100}],"dynamicMain":true,"dynamicMainSpec":{1284,702,100}}` | OK |
| "Create virtual monitor" nace al tamaño de la ventana | OK — 1284×701 con la ventana por defecto |
| **100 ciclos crear → borrar** (939 s) | OK — `stress-100-ciclos.log` |
| Perfiles `.icc` en `/Library/ColorSync/Profiles/Displays` | **2 constantes** (Apple Virtual + 1 de Remote Display reusado por el serial estable). 0 acumulación |
| CPU de `colorsyncd`/`displayservices` | **0 %** en las 12 mediciones |
| RSS del proceso server | 385 MB → 512 MB en el ciclo 1 (buffers del encoder) → 552 MB al final: deriva leve con altibajos (538→521), no concluyente como fuga |
| Estado final | solo Monitor 1 — sin virtuales residuales (`win11-stress-final-menu.png`) |

Comparación: con el serial aleatorio (antes de b0f0e1c) 100 ciclos dejaban ~56
`.icc` y `colorsyncd` al 100 % sostenido.

## Semántica de monitores (acordada 2026-09-02)

- **Fit to screen** es el único trigger de resolución dinámica. Sobre un
  **virtual**: toma el tamaño de la ventana. Sobre un **físico** (peer macOS):
  activa el *main dinámico* — el físico queda espejado sobre un virtual principal
  que sí sigue a la ventana. Se deshace con el switch del físico apagado o con el
  basurero del virtual dinámico (el engine nunca destruye ese virtual: en macOS
  26 dejaría un display fantasma; lo oculta y lo recicla).
- **Persistencia = perfil POR CLIENTE, por peer**, guardado en el cliente
  (`client/lib/session/monitor_profile.dart`, opción de peer
  `mac_monitor_profile`): virtuales con tamaño, main dinámico y su tamaño. Se
  toma del estado real del server ~2.5 s después de cada acción de la toolbar.
  Al conectar y en cada reconexión (`FfiModel.peerInfoEpoch`), la ventana
  principal reconcilia el server: borra sobrantes, crea faltantes, ajusta
  tamaños. Otro cliente (PC vs iPad) aplica el suyo → override.
- **El server headless corre un NSApplication (Prohibited) en el hilo principal**, no
  un `CFRunLoopRun()` pelado: CoreGraphics entrega las notificaciones de
  reconfiguración de displays por el event loop de AppKit; sin bombearlas, tras la
  transacción de espejo del main dinámico el proceso dejaba de ver los displays
  creados después (`harness/mirror_enum_test2.mm`).
- **macOS 26 disuelve el espejo del main dinámico al cambiar el modo de cualquier
  otro display** (`harness/mirror_stability_test.mm`): tras un resize de otro
  virtual el engine re-espeja solo; si el espejo se rompe por fuera y no se puede
  reparar, apaga el main dinámico (físico vuelve a principal, virtual oculto).
- El server macOS **no destruye** virtuales al cerrar la última conexión (solo
  Windows/IDD hace `reset_all`); reconectar desde el mismo cliente no toca nada.
- **Escala por monitor virtual** (tap en su dimensión → 100/125/150/200 %). El
  framebuffer sigue a los píxeles FÍSICOS de la ventana del viewer (canvas ×
  devicePixelRatio) y los puntos = píxeles/escala. **Retina real (backing 2x)
  solo cuando 2×puntos > 1920 px** (limitación medida de CGVirtualDisplay en
  macOS 26, ver `harness/hidpi_test2..5.mm`): por debajo el display queda a 1x
  con menos puntos (UI más grande, algo más suave), que es lo confiable. Si el
  modo Retina no asienta (p.ej. el virtual del main dinámico, que es principal y
  master de espejo), el engine cae solo a 1x con los mismos puntos: la escala
  elegida siempre se respeta.
  Default para virtuales nuevos y main dinámico: la escala del cliente (snap del
  DPR). Protocolo: `ToggleVirtualDisplay` con índice ≥ 1 000 000 + id = HiDPI
  on/off; platform addition `mac_hidpi_displays`. El perfil por cliente guarda la
  escala (v2).
- Nombres `Monitor 1..N` por posición; ⧉ abre un monitor en otra ventana y ✕ la
  cierra; el tap en la fila siempre cambia la vista de esta ventana (o trae al
  frente la ventana que ya lo muestra).

## Rig de VMs (Windows QEMU + Mac Tart)

El banco de pruebas completo (cómo levantar el cliente Windows en QEMU, el
server macOS en Tart, el puente de red, y los **snapshots dorados** para no
reinstalar) vive fuera del repo (banco de VMs local, no publicado).

Incluye los gotchas que costaron horas (ramfb vs virtio-gpu para instalar
Windows ARM, boot del instalador por UEFI shell, aislamiento de red de Tart).

## Nota 2026-09-03 — bandera HiDPI (pedido vs real)

- El server distingue `hidpiRequested` (lo que pidió el cliente; es lo que
  publica `mac_hidpi_displays` y lo que usa la etiqueta de escala) de `hidpi`
  (backing real, medido al final del resize con
  `CGDisplayModeGetPixelWidth == 2 × puntos`, espera de 5 s). El toggle
  HiDPI solo declara el modo; el resize que sigue lo aplica y verifica.
- Un toggle con los mismos puntos no cambia los bounds (960×505 en 1× y 2×):
  la espera es por píxeles y puntos, no por bounds.
- En esta VM el Retina real no se activa a 960 pt (= 1920 px, justo en el
  umbral): el display queda a 1× con los mismos puntos (UI al doble). Sí
  se activó a 1284 pt / 2568 px (tabla de evidencia más arriba). El log del
  engine (`rustdesk.log`, línea `resize … (hidpi=N)`) muestra el backing real.
