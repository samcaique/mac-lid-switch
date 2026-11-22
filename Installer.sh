# Embedded in the signed app at build time. $1 is the operation. Install also
# takes the helper path, build-pinned requirement, account UID and launch plist.
set -eu
umask 077
label=org.lidswitch.control
library=/Library
support="$library/Application Support"
service_dir="$support/$label"
helper="$service_dir/LidSwitchHelper"
daemons="$library/LaunchDaemons"
plist="$daemons/$label.plist"
runtime=/private/var/run
service="system/$label"

fail() { echo "$1" >&2; exit 1; }

trusted_directory() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = 0 ] &&
        [ $((0$(/usr/bin/stat -f %Lp "$1") & 022)) -eq 0 ] ||
        fail "The system directory is missing or has unexpected permissions: $1"
}
plain_file_or_absent() {
    [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } ||
        fail "An unexpected item exists at $1."
}
stop_service() {
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
        /bin/launchctl bootout "$service"
    fi
}

trusted_directory "$library"
trusted_directory "$support"
trusted_directory "$daemons"
if [ -e "$service_dir" ] || [ -L "$service_dir" ]; then trusted_directory "$service_dir"; fi
plain_file_or_absent "$helper"
plain_file_or_absent "$plist"

if [ "$1" = remove ]; then
    stop_service
    /bin/rm -f "$plist" "$helper" "$runtime/$label.sock" "$runtime/$label.lock"
    if [ -d "$service_dir" ]; then /bin/rmdir "$service_dir"; fi
    exit 0
fi

[ "$1" = install ] || fail "Unknown installer operation."
stage=$(/usr/bin/mktemp -d "/private/tmp/$label.XXXXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
# Read user-controlled bundle paths with the initiating user's access rights.
# Everything installed from this point on comes from this private root staging area.
/usr/bin/sudo -u "#$4" -- /bin/cat "$2" > "$stage/helper"
/bin/chmod 0755 "$stage/helper"
/usr/bin/codesign --verify --strict --all-architectures -R "=$3" "$stage/helper" ||
    fail "The control helper failed signature verification."
/usr/bin/printf '%s' "$5" | /usr/bin/base64 -D > "$stage/job.plist"
/usr/bin/plutil -lint "$stage/job.plist" >/dev/null

# Verify and prepare before stopping a working installation. If replacement or
# bootstrap fails, put the previous files and launchd registration back.
if [ -f "$helper" ]; then /bin/cp -p "$helper" "$stage/old-helper"; fi
if [ -f "$plist" ]; then /bin/cp -p "$plist" "$stage/old-plist"; fi
was_running=0
if /bin/launchctl print "$service" >/dev/null 2>&1; then was_running=1; fi
new_directory=0
if [ ! -d "$service_dir" ]; then /bin/mkdir -m 0755 "$service_dir"; new_directory=1; fi
stop_service
rollback() {
    set +e
    /bin/rm -f "$helper" "$plist"
    if [ -f "$stage/old-helper" ]; then /bin/mv "$stage/old-helper" "$helper"; fi
    if [ -f "$stage/old-plist" ]; then /bin/mv "$stage/old-plist" "$plist"; fi
    if [ "$new_directory" = 1 ]; then /bin/rmdir "$service_dir"; fi
    if [ "$was_running" = 1 ]; then /bin/launchctl bootstrap system "$plist"; fi
    /bin/rm -rf "$stage"
}
trap rollback EXIT
/usr/bin/install -S -m 0755 "$stage/helper" "$helper"
/usr/bin/install -S -m 0644 "$stage/job.plist" "$plist"
/bin/rm -f "$runtime/$label.sock"
/bin/launchctl bootstrap system "$plist"
trap '/bin/rm -rf "$stage"' EXIT
