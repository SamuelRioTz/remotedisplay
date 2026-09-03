#!/bin/bash
# Instala el host Remote Display headless en el Mac (correr EN el Mac).
# Uso: bash install-host.sh <password-permanente>
#
# Alternativa headless (sin barra de menú) a "Remote Display Server.app" de server-mac/.
# Las dos comparten puerto 21118 y socket IPC, así que son MUTUAMENTE EXCLUYENTES:
# este script hace bootout de la app antes de arrancar para evitar el doble-bind.
set -e

PASS="${1:?Uso: install-host.sh <password>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
# Binario del motor. Override con ENGINE_BIN=<ruta>. Por defecto prueba el build del
# repo (engine/rustdesk) y, si no, el checkout espejo legacy.
INSTALL_DIR="$HOME/.local/share/remotedisplay"
CONF_DIR="$HOME/Library/Preferences/RemoteDisplay"
UID_NUM="$(id -u)"

if [ -n "${ENGINE_BIN:-}" ]; then
    BIN_SRC="$ENGINE_BIN"
elif [ -x "$DIR/../../engine/rustdesk/target/release/rustdesk" ]; then
    BIN_SRC="$DIR/../../engine/rustdesk/target/release/rustdesk"
else
    BIN_SRC="$HOME/dev/rustdesk/target/release/rustdesk"
fi
test -x "$BIN_SRC" || { echo "ERROR: no existe el binario del motor: $BIN_SRC (¿compiló? usa ENGINE_BIN=<ruta>)"; exit 1; }

mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$HOME/Library/LaunchAgents"
cp -f "$BIN_SRC" "$INSTALL_DIR/rustdesk"

# Firmar con identidad estable si existe (permisos TCC sobreviven rebuilds).
# Crear una vez con Keychain Access: certificado "Code Signing" llamado RemoteDisplaySign.
if security find-identity -v -p codesigning 2>/dev/null | grep -q RemoteDisplaySign; then
    codesign --force --sign RemoteDisplaySign --identifier app.remotedisplay.engine "$INSTALL_DIR/rustdesk"
    echo "Binario firmado con RemoteDisplaySign"
else
    echo "AVISO: sin certificado RemoteDisplaySign — el permiso TCC se invalida en cada rebuild (ver README)"
fi

# Config bloqueada a LAN (antes del primer arranque)
cp -f "$DIR/RemoteDisplay2.toml" "$CONF_DIR/RemoteDisplay2.toml"

# Evitar conflicto con "Remote Display Server.app" (mismo puerto/socket IPC).
launchctl bootout "gui/$UID_NUM/app.remotedisplay.server" 2>/dev/null || true

# LaunchAgent: arranca con la sesión
# El plist es una plantilla: rutas absolutas del usuario real (portable).
sed -e "s#__INSTALL_DIR__#$INSTALL_DIR#g" -e "s#__HOME__#$HOME#g" "$DIR/app.remotedisplay.engine.plist" > "$HOME/Library/LaunchAgents/app.remotedisplay.engine.plist"
launchctl bootout "gui/$UID_NUM/app.remotedisplay.engine" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/app.remotedisplay.engine.plist"
launchctl kickstart -k "gui/$UID_NUM/app.remotedisplay.engine"

# Contraseña permanente: el flag --password está bloqueado por el gate
# is_installed()/is_root() (el motor no vive en /Applications/RustDesk.app).
# Se usa --set-lan-password, que va por IPC al motor YA corriendo — hay que
# esperar a que el daemon levante el socket.
PW_OK=0
for i in $(seq 1 15); do
    if "$INSTALL_DIR/rustdesk" --set-lan-password "$PASS" 2>&1 | grep -q "Done!"; then
        PW_OK=1
        echo "Contraseña permanente fijada"
        break
    fi
    sleep 1
done
[ "$PW_OK" = "1" ] || { echo "ERROR: no se pudo fijar la contraseña (¿el motor arrancó? revisa $INSTALL_DIR/rustdesk.log)"; exit 1; }

echo "OK: host corriendo en puerto 21118 (log: $INSTALL_DIR/rustdesk.log)"
