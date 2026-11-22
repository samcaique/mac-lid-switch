#!/bin/zsh
set -eu
setopt PIPE_FAIL
cd "${0:A:h}"
mode="${1:-preview}"
case "$mode" in
    preview) prefix=Lid-Switch-local ;;
    release)
        : "${LIDSWITCH_SIGN_IDENTITY:?Developer ID Application signing identity required}"
        : "${LIDSWITCH_TEAM_ID:?Apple Developer Team ID required}"
        : "${LIDSWITCH_NOTARY_PROFILE:?Keychain profile for notarytool required}"
        [[ "$LIDSWITCH_SIGN_IDENTITY" != "-" ]] || { print -u2 "An ad hoc identity cannot sign a public release."; exit 1; }
        if [[ -n "${GITHUB_REPOSITORY:-}" && ! "$GITHUB_REPOSITORY" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]]; then
            print -u2 'GITHUB_REPOSITORY must be in owner/repository format.'
            exit 2
        fi
        prefix=Lid-Switch ;;
    *) print -u2 'Usage: zsh package.sh [preview|release] [output-directory]'; exit 2 ;;
esac
destination="${2:-$PWD/dist/$mode}"
destination="${destination:a}"
work=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/lid-switch.XXXXXXXX")
trap '/bin/rm -rf "$work"' EXIT
export LIDSWITCH_BUILD_DIR="$work/build"
if [[ "$mode" == preview ]]; then
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
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname "Install Lid Switch" -srcfolder "$work/disk" "$out/$prefix.dmg"
if [[ "$mode" == release ]]; then
    /usr/bin/codesign --force --sign "$LIDSWITCH_SIGN_IDENTITY" --timestamp "$out/$prefix.dmg"
    "$notary" submit "$out/$prefix.dmg" --keychain-profile "$LIDSWITCH_NOTARY_PROFILE" --wait
    "$stapler" staple "$out/$prefix.dmg"
    "$stapler" validate "$out/$prefix.dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature "$out/$prefix.dmg"
fi
/usr/bin/hdiutil verify "$out/$prefix.dmg"
/usr/bin/ditto -c -k --keepParent "$app" "$out/$prefix.zip"
(cd "$out" && /usr/bin/shasum -a 256 "$prefix.dmg" "$prefix.zip" > SHA256SUMS)
if [[ "$mode" == release && -n "${GITHUB_REPOSITORY:-}" ]]; then
    download="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/Lid-Switch"
    /usr/bin/awk -v url="$download" '
        /^The first signed download is pending[.]/ {
            print "[Download for Mac](" url ".dmg) · [ZIP](" url ".zip)"
            print ""
            print "Open the disk image and drag **Lid Switch** into **Applications**. For the ZIP, unzip it and move the app to Applications. Open Lid Switch to set up the light."
            replaced++
            next
        }
        { print }
        END { if (replaced != 1) exit 1 }
    ' README.md > "$out/README.for-GitHub.md"
fi
mkdir -p "$destination"
/usr/bin/ditto "$out" "$destination"
print "Packages: $destination"
