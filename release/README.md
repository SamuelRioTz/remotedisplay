# release/ — binarios de Remote Display

> **Versión actual: 0.3.0**  (fuente de verdad: `version:` en `client/pubspec.yaml`; se
> refleja acá, en el README principal y en el tag `v<version>`).
>
> **Bump de versión**: solo cuando se pide explícitamente. Al pedirlo se cambia el número
> en `client/pubspec.yaml` (`version: X.Y.Z+N`), en el README principal y en esta línea, y
> el próximo release usa el tag nuevo. Si no se pide, se reusa la versión actual (se
> re-suben/actualizan los artefactos al Release existente con `--clobber`).

Los binarios van a **GitHub Releases** del repo (privado), tag `v<version>`. Nada de
binarios en git (`release/out/` está en .gitignore).

## Artefactos y cómo se producen

| Artefacto | Se construye en | Comando |
|---|---|---|
| `RemoteDisplay-Setup-<ver>.exe` (Inno) + `RemoteDisplay-<ver>-windows-x64-portable.zip` | PC Windows | `release/release-windows.ps1 -Upload` |
| `RemoteDisplay-<ver>-android-arm64.apk` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-macos-client.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-Server-<ver>-macos.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-ios.ipa` | Mac | `release/release-mac.sh` |

## Flujo completo de un release

1. Subir `version:` en `client/pubspec.yaml` y en el README principal, commit+push.
2. **PC Windows**: `powershell -ExecutionPolicy Bypass -File release/release-windows.ps1 -Upload`
   (compila, valida, crea el Release `v<ver>` y sube zip+instalador).
   Requiere la DLL del motor al día (`engine/rustdesk/target/release/librustdesk.dll`,
   receta en `tools/README.md`).
3. **Mac** (lo corre el Claude del Mac o Sam; codesign necesita la sesión gráfica):
   `git pull && bash release/release-mac.sh [--upload]` → compila los 4 artefactos en
   `release/out/`; con `--upload` además los sube al Release `v<ver>` (lo crea si no existe).
   El Mac YA tiene `gh` autenticado (`SamuelRioTz`), así que sube directo — el paso 4 (fetch
   desde Windows) es solo alternativa si el Mac no tuviera `gh`.
   Si el llavero pide acceso a la llave "Apple Development", elegir **Permitir siempre**.
   - `ENGINE_BIN` del server: default `engine/rustdesk/target/release/rustdesk` (el binario
     del motor del monorepo, ya con los parches serverless). Pasar otra ruta si se quiere.
4. **PC Windows** (alternativa, si el Mac no tiene `gh`): `release/release-fetch-mac.ps1` —
   trae los artefactos del Mac por scp y los sube al mismo Release.

## Instalar el IPA en el iPad/iPhone

El `.ipa` va firmado con el certificado de desarrollo (equipo K45698KZ4W) — los
dispositivos de Sam ya están en el perfil. Desde el Mac, con el dispositivo conectado
y desbloqueado:

```sh
xcrun devicectl list devices            # UDID
xcrun devicectl device install app --device <UDID> RemoteDisplay-<ver>-ios.ipa
```

(También: arrastrarlo al dispositivo en Finder, o Apple Configurator.)
La firma de desarrollo expira: reinstalar cuando el perfil venza.

## Notas

- El ZIP portable de Windows corre desde cualquier carpeta sin instalar; la config
  vive en `%APPDATA%\RustDesk` (rezago de marca pendiente de renombrar).
- Instalador validado con install/uninstall silencioso (`/VERYSILENT`).
- `gh` debe apuntar a ESTE repo: el repo es fork de rustdesk/rustdesk y `gh` sin
  configurar resuelve al padre. Ya está fijado con `gh repo set-default
  SamuelRioTz/remotedisplay` (si se reclona, volver a correrlo).
