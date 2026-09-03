# engine — the engine and how it syncs with upstream

`engine/rustdesk/` is a **snapshot** of [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk)
(tag in [`BASELINE`](BASELINE)) plus **our changes** applied on top. There is no fork
branch and no submodule: the model is *pristine snapshot → re-apply our diff*.

## Commands

```sh
bash engine/check.sh            # is there a newer upstream release than BASELINE?
bash engine/check.sh 1.5.0      # dry-run: would our diff re-apply cleanly on 1.5.0? (touches nothing)
bash engine/diff.sh --stat      # audit WHAT is ours (full diff vs upstream)
bash engine/diff.sh > ours.patch  # export; re-apply with git apply --directory=engine/rustdesk
bash engine/update.sh 1.5.0     # update the engine to a new tag
```

`update.sh`: (1) extracts our complete diff against the baseline, (2) commits the
pristine snapshot of the new tag (`git read-tree`: exact blobs and modes, which matters
on Windows), (3) re-applies our diff with a 3-way merge in the index — where upstream
touched the same lines, conflicts are left marked — and (4) updates `BASELINE` and
records the run in the table below. You make the final commit after reviewing and
building. `check.sh <tag>` runs steps 1–3 in a temporary index, so you can see the
conflicts before touching anything.

Self-test of the mechanism: updating to the SAME tag must rebuild `engine/rustdesk/`
identically (diff 0). Run it in a clean clone:
`git clone . /tmp/x && cd /tmp/x && bash engine/update.sh $(cat engine/BASELINE)` and then
`git diff --cached --quiet <original HEAD> -- engine/rustdesk`.

### `libs/hbb_common` (a submodule upstream, vendored here)

Upstream ships `libs/hbb_common` as a submodule of
[rustdesk/hbb_common](https://github.com/rustdesk/hbb_common). Here it is expanded into
the tree and `.gitmodules` is deliberately dropped. Its baseline is **never written by
hand**: it is the commit the tag's gitlink points to (`git ls-tree <tag> libs/hbb_common`),
and `engine/lib.sh` fetches it by SHA from the hbb_common repo (pinned under
`refs/hbb_common/<sha>`). `diff.sh` diffs hbb_common against that commit (with the
`libs/hbb_common/` path prefix, so the patch stays a single file) and `update.sh`
expands the NEW tag's hbb_common in place of the gitlink before re-applying our changes.
Without this, an update would leave our old hbb_common underneath a new engine.

### Files upstream force-adds against its own `.gitignore`

Upstream's `.gitignore` ignores `*png`/`*svg` (and `.vscode`), yet upstream tracks them
anyway (the icons in `res/`, the SVGs in `flutter/assets`, Android/iOS mipmaps,
`fastlane/`). When vendoring they must be added with `git add -f`; if they are missing, a
fresh clone does not build (`src/tray.rs` does `include_bytes!` on
`res/mac-tray-dark-x2.png`) and the engine's widgets cannot find their SVGs. The
generated bridge (`src/bridge_generated*.rs`, `flutter/lib/generated_bridge*.dart`) is
NOT committed, as upstream: generate it with `flutter_rust_bridge_codegen` 1.80.1 (see
`tools/README.md`).

## What is ours (delta summary)

`bash engine/diff.sh --stat` as of 2026-09-03: **41 files (+3706/−195) on top of upstream
1.4.9** plus `libs/hbb_common/src/config.rs` (+16/−4) on top of hbb_common@7e1c392.
Everything else in the diff (`.gitmodules` and the hbb_common gitlink deleted) is the
vendoring itself.

| Area | What |
|---|---|
| `src/` | serverless (rendezvous → 127.0.0.1), headless CM `--cm-no-ui`, active LAN + Tailscale discovery (`lan.rs`), no tray in non-flutter builds, no chat / update check |
| `src/platform/macos.mm`, `src/virtual_display_manager.rs`, `src/server/display_service.rs` | dynamic virtual displays on macOS (in-process CGVirtualDisplay, dynamic main, turning physical displays off/on, mirrored-physical mode guard, display topology hash) |
| `libs/scrap` | mirrored-display filter on macOS (`CGDisplayMirrorsDisplay`); a stopped stream is an error, not `WouldBlock` |
| `libs/hbb_common` | serverless defaults in `config.rs` |
| `libs/enigo` | macOS input tweaks |
| `flutter/` | hooks for `client/` (see `HOOKS.md`): `showToolbar`/`keyHelpHorizontal`, mobile keyboard focus, cursor crossing to an external display, etc. |
| `res/`, `fastlane/` | assets upstream force-adds against its `.gitignore` (here too, with `git add -f`) |

## Sync history

| Date | Change | Result |
|---|---|---|
| 2026-08-18 | initial snapshot of upstream **1.4.9** + serverless patches | fork is born |
| 2026-08-19 | self-test: update 1.4.9 → 1.4.9 | ✓ identical (diff 0, 93 files re-applied) |
| 2026-08-19 | self-test of the layout sync: 1.4.9 → 1.4.9 | ✓ mechanism verified |
| 2026-09-03 | snapshot repair on 1.4.9: 123 upstream files that were missing (assets force-added against `.gitignore`, `.gitattributes`, `CLAUDE.md`), 28 `+x` bits lost in the export; `tools/patches/` removed (single source of truth = `diff.sh`); hbb_common baseline derived from the tag (`lib.sh`); `check.sh` added | ✓ self-test in a clean clone: 1.4.9 → 1.4.9 identical (193 files re-applied, 0 conflicts) |
