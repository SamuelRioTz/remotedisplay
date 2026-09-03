#!/bin/bash
# Actualiza engine/rustdesk/ a un tag nuevo de upstream RustDesk, re-aplicando nuestros
# cambios encima con merge de 3 vías.
#
# Uso: bash engine/update.sh <tag-upstream>      (ej: bash update-engine.sh 1.5.0)
#
# Flujo:
#   1. Calcula NUESTRO diff total: upstream(baseline) → engine/rustdesk/ actual.
#   2. Reemplaza engine/rustdesk/ con el snapshot puro del tag nuevo y lo commitea
#      ("engine: snapshot upstream X.Y.Z") — la historia siempre distingue
#      qué es de upstream y qué es nuestro. Solo se agregan los archivos del
#      tag (los artefactos de build que viven en engine/ no se tocan).
#   3. Re-aplica nuestro diff con `git apply --3way`. Si upstream tocó las
#      mismas líneas, quedan conflictos marcados para resolver a mano.
#   4. Actualiza engine/BASELINE. El commit final lo hacés vos
#      tras revisar/resolver: git commit (ya queda staged).
set -e
NEW="${1:?Uso: update.sh <tag-upstream>  (ej: 1.5.0)}"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
OLD=$(cat engine/BASELINE 2>/dev/null | tr -d '[:space:]')
[ -n "$OLD" ] || { echo 'ERROR: falta engine/BASELINE'; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree con cambios sin commitear — commitea o stashea primero."
    exit 1
fi

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/rustdesk/rustdesk.git
echo "→ trayendo tags $OLD y $NEW de upstream…"
git rev-parse -q --verify "refs/tags/$OLD" >/dev/null || git fetch --depth 1 upstream tag "$OLD"
git rev-parse -q --verify "refs/tags/$NEW" >/dev/null || git fetch --depth 1 upstream tag "$NEW"

echo "→ 1/4 extrayendo nuestro diff ($OLD → engine/rustdesk/ actual)…"
OURS=$(mktemp -t rustdesk-ours.XXXXXX)
git diff --binary "$OLD" HEAD:engine/rustdesk > "$OURS"
echo "   $(grep -c '^diff --git' "$OURS") archivos nuestros ($OURS)"

echo "→ 2/4 snapshot puro de upstream $NEW en engine/rustdesk/…"
# read-tree stagea el árbol del tag directo en el índice: modos ejecutables y
# blobs EXACTOS, sin pasar por el filesystem (tar en Windows pierde el bit +x).
git rm -rq engine/rustdesk
git read-tree --prefix=engine/rustdesk/ "$NEW"
git commit -qm "engine: snapshot upstream $NEW (pristine, sin cambios nuestros)"
git checkout -q -- engine/rustdesk

echo "→ 3/4 re-aplicando nuestro diff con 3-way (en el índice)…"
APPLYLOG=$(mktemp -t rustdesk-apply.XXXXXX)
# --cached: aplica contra el índice — inmune a CRLF/locks del working tree.
git apply --binary --cached --3way --directory=engine/rustdesk "$OURS" 2>"$APPLYLOG" || true
CONFLICTS=$(git ls-files -u | awk '{print $4}' | sort -u)

if [ -n "$CONFLICTS" ]; then
    echo "   ⚠ CONFLICTOS (upstream tocó lo mismo que nosotros):"
    echo "$CONFLICTS" | sed 's/^/     /'
    echo "   Materializá los marcadores con: git checkout -m -- <archivo>"
    echo "   (log del apply: $APPLYLOG)"
elif git diff --cached --quiet; then
    echo "   ✗ ERROR: el apply no aplicó nada — revisá $APPLYLOG:"
    tail -5 "$APPLYLOG" | sed 's/^/     /'
    exit 1
else
    N=$(git diff --cached --name-only | wc -l | tr -d ' ')
    echo "   ✓ aplicó limpio ($N archivos staged)"
    git checkout -q -- engine/rustdesk
fi

echo "→ 4/4 actualizando baseline y registrando en SYNC.md"
echo "$NEW" > engine/BASELINE
NFILES=$(grep -c '^diff --git' "$OURS")
if [ -n "$CONFLICTS" ]; then
    RES="⚠ conflictos: $(echo "$CONFLICTS" | tr '
' ' ')"
else
    RES="✓ limpio ($NFILES archivos re-aplicados)"
fi
printf '| %s | update **%s** → **%s** | %s |
' "$(date +%F)" "$OLD" "$NEW" "$RES" >> engine/SYNC.md
git add engine/BASELINE engine/SYNC.md

echo
echo "LISTO. Revisá (git status / git diff --cached), resolvé conflictos si hay,"
echo "compilá para verificar, y commiteá:"
echo "  git commit -m 'engine: re-aplicar cambios propios sobre $NEW'"
