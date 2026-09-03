# HOOKS.md — client/ hooks inside the engine

Project rule: `client/` does NOT edit the engine except for **minimal,
backward-compatible hooks documented here**. On every upstream update
(`engine/update.sh`), this list is the only thing to review if there are conflicts
on the Flutter side.

| # | File (engine/rustdesk/) | What | Why |
|---|---|---|---|
| 1 | `flutter/lib/desktop/pages/remote_page.dart` | Optional `showToolbar = true` param on `RemotePage`; with `false` it doesn't mount the built-in `RemoteToolbar` | `client/` suppresses RustDesk's toolbar and overlays its own (`client/lib/session/session_toolbar.dart`). Default `true` ⇒ the engine's own app doesn't change at all |

Notes:
- Hooks are marked in the code with a `remotedisplay:` comment.
- Everything else `client/` needs from the engine is consumed as a package
  (`flutter_hbb` by path) without modifying it: `RemotePage`, models, toolbar
  helpers (`toolbarImageQuality`/`toolbarCodec`), `handleUriLink`, etc.
