# Building a release

Use an Apple silicon Mac with the Command Line Tools for Xcode. The build compiles Swift sources locally and draws the icons from the artwork in `icon-work/`.

## Local package

```sh
zsh package.sh preview
```

The local DMG and ZIP appear in `dist/preview/`. Both contain an ad hoc signed app. These packages are for local testing.

## Checks

Run these from a logged-in macOS desktop session. The first two checks use temporary files, a disposable preferences domain and the current account. The installer check also drives the app’s button and recovery dialog logic against that helper. These tests leave the physical light alone.

```sh
python3 HelperIntegrationChecks.py
python3 InstallerChecks.py
python3 PackageChecks.py dist/preview/Lid-Switch-local.dmg
```

For a hardware check, start with a clean installation on a compatible Mac. Cancel setup once, then retry. Verify the physical logo and both icons after switching each way, after quitting and reopening, and after restarting macOS. Remove the helper from the app menu and check that its launch daemon and files are gone.

## Sign and notarize

Install Xcode and a Developer ID Application certificate with its private key in the signing keychain. Store the notarization credentials with `notarytool store-credentials`. Set the following environment variables in the release shell.

| Variable | Value |
| --- | --- |
| `LIDSWITCH_SIGN_IDENTITY` | Developer ID Application identity or its certificate fingerprint |
| `LIDSWITCH_TEAM_ID` | Ten-character team ID on the certificate |
| `LIDSWITCH_NOTARY_PROFILE` | Name of the saved notarytool Keychain profile |
| `GITHUB_REPOSITORY` (optional) | GitHub repository in owner/repository format, used to generate direct download links |
| `LIDSWITCH_XCODE_DIR` (optional) | Developer directory for an Xcode installation outside /Applications/Xcode.app |

```sh
zsh package.sh release
python3 PackageChecks.py dist/release/Lid-Switch.dmg
```

The script signs the helper and app, verifies their signing team, submits the app to Apple, and staples its ticket. It then signs and notarizes the disk image and checks it with Gatekeeper. The ZIP contains the stapled app. The final checksums cover the exact download files. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## GitHub release

Tag the version in `build.sh`. Create a draft GitHub release, use the [release description](docs/release-notes.md) and attach `Lid-Switch.dmg`, `Lid-Switch.zip` and `SHA256SUMS` from `dist/release/`. GitHub supplies the source archives for the tag.

Once the release is public, use the download links from `dist/release/README.for-GitHub.md` in the repository README. That file is generated when `GITHUB_REPOSITORY` is set. Download the DMG from the live release and check the drag-to-Applications flow with Gatekeeper enabled.
