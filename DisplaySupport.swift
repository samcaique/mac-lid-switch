import Foundation

enum DisplaySupport {
    private struct Profile: Decodable {
        let SPDisplaysDataType: [Adapter]
    }

    private struct Adapter: Decodable {
        let spdisplays_ndrvs: [Display]?
    }

    private struct Display: Decodable {
        let spdisplays_display_type: String?
        let spdisplays_connection_type: String?
    }

    static func currentMacHasIlluminatedLid() throws -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPDisplaysDataType", "-json"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return try hasIlluminatedLid(in: data)
    }

    static func hasIlluminatedLid(in data: Data) throws -> Bool {
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        return profile.SPDisplaysDataType.contains { adapter in
            (adapter.spdisplays_ndrvs ?? []).contains { display in
                guard let type = display.spdisplays_display_type?.lowercased() else { return false }
                if type == "spdisplays_built-in-proled-xdr" { return true }
                return display.spdisplays_connection_type == "spdisplays_internal" &&
                    type.replacingOccurrences(of: "-", with: " ").contains("proled xdr")
            }
        }
    }
}
