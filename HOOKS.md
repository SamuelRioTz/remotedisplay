# HOOKS.md — ganchos de client/ dentro del engine

Regla del proyecto: `client/` NO edita el engine salvo **ganchos mínimos,
backward-compatible y documentados acá**. En cada update de upstream
(`engine/update.sh`), esta lista es lo único a revisar si hay conflictos
del lado Flutter.

| # | Archivo (engine/rustdesk/) | Qué | Por qué |
|---|---|---|---|
| 1 | `flutter/lib/desktop/pages/remote_page.dart` | Param opcional `showToolbar = true` en `RemotePage`; con `false` no monta la `RemoteToolbar` integrada | `client/` suprime la toolbar de RustDesk y superpone la suya (`client/lib/session/session_toolbar.dart`). Default `true` ⇒ el app del engine no cambia en nada |

Notas:
- Los ganchos se marcan en el código con un comentario `remotedisplay:`.
- Todo lo demás que `client/` necesita del engine lo consume como package
  (`flutter_hbb` por path) sin modificarlo: `RemotePage`, modelos, helpers de
  toolbar (`toolbarImageQuality`/`toolbarCodec`), `handleUriLink`, etc.
