# HOOKS.md — client/ hooks inside the engine

Project rule: `client/` does NOT edit the engine except for **minimal,
backward-compatible hooks documented here**. On every upstream update
(`engine/update.sh`), this list is the only thing to review if there are conflicts
on the Flutter side.

| # | File (engine/rustdesk/) | What | Why |
|---|---|---|---|
| 1 | `flutter/lib/desktop/pages/remote_page.dart` | Optional `showToolbar = true` param on `RemotePage`; with `false` it doesn't mount the built-in `RemoteToolbar` | `client/` suppresses RustDesk's toolbar and overlays its own (`client/lib/session/session_toolbar.dart`). Default `true` ⇒ the engine's own app doesn't change at all |
| 2 | `flutter/lib/models/peer_model.dart` | `Peer.machineId` and `Peer.onlineKnown` from the event JSON (`machine_id`, `online`); `Peers._updatePeers` keeps the engine's `online` verdict for peers that carry one instead of copying the previous list's state | `client/lib/home.dart` groups a host's addresses by its engine id and hides the old leases of a machine the engine's scan did not find. Lists without those keys (recent, favorites) behave exactly as upstream |

Notes:
- Hooks are marked in the code with a `remotedisplay:` comment.
- Everything else `client/` needs from the engine is consumed as a package
  (`flutter_hbb` by path) without modifying it: `RemotePage`, models, toolbar
  helpers (`toolbarImageQuality`/`toolbarCodec`), `handleUriLink`, etc.
