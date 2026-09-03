#!/bin/bash
# Check upstream RustDesk for new releases and dry-run an update. Touches nothing:
# no commits, no changes to the index or the working tree.
# Usage:
#   bash engine/check.sh          → list upstream release tags newer than BASELINE
#   bash engine/check.sh <tag>    → would our diff re-apply cleanly on <tag>? (3-way, in a temp index)
set -e
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
source engine/lib.sh
BASE=$(tr -d '[:space:]' < engine/BASELINE)

if [ $# -eq 0 ]; then
    echo "baseline: upstream $BASE"
    NEWER=$(upstream_tags_newer_than "$BASE")
    if [ -z "$NEWER" ]; then
        echo "up to date: no upstream release newer than $BASE"
        exit 0
    fi
    echo "newer upstream releases:"
    echo "$NEWER" | sed 's/^/  /'
    echo "dry-run the latest with: bash engine/check.sh $(echo "$NEWER" | tail -1)"
    exit 0
fi

NEW=$1
ensure_upstream_tag "$BASE"
ensure_upstream_tag "$NEW"
OLD_HBB=$(hbb_commit_of "$BASE"); NEW_HBB=$(hbb_commit_of "$NEW")
ensure_hbb_commit "$OLD_HBB"
ensure_hbb_commit "$NEW_HBB"

echo "upstream $BASE → $NEW:$(git diff --shortstat "$BASE" "$NEW" -- . ':(exclude)libs/hbb_common')"
echo "hbb_common ${OLD_HBB:0:7} → ${NEW_HBB:0:7}:$(git diff --shortstat "$OLD_HBB" "$NEW_HBB")"

OURS=$(mktemp -t rustdesk-ours.XXXXXX)
our_diff HEAD "$BASE" "$OLD_HBB" > "$OURS"
echo "our diff: $(grep -c '^diff --git' "$OURS") files"

# Pristine snapshot of NEW in a TEMPORARY index, then 3-way apply of our diff on it.
TMPIDX=$(mktemp -t rustdesk-idx.XXXXXX); rm -f "$TMPIDX"
LOG=$(mktemp -t rustdesk-apply.XXXXXX)
export GIT_INDEX_FILE="$TMPIDX"
stage_pristine_snapshot "$NEW" "$NEW_HBB"
PRISTINE=$(git write-tree)
RC=0
git apply --binary --cached --3way --directory=engine/rustdesk "$OURS" 2>"$LOG" || RC=$?
CONFLICTS=$(git ls-files -u | awk '{print $4}' | sort -u)
CHANGED=$(git diff --cached --name-only "$PRISTINE" | wc -l | tr -d ' ')
unset GIT_INDEX_FILE
rm -f "$TMPIDX"

# Note: "repository lacks the necessary blob to perform 3-way merge" in the log is
# expected noise for mode-only changes; git then falls back to direct application.
if [ -n "$CONFLICTS" ]; then
    echo "⚠ conflicts to resolve by hand ($(echo "$CONFLICTS" | wc -l | tr -d ' ') files; $CHANGED files touched):"
    echo "$CONFLICTS" | sed 's/^/  /'
    echo "the rest of our diff applies; update with: bash engine/update.sh $NEW"
    exit 2
elif [ "$RC" -ne 0 ]; then
    echo "✗ the patch could not be applied (git apply exit $RC; log: $LOG):"
    grep -E '^error:' "$LOG" | grep -v 'lacks the necessary blob' | head -20 | sed 's/^/  /'
    exit 1
else
    echo "✓ our diff re-applies cleanly on $NEW ($CHANGED files, no conflicts)"
    echo "to update for real: bash engine/update.sh $NEW"
fi
