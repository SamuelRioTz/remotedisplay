#!/bin/bash
# Update engine/rustdesk/ to a new upstream RustDesk tag, re-applying our changes on
# top with a 3-way merge.
#
# Usage: bash engine/update.sh <upstream-tag>      (e.g. bash engine/update.sh 1.5.0)
# Preview first with: bash engine/check.sh <upstream-tag>
#
# Flow:
#   1. Compute OUR complete diff: upstream(baseline) → current engine/rustdesk/.
#      libs/hbb_common (a submodule upstream, vendored here) is diffed separately
#      against the submodule commit of the old tag (see engine/lib.sh).
#   2. Replace engine/rustdesk/ with the pristine snapshot of the new tag — with the
#      new tag's hbb_common expanded in place of the gitlink — and commit it
#      ("engine: snapshot upstream X.Y.Z"): history always tells upstream from ours.
#      Only the tag's files are added (build artifacts living in engine/ are untouched).
#   3. Re-apply our diff with `git apply --3way`. Where upstream touched the same
#      lines, conflicts are left marked to resolve by hand.
#   4. Update engine/BASELINE. The final commit is yours, after reviewing/resolving:
#      git commit (everything is already staged).
set -e
NEW="${1:?Usage: update.sh <upstream-tag>  (e.g. 1.5.0)}"
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
OLD=$(cat engine/BASELINE 2>/dev/null | tr -d '[:space:]')
[ -n "$OLD" ] || { echo 'ERROR: engine/BASELINE is missing'; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: the working tree has uncommitted changes — commit or stash first."
    exit 1
fi

source engine/lib.sh
echo "→ fetching upstream tags $OLD and $NEW…"
ensure_upstream_tag "$OLD"
ensure_upstream_tag "$NEW"
OLD_HBB=$(hbb_commit_of "$OLD"); NEW_HBB=$(hbb_commit_of "$NEW")
echo "→ fetching hbb_common ${OLD_HBB:0:7} (old) and ${NEW_HBB:0:7} (new)…"
ensure_hbb_commit "$OLD_HBB"
ensure_hbb_commit "$NEW_HBB"

echo "→ 1/4 extracting our diff ($OLD + hbb_common ${OLD_HBB:0:7} → current engine/rustdesk/)…"
OURS=$(mktemp -t rustdesk-ours.XXXXXX)
our_diff HEAD "$OLD" "$OLD_HBB" > "$OURS"
echo "   $(grep -c '^diff --git' "$OURS") files of ours ($OURS)"

echo "→ 2/4 pristine snapshot of upstream $NEW into engine/rustdesk/…"
git rm -rq engine/rustdesk
stage_pristine_snapshot "$NEW" "$NEW_HBB"   # see engine/lib.sh
git commit -qm "engine: snapshot upstream $NEW + hbb_common ${NEW_HBB:0:7} (pristine, none of our changes)"
git checkout -q -- engine/rustdesk

echo "→ 3/4 re-applying our diff with 3-way (in the index)…"
APPLYLOG=$(mktemp -t rustdesk-apply.XXXXXX)
# --cached: applies against the index — immune to CRLF/locks of the working tree.
git apply --binary --cached --3way --directory=engine/rustdesk "$OURS" 2>"$APPLYLOG" || true
CONFLICTS=$(git ls-files -u | awk '{print $4}' | sort -u)

if [ -n "$CONFLICTS" ]; then
    echo "   ⚠ CONFLICTS (upstream touched the same lines we did):"
    echo "$CONFLICTS" | sed 's/^/     /'
    echo "   Materialize the markers with: git checkout -m -- <file>"
    echo "   (apply log: $APPLYLOG)"
elif git diff --cached --quiet; then
    echo "   ✗ ERROR: the apply changed nothing — check $APPLYLOG:"
    tail -5 "$APPLYLOG" | sed 's/^/     /'
    exit 1
else
    N=$(git diff --cached --name-only | wc -l | tr -d ' ')
    echo "   ✓ applied cleanly ($N files staged)"
    git checkout -q -- engine/rustdesk
fi

echo "→ 4/4 updating the baseline and recording the run in SYNC.md"
echo "$NEW" > engine/BASELINE
NFILES=$(grep -c '^diff --git' "$OURS")
if [ -n "$CONFLICTS" ]; then
    RES="⚠ conflicts: $(echo "$CONFLICTS" | tr '
' ' ')"
else
    RES="✓ clean ($NFILES files re-applied)"
fi
printf '| %s | update **%s** → **%s** (hbb_common %s → %s) | %s |
' "$(date +%F)" "$OLD" "$NEW" "${OLD_HBB:0:7}" "${NEW_HBB:0:7}" "$RES" >> engine/SYNC.md
git add engine/BASELINE engine/SYNC.md

echo
echo "DONE. Review (git status / git diff --cached), resolve conflicts if any,"
echo "build to verify, and commit:"
echo "  git commit -m 'engine: re-apply our changes on top of $NEW'"
