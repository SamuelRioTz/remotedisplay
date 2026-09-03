# Contributing

Issues and pull requests are welcome. A few things to know:

- The engine (`engine/rustdesk/`) is a vendored fork. Keep changes there minimal and
  list them in `HOOKS.md`; upstream updates are re-applied with `engine/update.sh`.
- macOS display behaviour is measured, not assumed: if you touch `server-mac/` or
  `src/platform/macos.mm`, add or run a harness in `docs/pruebas/vdisplay-vm/harness/`.
- Commit messages: short imperative summary, body explains *why*.
- By contributing you agree that your contribution is licensed under AGPL-3.0.
