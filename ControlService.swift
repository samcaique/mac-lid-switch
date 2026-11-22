import Foundation
import Darwin

struct ServiceReply: Decodable {
    let enabled: Bool?
    let error: String?
    let code: String?
}

enum ControlServiceError: LocalizedError {
    case cancelled
    case unavailable
    case untrustedService
    case invalidResponse
    case accessDenied
    case unrecognizedSetting
    case rejected(String)
    case installationFailed(String)
    case missingHelper

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Setup was cancelled. Your logo setting has not changed."
        case .unavailable:
            return "The logo service is unavailable. Set up access to reconnect."
        case .untrustedService:
            return "Lid Switch could not verify its system service. Please set up access again."
        case .accessDenied:
            return "Use the Mac account that set up Lid Switch."
        case .unrecognizedSetting:
            return "Unknown light setting. Click to choose On or Off."
        case .invalidResponse:
            return "The logo service returned an unexpected response. Please try again."
        case .rejected(let message):
            return message
        case .installationFailed(let message):
            return message.isEmpty ? "macOS could not finish setting up Lid Switch." : "macOS could not finish setting up Lid Switch. \(message)"
        case .missingHelper:
            return "The app’s system service is missing. Please restore the complete Lid Switch app."
        }
    }
}

enum ControlService {
    private static let label = "org.lidswitch.control"
    private static let socketPath = "/var/run/org.lidswitch.control.sock"
    private static let helperPath = "/Library/Application Support/org.lidswitch.control/LidSwitchHelper"
    private static let plistPath = "/Library/LaunchDaemons/org.lidswitch.control.plist"

    static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPath)
            && FileManager.default.fileExists(atPath: plistPath)
    }

    static var hasRemovableFiles: Bool {
        [helperPath, plistPath].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Call off the main thread. The helper alone reads and writes the root preference.
    static func request(_ action: String) throws -> Bool {
        guard ["status", "on", "off"].contains(action) else {
            throw ControlServiceError.rejected("The requested logo action is not supported.")
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlServiceError.unavailable }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw ControlServiceError.unavailable
        }
        var suppressBrokenPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressBrokenPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlServiceError.unavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == EACCES || errno == EPERM { throw ControlServiceError.accessDenied }
            throw ControlServiceError.unavailable
        }

        var peerUser = uid_t.max
        var peerGroup = gid_t.max
        guard getpeereid(descriptor, &peerUser, &peerGroup) == 0, peerUser == 0 else {
            throw ControlServiceError.untrustedService
        }

        let bytes = Array((action + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlServiceError.unavailable }
            sent += count
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while response.count < 4096 {
            let count = Darwin.recv(descriptor, &buffer, min(buffer.count, 4096 - response.count), 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlServiceError.unavailable }
            response.append(contentsOf: buffer.prefix(count))
            if let newline = response.firstIndex(of: 10) {
                let line = response.prefix(upTo: newline)
                guard let reply = try? JSONDecoder().decode(ServiceReply.self, from: Data(line)) else {
                    throw ControlServiceError.invalidResponse
                }
                // Previously installed helpers reported this condition as text only.
                if reply.code == "unrecognizedSetting" ||
                    (reply.code == nil && reply.error == "The logo uses an unrecognized setting. Choose On or Off to reset it.") {
                    throw ControlServiceError.unrecognizedSetting
                }
                if let message = reply.error {
                    throw ControlServiceError.rejected(String(message.prefix(600)))
                }
                guard let enabled = reply.enabled else { throw ControlServiceError.invalidResponse }
                return enabled
            }
        }
        throw ControlServiceError.invalidResponse
    }

    static func waitForStartup() throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while true {
            do { return try request("status") }
            catch ControlServiceError.unavailable where ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    /// Installs a narrow, root-owned service after macOS obtains administrator consent.
    /// It never receives or stores the administrator password.
    static func install() throws {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/LidSwitchHelper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ControlServiceError.missingHelper
        }
        try verifyHelper(at: helperURL)
        let userID = getuid()
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperPath, String(userID)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
            "ProcessType": "Background"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        let encodedPlist = plistData.base64EncodedString()
        let arguments = ["install", helperURL.path, BuildTrust.helperRequirement, String(userID), encodedPlist]
        try runInstaller(arguments, prompt: "Allow Lid Switch to install its background control for password-free switching.")
    }

    // Check before prompting. The installer repeats this check on the private
    // copy it will actually install, closing the gap between check and use.
    static func verifyHelper(at url: URL) throws {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", "--strict", "--all-architectures", "-R", "=" + BuildTrust.helperRequirement, url.path]
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            throw ControlServiceError.rejected("The control helper failed signature verification. Restore the complete app and try again.")
        }
    }

    static func uninstall() throws {
        try runInstaller(["remove"], prompt: "Allow Lid Switch to remove its background control.")
    }

    private static func runInstaller(_ arguments: [String], prompt: String) throws {
        // The lock is only held during setup or removal, never while toggling.
        let invocation = ["/usr/bin/lockf", "-t", "10", "/private/var/run/org.lidswitch.control.setup-lock",
                          "/bin/sh", "-c", BuildTrust.installer, "LidSwitchInstaller"] + arguments
        try runAuthorized(invocation.map(shellQuote).joined(separator: " "), prompt: prompt)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func runAuthorized(_ script: String, prompt: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptLiteral(script)) with administrator privileges with prompt \(appleScriptLiteral(prompt))"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw ControlServiceError.installationFailed(error.localizedDescription)
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.contains("(-128)") { throw ControlServiceError.cancelled }
            throw ControlServiceError.installationFailed(String(message.suffix(800)))
        }
    }
}
