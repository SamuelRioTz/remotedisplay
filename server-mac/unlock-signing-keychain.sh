#!/bin/bash
# Unlocks the dedicated signing keychain described in ~/.config/remotedisplay/signing.env
# (RD_SIGNING_KEYCHAIN + RD_SIGNING_KEYCHAIN_PASSWORD). A custom keychain stays locked after a
# reboot or logout; without this, codesign pops a keychain password dialog on the build Mac and
# the release script hangs. No-op when the file or the variables are missing.
ENV="$HOME/.config/remotedisplay/signing.env"
[ -f "$ENV" ] || exit 0
. "$ENV"
[ -n "${RD_SIGNING_KEYCHAIN:-}" ] && [ -n "${RD_SIGNING_KEYCHAIN_PASSWORD:-}" ] || exit 0
security unlock-keychain -p "$RD_SIGNING_KEYCHAIN_PASSWORD" "$RD_SIGNING_KEYCHAIN"
