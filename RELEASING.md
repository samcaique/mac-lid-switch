# Building a release

Use an Apple silicon Mac with the Command Line Tools for Xcode. The build compiles Swift sources locally and draws the icons from the artwork in `icon-work/`.

## Package the app

```sh
zsh package.sh adhoc
```

The DMG, app ZIP, source ZIP and checksums appear in `dist/adhoc/`. The app and helper use ad hoc signatures. Document this signing status in the release notes.

## Checks

Run these from a logged-in macOS desktop session. The first two checks use temporary files, a disposable preferences domain and the current account. The installer check also drives the app’s button and recovery dialog logic against that helper. These tests leave the physical light alone.

```sh
python3 HelperIntegrationChecks.py
python3 InstallerChecks.py
python3 PackageChecks.py dist/adhoc/Lid-Switch.dmg
```

For a hardware check, start with a clean installation on a compatible Mac. Cancel setup once, then retry. Verify the physical logo and both icons after switching each way, after quitting and reopening, and after restarting macOS. Remove the helper from the app menu and check that its launch daemon and files are gone.

## Sign and notarize

Install Xcode and a Developer ID Application certificate with its private key in the signing keychain. Store the notarization credentials with `notarytool store-credentials`. Set the following environment variables in the release shell.

| Variable | Value |
| --- | --- |
| `LIDSWITCH_SIGN_IDENTITY` | Developer ID Application identity or its certificate fingerprint |
| `LIDSWITCH_TEAM_ID` | Ten-character team ID on the certificate |
| `LIDSWITCH_NOTARY_PROFILE` | Name of the saved notarytool Keychain profile |
| `LIDSWITCH_XCODE_DIR` (optional) | Developer directory for an Xcode installation outside /Applications/Xcode.app |

```sh
zsh package.sh release
python3 PackageChecks.py dist/release/Lid-Switch.dmg
```

The script signs the helper and app, verifies their signing team, submits the app to Apple, and staples its ticket. It then signs and notarizes the disk image and checks it with Gatekeeper. The ZIP contains the stapled app. The final checksums cover the exact download files. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## GitHub release

Create a GitHub release for the version in `build.sh` and tag the matching source commit. Attach `Lid-Switch.dmg`, `Lid-Switch.zip`, `Lid-Switch-source.zip` and `SHA256SUMS` from the same build. Use the [release notes](docs/release-notes.md) and check that their signing information matches the files. Download the published files and verify their checksums.
