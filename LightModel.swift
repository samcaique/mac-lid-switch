import AppKit
import Combine

@MainActor
final class LightModel: ObservableObject {
    @Published var enabled: Bool?
    @Published var busy = true
    @Published var connected = false
    @Published var supported = true
    @Published var message: String?
    @Published var error: String?
    @Published var showingInfo = false
    @Published var showingRemoval = false
    @Published var showingChoice = false

    static let unsupportedMessage = "Requires a built-in PROLED XDR display."
    static let cancelledMessage = "Setup cancelled. Click to try again."
    static let disconnectedMessage = "Control unavailable. Click to reconnect."

    let renderingSnapshot: Bool
    private let detectDisplay: () throws -> Bool
    private let worker = DispatchQueue(label: "org.lidswitch.app.control", qos: .userInitiated)
    private var refreshTimer: Timer?
    private var refreshInFlight = false

    init(detectDisplay: @escaping () throws -> Bool = DisplaySupport.currentMacHasIlluminatedLid) {
        self.detectDisplay = detectDisplay
        let args = ProcessInfo.processInfo.arguments
        renderingSnapshot = args.contains("--snapshot-state") && args.contains("--render")
        if renderingSnapshot {
            busy = false
            supported = !args.contains("unsupported")
            connected = supported && !args.contains("setup") && !args.contains("cancelled")
            enabled = connected ? !args.contains("off") : nil
            if !supported { message = Self.unsupportedMessage }
            if args.contains("cancelled") { message = Self.cancelledMessage }
        } else {
            checkDisplay()
        }
    }

    private func checkDisplay() {
        busy = true
        worker.async { [weak self, detectDisplay] in
            let compatible = try? detectDisplay()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.supported = compatible == true
                if self.supported {
                    self.message = nil
                    self.refresh()
                } else {
                    self.connected = false
                    self.enabled = nil
                    self.message = compatible == nil ? "Couldn’t check the display. Reopen Lid Switch." : Self.unsupportedMessage
                }
                self.startRefreshing()
            }
        }
    }

    func displayMayHaveChanged() {
        guard !renderingSnapshot, !busy else { return }
        if supported { refresh() }
        else { checkDisplay() }
    }

    func startRefreshing() {
        refreshTimer?.invalidate()
        guard !renderingSnapshot else { return }
        let interval: TimeInterval = NSApp.isActive ? 5 : 20
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        guard supported, !renderingSnapshot, !busy, !refreshInFlight else { return }
        guard ControlService.helperInstalled else {
            if connected {
                connected = false
                enabled = nil
                message = Self.disconnectedMessage
            }
            return
        }
        refreshInFlight = true
        worker.async { [weak self] in
            let result = Result { try ControlService.request("status") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                if !self.busy { self.apply(result, userInitiated: false) }
            }
        }
    }

    func toggle() {
        guard !renderingSnapshot, supported, !busy else { return }
        if connected && enabled == nil {
            showingChoice = true
            return
        }
        let canSetUp = !connected
        changeLight {
            let current: Bool
            do { current = try ControlService.request("status") }
            catch ControlServiceError.unavailable where canSetUp {
                try ControlService.install()
                current = try ControlService.waitForStartup()
            }
            return try ControlService.request(current ? "off" : "on")
        }
    }

    func choose(_ on: Bool) {
        guard !renderingSnapshot, supported, !busy else { return }
        showingChoice = false
        changeLight { try ControlService.request(on ? "on" : "off") }
    }

    private func changeLight(_ operation: @escaping () throws -> Bool) {
        busy = true
        message = nil
        worker.async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.apply(result, userInitiated: true)
            }
        }
    }

    private func apply(_ result: Result<Bool, Error>, userInitiated: Bool) {
        switch result {
        case .success(let state):
            enabled = state
            connected = true
            message = nil
        case .failure(ControlServiceError.unrecognizedSetting):
            enabled = nil
            connected = true
            message = ControlServiceError.unrecognizedSetting.localizedDescription
            if userInitiated { showingChoice = true }
        case .failure(let failure):
            enabled = nil
            connected = false
            switch failure {
            case ControlServiceError.cancelled: message = Self.cancelledMessage
            case ControlServiceError.accessDenied: message = failure.localizedDescription
            default:
                message = Self.disconnectedMessage
                if userInitiated { error = failure.localizedDescription }
            }
        }
    }

    func removeHelper() {
        guard !renderingSnapshot, !busy else { return }
        busy = true
        showingInfo = false
        worker.async { [weak self] in
            let result = Result { try ControlService.uninstall() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success:
                    self.connected = false
                    self.enabled = nil
                    self.message = nil
                case .failure(ControlServiceError.cancelled):
                    break
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
