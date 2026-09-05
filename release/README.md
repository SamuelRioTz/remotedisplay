# release/ — Remote Display binaries

> **Current version: 1.0.5** (source of truth: `version:` in `client/pubspec.yaml`; it's
> reflected here, in the main README, and in the `v<version>` tag).
>
> **Version bump**: only when explicitly requested. When requested, the number changes
> in `client/pubspec.yaml` (`version: X.Y.Z+N`), in the main README and in this line, and
> the next release uses the new tag. If not requested, the current version is reused (the
> artifacts are re-uploaded/updated to the existing Release with `--clobber`).

Binaries go to **GitHub Releases** of the (private) repo, tag `v<version>`. No
binaries in git (`release/out/` is in .gitignore).

## Artifacts and how they're produced

| Artifact | Built on | Command |
|---|---|---|
| `RemoteDisplay-Setup-<ver>.exe` (Inno) + `RemoteDisplay-<ver>-windows-x64-portable.zip` | Windows PC | `release/release-windows.ps1 -Upload` |
| `RemoteDisplay-<ver>-android-arm64.apk` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-macos-client.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-Server-<ver>-macos.dmg` | Mac | `release/release-mac.sh` |
| `RemoteDisplay-<ver>-ios.ipa` | Mac | `release/release-mac.sh` |

## Full release flow

1. Bump `version:` in `client/pubspec.yaml` and in the main README, commit+push.
2. **Windows PC**: `powershell -ExecutionPolicy Bypass -File release/release-windows.ps1 -Upload`
   (builds, validates, creates the `v<ver>` Release and uploads zip+installer). Over a
   non-interactive SSH session `gh` on the PC may be unauthenticated (401): then fetch the
   two files from `release\out` with `scp` and upload them from the Mac (`gh release upload`).
   Requires an up-to-date engine DLL (`engine/rustdesk/target/release/librustdesk.dll`,
   recipe in `tools/README.md`).
3. **Mac** (run by the Mac's Claude or Sam; codesign needs the graphical session):
   `git pull && bash release/release-mac.sh [--upload]` → builds the 4 artifacts into
   `release/out/`; with `--upload` it also uploads them to the `v<ver>` Release (creates it if it doesn't exist).
   The Mac ALREADY has `gh` authenticated (`SamuelRioTz`), so it uploads directly — step 4 (fetch
   from Windows) is only an alternative if the Mac didn't have `gh`.
   With the Developer ID identity present the two DMGs come out notarized and stapled
   (about 2–5 minutes per submission; `--skip-notarize` for a quick local build).
   - Server's `ENGINE_BIN`: defaults to `engine/rustdesk/target/release/rustdesk` (the monorepo's
     engine binary, already with the serverless patches). Pass another path if you want.
4. **Windows PC** (alternative, if the Mac doesn't have `gh`): `release/release-fetch-mac.ps1` —
   fetches the artifacts from the Mac via scp and uploads them to the same Release.

## Signing and notarization (Mac)

- Identity: `server-mac/sign-identity.sh` picks the personal team's (K45698KZ4W)
  *Developer ID Application* certificate, else its *Apple Development* one. Never another
  team's certificate.
- The Developer ID identity is kept in a dedicated keychain,
  `~/Library/Keychains/remotedisplay-signing.keychain-db`, unlocked for `codesign` without
  prompts (`security set-key-partition-list`) and listed in the user search list. Its
  password and the notary profile name are in `~/.config/remotedisplay/signing.env`
  (mode 600, outside the repo; `release-mac.sh` sources it if present). The identity was
  imported from Sam's private backup of the certificate and key; nothing of it is in this
  repository.
- Notarization uses `xcrun notarytool --keychain-profile remotedisplay-notary`, an App
  Store Connect API key stored with `notarytool store-credentials`. Apps are submitted as
  zips and stapled, then the DMG is signed, submitted and stapled too; the script fails on
  anything but `Accepted` and prints Apple's log. `spctl` must report
  `source=Notarized Developer ID`.
- The macOS server signs with an explicit designated requirement (identifier + team), so a
  development build and a notarized build share the TCC grants; see `server-mac/README.md`.

## Installing the IPA on the iPad/iPhone

The `.ipa` is signed with the development certificate (team K45698KZ4W) — Sam's
devices are already in the profile. From the Mac, with the device connected
and unlocked:

```sh
xcrun devicectl list devices            # UDID
xcrun devicectl device install app --device <UDID> RemoteDisplay-<ver>-ios.ipa
```

(Also: drag it onto the device in Finder, or Apple Configurator.)
The development signature expires: reinstall when the profile lapses.

## Notes

- The Windows portable ZIP runs from any folder without installing; the config
  lives in `%APPDATA%\RemoteDisplay` (older 0.x builds used `%APPDATA%\RustDesk`; that folder can be deleted).
- Installer validated with silent install/uninstall (`/VERYSILENT`).
- `gh` must point at THIS repo: the repo is a fork of rustdesk/rustdesk and unconfigured
  `gh` resolves to the parent. It's already fixed with `gh repo set-default
  SamuelRioTz/remotedisplay` (if it gets recloned, run it again).
