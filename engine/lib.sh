#!/bin/bash
# Shared helpers for diff.sh, update.sh and check.sh (meant to be `source`d, not run).
#
# libs/hbb_common is a git SUBMODULE upstream (rustdesk/hbb_common); in
# engine/rustdesk/ it is vendored (expanded into the tree). Its baseline is never
# written by hand: it is the commit the `libs/hbb_common` gitlink of the upstream
# tag points to (`git ls-tree <tag> libs/hbb_common`).
UPSTREAM_URL=https://github.com/rustdesk/rustdesk.git
HBB_URL=https://github.com/rustdesk/hbb_common.git

# Fetch the upstream tag if we do not have it (remote `upstream`, shallow fetch).
ensure_upstream_tag() { # <tag>
    git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
    git rev-parse -q --verify "refs/tags/$1" >/dev/null || git fetch --depth 1 upstream tag "$1"
}

# hbb_common commit referenced by the tag's gitlink.
hbb_commit_of() { # <tag>
    git ls-tree "$1" libs/hbb_common | awk '$2=="commit"{print $3}'
}

# Fetch that commit from the hbb_common repo (by SHA, shallow) and pin it under a
# ref so that gc does not prune it.
ensure_hbb_commit() { # <sha>
    [ -n "$1" ] || { echo "ERROR: the tag has no libs/hbb_common gitlink" >&2; return 1; }
    git cat-file -e "$1^{commit}" 2>/dev/null || git fetch -q --depth 1 "$HBB_URL" "$1:refs/hbb_common/$1"
}

# Upstream release tags (x.y.z) newer than <base>, oldest first.
upstream_tags_newer_than() { # <base>
    git ls-remote --tags --refs "$UPSTREAM_URL" | awk -F/ '{print $NF}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | awk -v b="$1" '$0==b{f=1; next} f'
}

# Our complete diff as ONE patch applicable with `git apply --directory=engine/rustdesk`:
#   engine (without libs/hbb_common) against the tag + libs/hbb_common against its
#   commit, the latter with the libs/hbb_common/ path prefix.
# <rev> is the monorepo revision (normally HEAD) whose engine/rustdesk/ is compared.
# Extra args (e.g. --stat) go to both diffs; with no args, --binary.
our_diff() { # <rev> <tag> <hbb-sha> [git diff args]
    local REV=$1 TAG=$2 HBB=$3; shift 3
    local ARGS=("$@"); [ ${#ARGS[@]} -gt 0 ] || ARGS=(--binary)
    git diff "${ARGS[@]}" "$TAG" "${REV}:engine/rustdesk" -- . ':(exclude)libs/hbb_common'
    git diff "${ARGS[@]}" --src-prefix=a/libs/hbb_common/ --dst-prefix=b/libs/hbb_common/ "$HBB" "${REV}:engine/rustdesk/libs/hbb_common"
}

# Stage the pristine snapshot of upstream <tag> under engine/rustdesk/ in the CURRENT
# index (whatever GIT_INDEX_FILE points to), with the hbb_common commit expanded in
# place of the gitlink. read-tree stages the tag's tree directly: exact blobs and
# modes, without going through the filesystem (tar on Windows loses the +x bit).
stage_pristine_snapshot() { # <tag> <hbb-sha>
    git read-tree --prefix=engine/rustdesk/ "$1"
    git update-index --force-remove engine/rustdesk/libs/hbb_common
    git read-tree --prefix=engine/rustdesk/libs/hbb_common/ "$2"
}
