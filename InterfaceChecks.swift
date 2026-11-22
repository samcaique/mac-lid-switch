import AppKit
import Foundation

@main
@MainActor
struct InterfaceChecks {
    static func waitFor(_ description: String, until ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !ready() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, description)
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    static func main() async throws {
        _ = NSApplication.shared
        let states: [LightIconState] = [.on, .off, .unknown]
        let icons = states.compactMap { $0.menuImage() }
        precondition(icons.count == 3 && icons.allSatisfy { $0.isTemplate })
        precondition(Set(icons.compactMap { $0.tiffRepresentation }).count == 3)
        precondition(LightIconState(enabled: true, connected: true, supported: true) == .on)
        precondition(LightIconState(enabled: false, connected: true, supported: true) == .off)
        precondition(LightIconState(enabled: nil, connected: true, supported: true) == .unknown)
        precondition(LightIconState(enabled: false, connected: false, supported: true) == .unknown)
        let domain = CommandLine.arguments[1]
        precondition(domain.hasPrefix("org.lidswitch.control.test."))
        let socket = CommandLine.arguments[2]
        let defaults = UserDefaults(suiteName: domain)!
        let key = "LEBacklightMode"
        var panelAvailable = false
        let model = LightModel { panelAvailable }
        try await waitFor("Missing built-in panel") { !model.busy && !model.supported }
        model.toggle()
        precondition(!model.busy && !model.connected)

        panelAvailable = true
        model.displayMayHaveChanged()
        try await waitFor("Panel available after wake") { model.supported && model.enabled == true }
        model.toggle()
        try await waitFor("Ordinary turn off") { !model.busy && model.enabled == false }

        defaults.set(7, forKey: key)
        precondition(defaults.synchronize())
        model.refresh()
        try await waitFor("Unknown state with a reachable helper") { model.connected && model.enabled == nil }
        precondition(!model.showingChoice && model.error == nil)
        model.toggle()
        precondition(model.showingChoice && !model.busy)
        model.showingChoice = false
        precondition(defaults.integer(forKey: key) == 7)
        model.toggle()
        model.choose(true)
        try await waitFor("Explicit recovery to automatic") { !model.busy && model.enabled == true }
        _ = defaults.synchronize()
        precondition(defaults.object(forKey: key) == nil)

        defaults.set("unknown", forKey: key)
        precondition(defaults.synchronize())
        model.toggle()
        try await waitFor("Preference changed since last refresh") { model.showingChoice && !model.busy }
        model.choose(false)
        try await waitFor("Explicit recovery to off") { !model.busy && model.enabled == false }

        // Denied access must not trigger helper setup or overwrite another account's registration.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: socket)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket) }
        model.refresh()
        try await waitFor("Access denied") { !model.connected && model.enabled == nil }
        model.toggle()
        try await waitFor("Wrong account guidance") { !model.busy }
        precondition(model.message == ControlServiceError.accessDenied.localizedDescription && model.error == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket)
        model.refresh()
        try await waitFor("Restored access") { model.connected && model.enabled == false }

        let reopened = LightModel { true }
        try await waitFor("Relaunch reads the confirmed setting") { reopened.enabled == false }
        reopened.toggle()
        try await waitFor("Ordinary turn on") { !reopened.busy && reopened.enabled == true }
        print("PASS: button, cancelled choice, explicit recovery both ways, display redetection, account access and relaunch")
    }
}
