import AppKit

// A third state keeps startup, unsupported hardware, and a lost connection
// visually distinct from a confirmed off setting.
enum LightIconState: String, CaseIterable {
    case on, off, unknown

    init(enabled: Bool?, connected: Bool, supported: Bool) {
        guard connected, supported, let enabled else { self = .unknown; return }
        self = enabled ? .on : .off
    }

    var description: String {
        switch self {
        case .on: return "Logo light on"
        case .off: return "Logo light off"
        case .unknown: return "Logo light status unavailable"
        }
    }

    func dockImage() -> NSImage? {
        let name: String
        switch self {
        case .on: name = "DockOn"
        case .off: name = "DockOff"
        case .unknown: name = "LidSwitch"
        }
        let ext = self == .unknown ? "icns" : "png"
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return NSImage(contentsOf: url)
    }

    func menuImage() -> NSImage? {
        if self == .unknown {
            return NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: description)
        }
        // A monochrome template follows the user's menu bar appearance.
        let size = NSSize(width: 19, height: 19)
        let icon = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.25)
            context.addPath(CGPath(roundedRect: CGRect(x: 1.5, y: 5, width: 16, height: 11), cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.strokePath()
            context.fill(CGRect(x: 0, y: 2.5, width: 19, height: 1.3))
            let light = CGRect(x: 7.25, y: 8, width: 4.5, height: 4.5)
            if self == .on { context.fillEllipse(in: light) }
            else { context.strokeEllipse(in: light.insetBy(dx: 0.4, dy: 0.4)) }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = description
        return icon
    }
}
