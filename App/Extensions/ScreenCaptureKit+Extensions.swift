import ScreenCaptureKit

// MARK: - Screen Capture Content Type

enum ScreenCaptureContentType: String, Hashable, CaseIterable {
    static let `default`: ScreenCaptureContentType = .display

    case display = "display"
    case window = "window"
    case application = "application"
}

// MARK: - Screen Capture Quality

enum ScreenCaptureQuality: String, Hashable, CaseIterable {
    static let `default`: ScreenCaptureQuality = .medium

    case low = "low"
    case medium = "medium"
    case high = "high"
    case max = "max"

    var scaleFactor: CGFloat {
        switch self {
        case .low:
            return 0.5
        case .medium:
            return 0.75
        case .high:
            return 1.0
        case .max:
            return 2.0
        }
    }
}

// MARK: - Screen Capture Filter

enum ScreenCaptureFilter: String, Hashable, CaseIterable {
    static let `default`: ScreenCaptureFilter = .none

    case none = "none"
    case excludeDesktopWindows = "exclude-desktop"
    case onlyVisibleWindows = "only-visible"
    case excludeMenuBar = "exclude-menu-bar"

    func createContentFilter(with content: SCShareableContent) -> SCContentFilter {
        guard let display = content.displays.first else {
            return SCContentFilter()
        }

        switch self {
        case .none:
            return SCContentFilter()
        case .excludeDesktopWindows:
            let nonDesktopWindows = content.windows.filter {
                !($0.isOnScreen && $0.windowLayer == 0)
            }
            return SCContentFilter(display: display, including: nonDesktopWindows)
        case .onlyVisibleWindows:
            let visibleWindows = content.windows.filter { $0.isOnScreen }
            return SCContentFilter(display: display, including: visibleWindows)
        case .excludeMenuBar:
            let nonMenuBarWindows = content.windows.filter { $0.title?.contains("MenuBar") == true }
            return SCContentFilter(display: display, including: nonMenuBarWindows)
        }
    }
}

// MARK: - Screenshot Format

enum ScreenshotFormat: String, Hashable, CaseIterable {
    static let `default`: ScreenshotFormat = .png

    case png = "png"
    case jpeg = "jpeg"

    var mimeType: String {
        switch self {
        case .png:
            return "image/png"
        case .jpeg:
            return "image/jpeg"
        }
    }
}

// MARK: - ScreenCaptureKit Extensions

extension SCShareableContent {
    static func getAvailableContent() async throws -> SCShareableContent {
        return try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
    }
}

extension SCDisplay {
    var displayInfo: String {
        return "Display \(displayID): \(width)x\(height)"
    }
}

extension SCWindow {
    var windowInfo: String {
        return "Window: \(title ?? "Unknown") (\(frame.width)x\(frame.height))"
    }
}

extension SCRunningApplication {
    var applicationInfo: String {
        return "App: \(applicationName) (PID: \(processID))"
    }
}
