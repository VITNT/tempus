import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Something Tempus can record: a display, a window, or a camera.
struct CaptureSource: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        case camera(String)
    }

    var target: Target
    var label: String
    var pixelWidth: Int
    var pixelHeight: Int
    var isPrimary = false
    /// Windows: used to find the window again if its ID changes.
    var bundleID: String?
    var windowTitle: String?

    var id: String {
        switch target {
        case .display(let id): "display-\(id)"
        case .window(let id): "window-\(id)"
        case .camera(let id): "camera-\(id)"
        }
    }

    var kind: SourceKind {
        switch target {
        case .display: .display
        case .window: .window
        case .camera: .camera
        }
    }

    var systemImage: String {
        switch kind {
        case .display: "display"
        case .window: "macwindow"
        case .camera: "web.camera"
        }
    }

    var detail: String {
        switch kind {
        case .display: "\(isPrimary ? "Main display" : "Display") · \(pixelWidth)×\(pixelHeight)"
        case .window: "Window · \(pixelWidth)×\(pixelHeight)"
        case .camera: "Camera"
        }
    }
}

enum SourceCatalog {
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must use System Settings.
    @discardableResult
    static func requestScreenAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings(for kind: SourceKind) {
        let pane = kind == .camera ? "Privacy_Camera" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func cameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Displays (main first), then on-screen app windows. Tempus's own windows are left out.
    static func screenSources() async throws -> [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let mainDisplay = CGMainDisplayID()
        var sources: [CaptureSource] = content.displays.map { display in
            let size = pixelSize(of: SCContentFilter(display: display, excludingWindows: []))
            let isPrimary = display.displayID == mainDisplay
            return CaptureSource(
                target: .display(display.displayID),
                label: displayName(display.displayID) ?? "Display \(display.displayID)",
                pixelWidth: size.width, pixelHeight: size.height, isPrimary: isPrimary)
        }
        sources.sort { $0.isPrimary && !$1.isPrimary }

        let ownBundle = Bundle.main.bundleIdentifier
        let windows = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width >= 50, window.frame.height >= 50 else { return false }
            guard window.owningApplication?.bundleIdentifier != ownBundle else { return false }
            let title = window.title ?? ""
            let app = window.owningApplication?.applicationName ?? ""
            return !(title.isEmpty && app.isEmpty)
        }
        for window in windows {
            let title = window.title ?? ""
            let app = window.owningApplication?.applicationName ?? ""
            let label = switch (app.isEmpty, title.isEmpty) {
            case (false, false): "\(app) — \(title)"
            case (false, true): app
            default: title
            }
            let size = pixelSize(of: SCContentFilter(desktopIndependentWindow: window))
            sources.append(CaptureSource(
                target: .window(window.windowID), label: label,
                pixelWidth: size.width, pixelHeight: size.height,
                bundleID: window.owningApplication?.bundleIdentifier, windowTitle: window.title))
        }
        return sources
    }

    static func cameras() -> [CaptureSource] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        return discovery.devices.map { device in
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return CaptureSource(target: .camera(device.uniqueID), label: device.localizedName,
                                 pixelWidth: Int(dimensions.width), pixelHeight: Int(dimensions.height))
        }
    }

    /// Resolves a fresh content filter. Windows are matched by ID, then by app
    /// and title, so a window that was recreated can still be found.
    static func filter(for source: CaptureSource) async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw hasScreenAccess ? error : TempusError.screenAccessDenied
        }
        switch source.target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw TempusError.sourceUnavailable(source.label)
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        case .window(let id):
            let match = content.windows.first { $0.windowID == id }
                ?? content.windows.first { $0.owningApplication?.bundleIdentifier == source.bundleID && $0.title == source.windowTitle && $0.windowLayer == 0 }
            guard let window = match else { throw TempusError.sourceUnavailable(source.label) }
            return SCContentFilter(desktopIndependentWindow: window)
        case .camera:
            preconditionFailure("Cameras don't use ScreenCaptureKit")
        }
    }

    nonisolated static func pixelSize(of filter: SCContentFilter) -> (width: Int, height: Int) {
        let scale = CGFloat(filter.pointPixelScale)
        return (Int((filter.contentRect.width * scale).rounded()), Int((filter.contentRect.height * scale).rounded()))
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName
    }
}
