import AppKit
import SwiftUI
import Combine

private struct LogoView: View {
    @ObservedObject var model: LightModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var lit: Bool { model.enabled == true }
    private var help: String {
        if model.busy { return "Updating logo illumination…" }
        if !model.supported { return model.message ?? LightModel.unsupportedMessage }
        if !model.connected { return model.message ?? "Click to set up the light. macOS will request administrator approval." }
        if model.enabled == nil { return "Choose whether the logo light is on or off." }
        return lit ? "Click to turn the Apple logo off" : "Click to turn the Apple logo on"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.20), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Button {
                model.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.84).opacity(lit ? 0.13 : 0))
                        .frame(width: 126, height: 126)
                        .blur(radius: 35)
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(white: 0.65), lineWidth: 3)
                            .frame(width: 122, height: 78)
                        Capsule()
                            .fill(Color(white: 0.6))
                            .frame(width: 134, height: 4)
                            .offset(y: 44)
                        Circle()
                            .fill(lit ? Color(white: 0.99) : Color(white: model.enabled == nil ? 0.45 : 0.035))
                            .overlay(Circle().strokeBorder(Color(white: 0.54), lineWidth: 1.5))
                            .frame(width: 27, height: 27)
                            .shadow(color: lit ? .white.opacity(0.8) : .clear, radius: 8)
                    }
                        .scaleEffect(hovering && !model.busy ? 1.025 : 1)
                        .offset(y: -7)
                }
                .frame(width: 280, height: 252)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || !model.supported)
            .help(help)
            .accessibilityLabel(help)
            .keyboardShortcut(.space, modifiers: [])
            .onHover { hovering = $0 }
            .contextMenu {
                Button("About Lid Switch") { model.showingInfo = true }
                if model.connected || ControlService.hasRemovableFiles {
                    Button("Remove Background Control…") { model.showingRemoval = true }
                }
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            VStack {
                Spacer()
                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                } else if model.busy {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else {
                    Circle()
                        .fill(model.connected ? (lit ? Color(red: 0.57, green: 0.82, blue: 0.67) : Color(white: 0.35)) : Color(white: 0.35))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.bottom, 27)
            .allowsHitTesting(false)
        }
        .frame(width: 280, height: 280)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.enabled)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .alert("Lid Switch", isPresented: $model.showingInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Click the light in the window or the menu bar to turn the lid logo on or off.\n\nOne-time macOS approval enables password-free switching. Your setting stays after the app closes.\n\nChoose Remove Background Control from the Lid Switch menu to uninstall the helper.")
        }
        .alert("Couldn’t change the light", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "Please try again.") }
        .alert("Choose a light setting", isPresented: $model.showingChoice) {
            Button("Turn On") { model.choose(true) }
            Button("Turn Off") { model.choose(false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Lid Switch could not recognize the current setting. Turn On restores automatic illumination.")
        }
        .alert("Remove background control?", isPresented: $model.showingRemoval) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { model.removeHelper() }
        } message: { Text("Your light keeps its current setting. macOS will ask for approval to remove the helper. Then move this app to the Trash to uninstall it.") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var model: LightModel!
    private var statusItem: NSStatusItem!
    private var observers = Set<AnyCancellable>()
    private var dockIcons: [LightIconState: NSImage] = [:]
    private var barIcons: [LightIconState: NSImage] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func showMainWindow() {
        guard window == nil else { return }
        let app = NSApplication.shared
        model = LightModel()
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lid Switch", action: #selector(showInfo), keyEquivalent: "")
        appMenu.addItem(.separator())
        let removal = appMenu.addItem(withTitle: "Remove Background Control…", action: #selector(confirmRemoval), keyEquivalent: "")
        removal.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lid Switch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Lid Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        app.mainMenu = mainMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 280), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Lid Switch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: LogoView(model: model))
        configureIcons()
        window.center()
        window.setFrameAutosaveName("LidSwitchMinimalWindow")
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

    }

    private func configureIcons() {
        for state in LightIconState.allCases {
            dockIcons[state] = state.dockImage()
            barIcons[state] = state.menuImage()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.$enabled.combineLatest(model.$connected, model.$supported)
            .map { LightIconState(enabled: $0, connected: $1, supported: $2) }
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                NSApp.applicationIconImage = self.dockIcons[state]
                NSApp.dockTile.display()
                let button = self.statusItem.button
                button?.image = self.barIcons[state]
                button?.toolTip = state.description + " · Click to control, right-click for options"
                button?.setAccessibilityLabel(state.description)
                button?.setAccessibilityHelp("Click to control the light. Right-click for Open and Quit.")
            }
            .store(in: &observers)
        model.$error.compactMap { $0 }.sink { [weak self] _ in self?.revealWindow() }
            .store(in: &observers)
        model.$showingChoice.filter { $0 }.sink { [weak self] _ in self?.revealWindow() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.displayMayHaveChanged() }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.displayMayHaveChanged() }
            .store(in: &observers)
    }

    @objc private func handleStatusClick() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let button = statusItem.button else { return }
            let menu = NSMenu()
            let show = menu.addItem(withTitle: "Open Lid Switch", action: #selector(revealWindow), keyEquivalent: "")
            show.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Lid Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
            return
        }
        if !model.connected || !model.supported { revealWindow() }
        model.toggle()
    }

    @objc private func revealWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(confirmRemoval) else { return true }
        return !model.busy && (model.connected || ControlService.hasRemovableFiles)
    }

    @objc private func confirmRemoval() {
        window.makeKeyAndOrderFront(nil)
        model.showingRemoval = true
    }

    @objc private func showInfo() { revealWindow(); model.showingInfo = true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealWindow()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.startRefreshing()
        model?.refresh()
    }
    func applicationDidResignActive(_ notification: Notification) { model?.startRefreshing() }
}

@main
struct LidSwitchApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--preview"), let index = arguments.firstIndex(of: "--render"), arguments.indices.contains(index + 1) {
            let renderer = ImageRenderer(content: LogoView(model: LightModel()))
            renderer.scale = 2
            if let cgImage = renderer.cgImage {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
            }
            return
        }
        let media = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".lid-switch-install-media")
        if FileManager.default.fileExists(atPath: media.path) {
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Drag Lid Switch into Applications"
            alert.informativeText = "Then open Lid Switch from Applications to set up the light."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        delegate.showMainWindow()
        withExtendedLifetime(delegate) { app.run() }
    }
}
