import getpass, tempfile, json, os, pathlib, shutil, socket, subprocess, time, uuid
root = pathlib.Path(__file__).parent
suffix = uuid.uuid4().hex[:8]
test_dir = pathlib.Path(tempfile.mkdtemp(dir='/private/tmp', prefix='ls-test-'))
domain = 'org.lidswitch.control.test.' + suffix
socket_path = str(test_dir / 'service.sock')
lock_path = str(test_dir / 'service.lock')
source = (root / 'Helper.swift').read_text()
replacements = {
    '"/var/run/org.lidswitch.control.sock"': json.dumps(socket_path),
    '"/var/run/org.lidswitch.control.lock"': json.dumps(lock_path),
    '"com.apple.CoreBrightness"': json.dumps(domain),
    '"HOME": "/var/root"': '"HOME": ' + json.dumps(str(pathlib.Path.home())),
    '"USER": "root", "LOGNAME": "root"': '"USER": ' + json.dumps(getpass.getuser()) + ', "LOGNAME": ' + json.dumps(getpass.getuser()),
    'guard geteuid() == 0 else': 'guard geteuid() == getuid() else',
    'stat("/private/var/run", &parentInfo)': 'stat(' + json.dumps(str(test_dir)) + ', &parentInfo)',
    'parentInfo.st_uid == 0': 'parentInfo.st_uid == getuid()',
    'lockInfo.st_uid == 0': 'lockInfo.st_uid == getuid()',
    'chown(socketPath, authorizedUID, 0)': 'chown(socketPath, authorizedUID, getgid())',
}
for old, new in replacements.items():
    assert source.count(old) == 1, old
    source = source.replace(old, new)
assert 'com.apple.CoreBrightness' not in source
swift = test_dir / 'HelperTest.swift'
exe = test_dir / 'HelperTest'
swift.write_text(source)
subprocess.run(['/Library/Developer/CommandLineTools/usr/bin/swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macosx13.0', '-sdk', '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk', str(swift), '-o', str(exe)], check=True)
process = subprocess.Popen([str(exe), str(os.getuid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
checks = []
def check(label, value):
    assert value, label
    checks.append(label)
def call(request, shutdown=False):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(30)
    client.connect(socket_path)
    client.sendall(request)
    if shutdown: client.shutdown(socket.SHUT_WR)
    data = b''
    while b'\n' not in data:
        chunk=client.recv(1024)
        if not chunk: break
        data += chunk
    client.close()
    return json.loads(data)
def defaults(*args):
    return subprocess.run(['/usr/bin/defaults', *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout
try:
    for i in range(200):
        if os.path.exists(socket_path): break
        if process.poll() is not None: raise RuntimeError(process.stderr.read().decode())
        time.sleep(.025)
    check('Socket mode is 0600', (os.stat(socket_path).st_mode & 0o777) == 0o600)
    check('Socket belongs to allowed UID', os.stat(socket_path).st_uid == os.getuid())
    check('Missing preference reports on', call(b'status\n') == {'enabled': True})
    check('Off applies and confirms false', call(b'off\n') == {'enabled': False})
    check('Off writes integer zero', defaults('read', domain, 'LEBacklightMode').strip() == '0')
    check('Off state persists on status', call(b'status\n') == {'enabled': False})
    check('On deletes preference and confirms true', call(b'on\n') == {'enabled': True})
    check('Repeated on is idempotent', call(b'on\n') == {'enabled': True})
    check('Unknown operation rejected', 'error' in call(b'shell\n'))
    check('Oversized request rejected', 'error' in call(b'x'*32))
    check('Incomplete request rejected', 'error' in call(b'stat', shutdown=True))
    check('Non UTF-8 request rejected', 'error' in call(b'\xff\n'))
    defaults('write', domain, 'LEBacklightMode', '-int', '7')
    check('Unknown integer rejects status', 'error' in call(b'status\n'))
    check('Explicit on recovers unknown integer', call(b'on\n') == {'enabled': True})
    defaults('write', domain, 'LEBacklightMode', '-string', 'weird')
    check('Unknown string rejects status', 'error' in call(b'status\n'))
    check('Explicit off recovers unknown string', call(b'off\n') == {'enabled': False})
    defaults('delete', domain, 'LEBacklightMode')
    defaults('write', domain, 'LEBacklightMode', '-bool', 'false')
    check('Boolean false is not treated as integer zero', 'error' in call(b'status\n'))
    check('Unknown key can be reset on', call(b'on\n') == {'enabled': True})
    started=time.monotonic()
    check('Idle client gets a bounded error', 'error' in call(b''))
    check('Idle client timeout is near 3 seconds', 2.5 < time.monotonic()-started < 5)
    check('Daemon remains usable after malformed and timeout requests', call(b'status\n') == {'enabled': True})
    print('Passed %d isolated helper integration checks.' % len(checks))
    for label in checks: print('  PASS '+label)
finally:
    process.terminate()
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
    subprocess.run(['/usr/bin/defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(test_dir)
