"""Exercise setup against a disposable user launchd job. No sudo or hardware writes."""
import base64
import getpass
import json
import os
from pathlib import Path
import plistlib
import shlex
import socket
import stat
import subprocess
import tempfile
import time
import uuid

src = Path(__file__).resolve().parent
uid = os.getuid()
assert uid != 0
label = "org.lidswitch.control.test." + uuid.uuid4().hex[:12]
domain = "gui/" + str(uid)
clt = Path("/Library/Developer/CommandLineTools")
signed_id = "org.lidswitch.control.helper"


def run(argv, **opts):
    return subprocess.run(argv, check=True, **opts)


def replace_once(source, old, new):
    assert source.count(old) == 1, old
    return source.replace(old, new)


def wait_for_state(expected, path):
    deadline = time.monotonic() + 15
    last = None
    while time.monotonic() < deadline:
        try:
            if request("status", path) == expected:
                return
        except (OSError, ValueError) as error:
            last = error
        time.sleep(0.15)
    raise AssertionError(f"service did not reach {expected}: {last}")


def request(action, path):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(3)
        client.connect(str(path))
        client.sendall((action + "\n").encode())
        with client.makefile("rb") as reply:
            return json.loads(reply.readline())["enabled"]


with tempfile.TemporaryDirectory(dir="/private/tmp", prefix="ll-") as directory:
    root = Path(directory)
    library = root / "Library"
    daemons = library / "LaunchDaemons"
    support = library / "Application Support"
    runtime = root / "run"
    for parent in (daemons, support, runtime):
        parent.mkdir(mode=0o755, parents=True)
    parent_modes = {p: stat.S_IMODE(p.stat().st_mode) for p in (library, daemons, support)}
    sock = runtime / (label + ".sock")
    helper = support / label / "LidSwitchHelper"
    plist = daemons / (label + ".plist")
    source = (src / "Helper.swift").read_text()
    # Model the deployment and permissions under the test account. Keep the
    # real helper protocol, defaults implementation and signature verifier.
    substitutions = {
        '"/var/run/org.lidswitch.control.sock"': json.dumps(str(sock)),
        '"/var/run/org.lidswitch.control.lock"': json.dumps(str(runtime / (label + ".lock"))),
        '"/private/var/run"': json.dumps(str(runtime)),
        '"com.apple.CoreBrightness"': json.dumps(label),
        '"HOME": "/var/root"': '"HOME": ' + json.dumps(str(Path.home())),
        '"USER": "root", "LOGNAME": "root"': '"USER": ' + json.dumps(getpass.getuser()) + ', "LOGNAME": ' + json.dumps(getpass.getuser()),
        "guard geteuid() == 0 else": "guard geteuid() == getuid() else",
        "parentInfo.st_uid == 0": "parentInfo.st_uid == getuid()",
        "lockInfo.st_uid == 0": "lockInfo.st_uid == getuid()",
        "chown(socketPath, authorizedUID, 0)": "chown(socketPath, authorizedUID, getgid())",
    }
    for old, new in substitutions.items():
        source = replace_once(source, old, new)
    swift = root / "Helper.swift"
    swift.write_text(source)
    fixture = root / "helper"
    run([clt / "usr/bin/swiftc", "-O", "-sdk", clt / "SDKs/MacOSX.sdk", swift, "-o", fixture])
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", signed_id, fixture])
    details = run(["/usr/bin/codesign", "-dv", "--verbose=4", fixture], capture_output=True, text=True).stderr
    cdhash = next(row.split("=")[1] for row in details.splitlines() if row.startswith("CDHash="))
    requirement = f'identifier "{signed_id}" and cdhash H"{cdhash}"'
    spec = {"Label": label, "ProgramArguments": [str(helper), str(uid)], "RunAtLoad": True,
            "KeepAlive": True, "StandardErrorPath": str(root / "error.log")}
    encoded = base64.b64encode(plistlib.dumps(spec)).decode()
    script = (src / "Installer.sh").read_text()
    for old, new in {
        "label=org.lidswitch.control": "label=" + label,
        "library=/Library": "library=" + shlex.quote(str(library)),
        "runtime=/private/var/run": "runtime=" + shlex.quote(str(runtime)),
        'service="system/$label"': 'service="' + domain + '/$label"',
        '" = 0 ]': '" = ' + str(uid) + ' ]',
        '/usr/bin/sudo -u "#$4" -- /bin/cat': '/bin/cat',
    }.items():
        script = replace_once(script, old, new)
    script = script.replace("bootstrap system ", "bootstrap " + domain + " ")

    def installer(*args, ok=True):
        result = subprocess.run(["/bin/sh", "-c", script, "InstallerTest", *args], capture_output=True, text=True)
        assert (result.returncode == 0) == ok, (result.returncode, result.stderr)
        return result

    option = ["install", str(fixture), requirement, str(uid), encoded]
    service = domain + "/" + label
    try:
        # The privileged verifier must reject an unrelated signed executable
        # before replacing files or touching an existing registration.
        denied = installer("install", "/usr/bin/true", requirement, str(uid), encoded, ok=False)
        assert "signature verification" in denied.stderr and not plist.exists() and not helper.exists()
        installer(*option)
        wait_for_state(True, sock)
        assert request("off", sock) is False
        # Restart by registering the installed plist again, without the app.
        run(["/bin/launchctl", "bootout", service])
        run(["/bin/launchctl", "bootstrap", domain, plist])
        wait_for_state(False, sock)
        assert request("on", sock) is True
        installer("install", "/usr/bin/true", requirement, str(uid), encoded, ok=False)
        assert request("status", sock) is True
        # A failed bootstrap must restore the previous working job.
        invalid_job = base64.b64encode(plistlib.dumps({"Label": label})).decode()
        installer("install", str(fixture), requirement, str(uid), invalid_job, ok=False)
        wait_for_state(True, sock)
        client = (src / "ControlService.swift").read_text()
        for old, new in {
            '"/var/run/org.lidswitch.control.sock"': json.dumps(str(sock)),
            '"/Library/Application Support/org.lidswitch.control/LidSwitchHelper"': json.dumps(str(helper)),
            '"/Library/LaunchDaemons/org.lidswitch.control.plist"': json.dumps(str(plist)),
            "peerUser == 0": "peerUser == getuid()",
            '"/usr/bin/osascript"': '"/usr/bin/false"',
        }.items():
            client = replace_once(client, old, new)
        test_client = root / "ControlService.swift"
        test_client.write_text(client)
        trust = root / "BuildTrust.swift"
        trust.write_text('enum BuildTrust { static let installer = ""; static let helperRequirement = "" }')
        interface = root / "check-interface"
        run([clt / "usr/bin/swiftc", "-sdk", clt / "SDKs/MacOSX.sdk", test_client, trust,
             src / "LightModel.swift", src / "DisplaySupport.swift", src / "StatusIcons.swift", src / "InterfaceChecks.swift", "-o", interface])
        run([interface, label, sock], timeout=60)
        installer("remove")
        installer("remove")
        assert not any(p.exists() for p in (plist, helper, helper.parent, sock, runtime / (label + ".lock")))
        assert subprocess.run(["/bin/launchctl", "print", service], capture_output=True).returncode != 0
        assert all(stat.S_IMODE(p.stat().st_mode) == mode for p, mode in parent_modes.items())
        print("PASS: clean installation, signature rejection, toggle, service restart, rollback, removal, and unchanged shared directory modes")
    finally:
        subprocess.run(["/bin/launchctl", "bootout", service], capture_output=True)
        subprocess.run(["/usr/bin/defaults", "delete", label], capture_output=True)
