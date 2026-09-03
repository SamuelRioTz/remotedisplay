#!/bin/bash
# Show everything that is OURS in engine/rustdesk/ as a diff against the upstream snapshot
# (engine against the BASELINE tag + libs/hbb_common against that tag's submodule commit).
# Usage:
#   bash engine/diff.sh              → full diff (a single patch)
#   bash engine/diff.sh --stat       → per-file summary (the last block is libs/hbb_common)
#   bash engine/diff.sh > ours.patch → export; re-apply with git apply --directory=engine/rustdesk
set -e
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
source engine/lib.sh
BASE=$(tr -d '[:space:]' < engine/BASELINE)
ensure_upstream_tag "$BASE"
HBB=$(hbb_commit_of "$BASE")
ensure_hbb_commit "$HBB"

# HEAD:engine/rustdesk is the tree of engine/rustdesk/; the tag is the upstream tree.
if [ $# -gt 0 ] && [[ " $* " == *" --stat"* ]]; then
    git diff "$@" "$BASE" HEAD:engine/rustdesk -- . ':(exclude)libs/hbb_common'
    echo "libs/hbb_common (against rustdesk/hbb_common@${HBB:0:7}):"
    git diff "$@" "$HBB" HEAD:engine/rustdesk/libs/hbb_common
else
    our_diff HEAD "$BASE" "$HBB" "$@"
fi
