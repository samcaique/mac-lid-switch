#!/bin/zsh
set -eu
cd "${0:A:h}"
if (( $# > 1 )) || [[ -n "${1:-}" && "${1:-}" != --install ]]; then
    print -u2 'Usage: zsh build.sh [--install]'
    exit 2
fi
if [[ -z "${DEVELOPER_DIR:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
compiler=$(/usr/bin/xcrun --find swiftc)
build_root="${LIDSWITCH_BUILD_DIR:-$HOME/.cache/lid-switch-build}"
app="$build_root/Lid Switch.app"
helper_id="org.lidswitch.control.helper"
identity="${LIDSWITCH_SIGN_IDENTITY:--}"
team="${LIDSWITCH_TEAM_ID:-}"
codesign_flags=(--force --options runtime --sign "$identity")
if [[ "$identity" == "-" ]]; then
    [[ -z "$team" ]] || { print -u2 "A distribution build requires a Developer ID Application identity."; exit 1; }
else
    [[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 "Supply the expected 10-character LIDSWITCH_TEAM_ID."; exit 1; }
    codesign_flags+=(--timestamp)
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchServices"
helper="$app/Contents/Library/LaunchServices/LidSwitchHelper"
"$compiler" -O -sdk "$sdk" -target arm64-apple-macos14.0 Helper.swift -o "$helper"
/usr/bin/codesign "${codesign_flags[@]}" --identifier "$helper_id" "$helper"
if [[ "$identity" == "-" ]]; then
    cdhash=$(/usr/bin/codesign -d --verbose=4 "$helper" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
    [[ "$cdhash" =~ '^[0-9a-f]{40}$' ]] || { print -u2 "Missing helper code hash"; exit 1; }
    requirement="identifier \"$helper_id\" and cdhash H\"$cdhash\""
else
    authority="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team\""
    requirement="identifier \"$helper_id\" and ($authority)"
fi
/usr/bin/codesign --verify --strict --all-architectures -R "=$requirement" "$helper"
# Compile the trust rule and installer into the app, independent of bundle resources.
{
    print -r 'enum BuildTrust {'
    printf '    static let helperRequirement = #"%s"#\n' "$requirement"
    print -r '    static let installer = #"""'
    /bin/cat Installer.sh
    print -r '"""#'
    print -r '}'
} > "$build_root/BuildTrust.swift"
"$compiler" -O -sdk "$sdk" -target arm64-apple-macos14.0 LidSwitch.swift LightModel.swift DisplaySupport.swift StatusIcons.swift ControlService.swift "$build_root/BuildTrust.swift" -o "$app/Contents/MacOS/LidSwitch"
iconset="$build_root/LidSwitch.iconset"
mkdir -p "$iconset"
"$compiler" -O -sdk "$sdk" icon-work/make_icon.swift -o "$build_root/make-icon"
"$build_root/make-icon" "$iconset" "$app/Contents/Resources"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/LidSwitch.icns"
/usr/bin/install -m 0644 LICENSE "$app/Contents/Resources/LICENSE"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LidSwitch</string>
<key>CFBundleIdentifier</key><string>org.lidswitch.app</string>
<key>CFBundleName</key><string>Lid Switch</string>
<key>CFBundleDisplayName</key><string>Lid Switch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleIconFile</key><string>LidSwitch</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Lid Switch contributors</string>
</dict></plist>
PLIST
/usr/bin/xattr -cr "$app"
/usr/bin/codesign "${codesign_flags[@]}" "$app"
if [[ "$identity" != "-" ]]; then /usr/bin/codesign --verify -R "=$authority" "$app"; fi
/usr/bin/codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
if [[ "${1:-}" == --install ]]; then
    install_dir="$HOME/Applications"
    installed_app="$install_dir/Lid Switch.app"
    mkdir -p "$install_dir"
    if [[ -e "$installed_app" || -L "$installed_app" ]]; then
        print -u2 "Lid Switch is already installed. To update, quit it and replace it in Finder with $app."
        exit 1
    fi
    stage=$(/usr/bin/mktemp -d "$install_dir/.lid-switch.XXXXXXXX")
    trap '/bin/rm -rf "$stage"' EXIT
    /usr/bin/ditto "$app" "$stage/Lid Switch.app"
    /usr/bin/codesign --verify --deep --strict "$stage/Lid Switch.app"
    # FileManager refuses to replace an existing app, even if another install finished first.
    /usr/bin/xcrun swift - "$stage/Lid Switch.app" "$installed_app" <<'SWIFT'
import Foundation
try FileManager.default.moveItem(atPath: CommandLine.arguments[1], toPath: CommandLine.arguments[2])
SWIFT
    /usr/bin/codesign --verify --deep --strict "$installed_app" || {
        print -u2 "macOS could not verify the app in $install_dir. Use a local Applications folder for the installed copy."
        exit 1
    }
    print "Installed $installed_app"
fi
