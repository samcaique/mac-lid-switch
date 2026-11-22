#!/bin/zsh
set -eu
setopt PIPE_FAIL
cd "${0:A:h}"
mode="${1:-adhoc}"
case "$mode" in
    adhoc) ;;
    release)
        : "${LIDSWITCH_SIGN_IDENTITY:?Developer ID Application signing identity required}"
        : "${LIDSWITCH_TEAM_ID:?Apple Developer Team ID required}"
        : "${LIDSWITCH_NOTARY_PROFILE:?Keychain profile for notarytool required}"
        [[ "$LIDSWITCH_SIGN_IDENTITY" != "-" ]] || { print -u2 "A notarized build requires a Developer ID Application identity."; exit 1; }
        ;;
    *) print -u2 'Usage: zsh package.sh [adhoc|release] [output-directory]'; exit 2 ;;
esac
destination="${2:-$PWD/dist/$mode}"
destination="${destination:a}"
work=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/lid-switch.XXXXXXXX")
trap '/bin/rm -rf "$work"' EXIT
export LIDSWITCH_BUILD_DIR="$work/build"
if [[ "$mode" == adhoc ]]; then
    unset LIDSWITCH_SIGN_IDENTITY LIDSWITCH_TEAM_ID
fi
/bin/zsh build.sh
app="$LIDSWITCH_BUILD_DIR/Lid Switch.app"
helper="$app/Contents/Library/LaunchServices/LidSwitchHelper"
out="$work/output"
mkdir -p "$out" "$work/disk"
if [[ "$mode" == release ]]; then
    devtools="${LIDSWITCH_XCODE_DIR:-/Applications/Xcode.app/Contents/Developer}/usr/bin"
    notary="$devtools/notarytool"
    stapler="$devtools/stapler"
    [[ -x "$notary" && -x "$stapler" ]] || { print -u2 'Install Xcode or set LIDSWITCH_XCODE_DIR.'; exit 1; }
    /usr/bin/ditto -c -k --keepParent "$app" "$work/app-to-notarize.zip"
    "$notary" submit "$work/app-to-notarize.zip" --keychain-profile "$LIDSWITCH_NOTARY_PROFILE" --wait
    "$stapler" staple "$app"
    "$stapler" validate "$app"
    /usr/bin/syspolicy_check distribution "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --strict "$helper"
/usr/bin/ditto "$app" "$work/disk/Lid Switch.app"
/bin/ln -s /Applications "$work/disk/Applications"
/usr/bin/touch "$work/disk/.lid-switch-install-media"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname "Install Lid Switch" -srcfolder "$work/disk" "$out/Lid-Switch.dmg"
if [[ "$mode" == release ]]; then
    /usr/bin/codesign --force --sign "$LIDSWITCH_SIGN_IDENTITY" --timestamp "$out/Lid-Switch.dmg"
    "$notary" submit "$out/Lid-Switch.dmg" --keychain-profile "$LIDSWITCH_NOTARY_PROFILE" --wait
    "$stapler" staple "$out/Lid-Switch.dmg"
    "$stapler" validate "$out/Lid-Switch.dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature "$out/Lid-Switch.dmg"
fi
/usr/bin/hdiutil verify "$out/Lid-Switch.dmg"
/usr/bin/ditto -c -k --keepParent "$app" "$out/Lid-Switch.zip"
# Package only the files used to build, test, or document the app.
source_dir="$work/mac-lid-switch"
mkdir -p "$source_dir/docs/images" "$source_dir/icon-work"
source_files=(.gitignore LICENSE README.md RELEASING.md build.sh package.sh Installer.sh
    ControlService.swift DisplaySupport.swift Helper.swift LightModel.swift LidSwitch.swift StatusIcons.swift
    HelperIntegrationChecks.py InstallerChecks.py InterfaceChecks.swift PackageChecks.py
    docs/release-notes.md docs/images/on-off.png icon-work/make_icon.swift)
for file in "${source_files[@]}"; do
    /bin/cp "$file" "$source_dir/$file"
done
(cd "$work" && /usr/bin/zip -X -qr "$out/Lid-Switch-source.zip" mac-lid-switch)
(cd "$out" && /usr/bin/shasum -a 256 Lid-Switch.dmg Lid-Switch.zip Lid-Switch-source.zip > SHA256SUMS)
mkdir -p "$destination"
/usr/bin/ditto "$out" "$destination"
print "Packages: $destination"
