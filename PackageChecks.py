"""Mount a built image, copy the app, and exercise it after ejecting the image."""
import argparse
import filecmp
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

def verify_app(app):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    run("/usr/bin/codesign", "--verify", "--strict", app / "Contents/Library/LaunchServices/LidSwitchHelper")
    resources = app / "Contents/Resources"
    assert not filecmp.cmp(resources / "DockOn.png", resources / "DockOff.png", shallow=False)
    license_text = (Path(__file__).resolve().parent / "LICENSE").read_bytes()
    assert (app / "Contents/Resources/LICENSE").read_bytes() == license_text
    with (app / "Contents/Info.plist").open("rb") as handle:
        assert plistlib.load(handle)["CFBundleIdentifier"] == "org.lidswitch.app"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("dmg", type=Path)
parser.add_argument("--save-images", type=Path)
args = parser.parse_args()
dmg = args.dmg.resolve(strict=True)
zip_path = dmg.with_suffix(".zip")
for artifact in (dmg, zip_path):
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    assert f"{digest}  {artifact.name}" in (dmg.parent / "SHA256SUMS").read_text().splitlines()

with tempfile.TemporaryDirectory(prefix="lid-switch-test-", dir="/private/tmp") as temp:
    root = Path(temp)
    mount = root / "Install Lid Switch"
    mount.mkdir()
    installed = root / "Applications/Lid Switch.app"
    installed.parent.mkdir()
    run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
    try:
        assert os.readlink(mount / "Applications") == "/Applications"
        assert (mount / ".lid-switch-install-media").is_file()
        run("/usr/bin/ditto", mount / installed.name, installed)
    finally:
        run("/usr/bin/hdiutil", "detach", mount)
    extracted = root / "extracted"
    run("/usr/bin/ditto", "-x", "-k", zip_path, extracted)
    verify_app(installed)
    verify_app(extracted / installed.name)
    relative = Path("Contents/MacOS/LidSwitch")
    exe = installed / relative
    assert filecmp.cmp(exe, extracted / installed.name / relative, shallow=False)
    images = args.save_images or root
    images.mkdir(exist_ok=True, parents=True)
    for state in ("on", "off"):
        target = images / (state + ".png")
        run(exe, "--preview", state, "--render", target)
        assert target.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    assert not filecmp.cmp(images / "on.png", images / "off.png", shallow=False)
    with subprocess.Popen([exe], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as app:
        try:
            time.sleep(1.5)
            assert app.poll() is None, "The installed application exited during startup."
        finally:
            if app.poll() is None:
                app.terminate()
print("Passed: archive digests, read-only mount, Applications link, copy, eject, launch, both icon states, ZIP extraction and code signatures.")
