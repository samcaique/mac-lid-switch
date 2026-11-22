import Foundation
import CoreFoundation
import Darwin

// A deliberately narrow root service: its only operations are status, on, and off.
// The executable and launchd plist must be installed root:wheel and not writable
// by the client. The sole argument is the authorized local user's numeric UID.
private let socketPath = "/var/run/org.lidswitch.control.sock"
private let lockPath = "/var/run/org.lidswitch.control.lock"
private let domain = "com.apple.CoreBrightness"
private let preferenceKey = "LEBacklightMode"
private let maximumRequestBytes = 32

private enum HelperError: Error, LocalizedError {
    case message(String)
    case unrecognizedSetting
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .unrecognizedSetting: return "The logo uses an unrecognized setting. Choose On or Off to reset it."
        }
    }
}

private struct Reply: Encodable {
    var enabled: Bool?
    var error: String?
    var code: String?
}

private final class Capture {
    private let lock = NSLock()
    private var storage = Data()
    private var exceededLimit = false
    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 16_384)
            if chunk.isEmpty { break }
            lock.lock()
            if storage.count + chunk.count <= 1_048_576 { storage.append(chunk) }
            else { exceededLimit = true }
            lock.unlock()
        }
    }
    func result() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if exceededLimit { throw HelperError.message("The system preference response was too large.") }
        return storage
    }
}

private struct CommandResult {
    let status: Int32
    let output: Data
}

// There is no caller-controlled executable, argument, environment, or shell text.
private func defaults(_ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = arguments
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root",
        "USER": "root", "LOGNAME": "root", "LC_ALL": "C"
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let completed = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completed.signal() }
    do { try process.run() }
    catch { throw HelperError.message("Could not launch the system preference utility.") }

    let output = Capture()
    let errors = Capture()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global().async { output.drain(stdout.fileHandleForReading); readers.leave() }
    readers.enter()
    DispatchQueue.global().async { errors.drain(stderr.fileHandleForReading); readers.leave() }
    if completed.wait(timeout: .now() + 8) == .timedOut {
        if process.isRunning { process.terminate() }
        if completed.wait(timeout: .now() + 1) == .timedOut && process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        throw HelperError.message("The system preference utility did not respond in time.")
    }
    guard readers.wait(timeout: .now() + 2) == .success else {
        throw HelperError.message("Could not finish reading the system preference response.")
    }
    _ = try errors.result()
    return CommandResult(status: process.terminationStatus, output: try output.result())
}

private func preferences() throws -> [String: Any] {
    let result = try defaults(["export", domain, "-"])
    guard result.status == 0 else {
        throw HelperError.message("macOS could not read the logo illumination preference.")
    }
    let object: Any
    do { object = try PropertyListSerialization.propertyList(from: result.output, options: [], format: nil) }
    catch { throw HelperError.message("macOS returned an unreadable logo illumination preference.") }
    guard let dictionary = object as? [String: Any] else {
        throw HelperError.message("macOS returned an unexpected preference format.")
    }
    return dictionary
}

private func enabled(in dictionary: [String: Any]) throws -> Bool {
    guard let value = dictionary[preferenceKey] else { return true }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFNumberGetTypeID(), number.doubleValue == 0 else {
        throw HelperError.unrecognizedSetting
    }
    return false
}

private func perform(_ request: String) throws -> Bool {
    switch request {
    case "status":
        return try enabled(in: preferences())
    case "on":
        // Absence means Apple's automatic illumination behavior is already on.
        if try preferences()[preferenceKey] != nil {
            let result = try defaults(["delete", domain, preferenceKey])
            guard result.status == 0 else {
                throw HelperError.message("macOS could not turn logo illumination on.")
            }
        }
        guard try enabled(in: preferences()) else {
            throw HelperError.message("macOS did not confirm that illumination is on.")
        }
        return true
    case "off":
        let result = try defaults(["write", domain, preferenceKey, "-int", "0"])
        guard result.status == 0 else {
            throw HelperError.message("macOS could not turn logo illumination off.")
        }
        guard try !enabled(in: preferences()) else {
            throw HelperError.message("macOS did not confirm that illumination is off.")
        }
        return false
    default:
        throw HelperError.message("Unsupported request.")
    }
}

private func readRequest(_ fd: Int32) throws -> String {
    var bytes = [UInt8]()
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    while bytes.count < maximumRequestBytes {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw HelperError.message("The request timed out.") }
        let remaining = deadline - now
        var timeout = timeval(tv_sec: Int(remaining / 1_000_000_000),
                              tv_usec: Int32(max(1, (remaining % 1_000_000_000) / 1_000)))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw HelperError.message("Could not secure the request connection.")
        }
        var byte: UInt8 = 0
        let count = Darwin.recv(fd, &byte, 1, 0)
        if count == -1 && errno == EINTR { continue }
        guard count == 1 else { throw HelperError.message("Incomplete request.") }
        if byte == 10 {
            guard let request = String(bytes: bytes, encoding: .utf8) else {
                throw HelperError.message("Invalid request.")
            }
            return request
        }
        bytes.append(byte)
    }
    throw HelperError.message("The request was too long.")
}

private func sendReply(_ reply: Reply, to fd: Int32) {
    guard var data = try? JSONEncoder().encode(reply) else { return }
    data.append(10)
    data.withUnsafeBytes { rawBuffer in
        guard let start = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.send(fd, start.advanced(by: offset), rawBuffer.count - offset, 0)
            if written == -1 && errno == EINTR { continue }
            if written <= 0 { return }
            offset += written
        }
    }
}

private func handle(_ fd: Int32, authorizedUID: uid_t) {
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == authorizedUID else {
        sendReply(Reply(error: "This account is not authorized to control illumination."), to: fd)
        return
    }
    do { sendReply(Reply(enabled: try perform(readRequest(fd))), to: fd) }
    catch HelperError.unrecognizedSetting {
        sendReply(Reply(error: HelperError.unrecognizedSetting.localizedDescription, code: "unrecognizedSetting"), to: fd)
    } catch { sendReply(Reply(error: error.localizedDescription), to: fd) }
}

private func fail(_ message: String) -> Never {
    NSLog("Lid Switch helper: %@", message)
    FileHandle.standardError.write(Data(("Lid Switch helper: " + message + "\n").utf8))
    exit(1)
}

guard geteuid() == 0 else { fail("must run as root.") }
guard CommandLine.arguments.count == 2,
      let authorizedUID = uid_t(CommandLine.arguments[1]), authorizedUID > 0,
      getpwuid(authorizedUID) != nil else { fail("requires one valid non-root UID argument.") }

// macOS normally uses root:daemon 0775 for /private/var/run. Permit its
// trusted system groups, but reject world access or writable non-system groups.
// Also refuse a symlinked/unexpected lock file below this trusted parent.
var parentInfo = stat()
guard stat("/private/var/run", &parentInfo) == 0,
      parentInfo.st_uid == 0,
      parentInfo.st_mode & S_IFMT == S_IFDIR,
      parentInfo.st_mode & 0o002 == 0,
      parentInfo.st_mode & 0o020 == 0 || parentInfo.st_gid == 0 || parentInfo.st_gid == 1 else {
    fail("the socket directory is not secure.")
}
let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
guard lockFD >= 0 else { fail("cannot open the service lock.") }
var lockInfo = stat()
guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == 0,
      lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o077 == 0,
      flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { fail("another service is running or the lock is unsafe.") }

signal(SIGPIPE, SIG_IGN)
_ = umask(0o177)
let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
guard server >= 0 else { fail("cannot create the service socket.") }
_ = fcntl(server, F_SETFD, FD_CLOEXEC)
var oldInfo = stat()
if lstat(socketPath, &oldInfo) == 0 {
    guard oldInfo.st_mode & S_IFMT == S_IFSOCK,
          oldInfo.st_uid == 0 || oldInfo.st_uid == authorizedUID else {
        fail("the existing socket path is unsafe.")
    }
    guard unlink(socketPath) == 0 else { fail("cannot remove the old service socket.") }
} else if errno != ENOENT { fail("cannot inspect the service socket path.") }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let pathBytes = Array(socketPath.utf8CString)
guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path is too long.") }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
    for index in pathBytes.indices { buffer[index] = UInt8(bitPattern: pathBytes[index]) }
}
let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bound == 0,
      chown(socketPath, authorizedUID, 0) == 0,
      chmod(socketPath, 0o600) == 0,
      listen(server, 8) == 0 else {
    _ = unlink(socketPath)
    fail("cannot prepare the private service socket.")
}

while true {
    let client = Darwin.accept(server, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        fail("cannot accept a service connection.")
    }
    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
    autoreleasepool { handle(client, authorizedUID: authorizedUID) }
}
