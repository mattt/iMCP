import Foundation
import OSLog

/// Logging configuration following Apple's recommended practices
extension Logger {
    /// Using bundle identifier as recommended by Apple for a unique identifier
    private static var subsystem = Bundle.main.bundleIdentifier ?? "com.loopwork.iMCP"

    /// Server-related logs including connection management and state changes
    static let server = Logger(subsystem: subsystem, category: "server")

    /// Service-related logs for various system services (Calendar, Contacts, etc.)
    static func service(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: "services.\(name)")
    }
    
    /// Service-related logs for various system services (Calendar, Contacts, etc.)
    static func integration(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: "integrations.\(name)")
    }
}
