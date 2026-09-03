#!/bin/bash
# Muestra TODO lo nuestro en engine/rustdesk/ como diff contra el snapshot de upstream.
# Uso:
#   bash engine/diff.sh            → diff completo
#   bash engine/diff.sh --stat     → solo resumen de archivos
#   bash engine/diff.sh > mio.patch  → exportar como patch re-aplicable
set -e
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
BASE=$(cat engine/BASELINE | tr -d '[:space:]')

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/rustdesk/rustdesk.git
git rev-parse -q --verify "refs/tags/$BASE" >/dev/null || git fetch --depth 1 upstream tag "$BASE"

# HEAD:engine/rustdesk es el árbol de engine/rustdesk/; el tag es el árbol de upstream.
# Sin args: patch completo con binarios (exportable). Con args (--stat, etc.): esos.
if [ $# -gt 0 ]; then
    git diff "$@" "$BASE" HEAD:engine/rustdesk
else
    git diff --binary "$BASE" HEAD:engine/rustdesk
fi
