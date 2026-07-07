import Foundation
import OSLog

enum AppLogger {
    // Fallback subsystem used only when `Bundle.main.bundleIdentifier` is nil (e.g. some
    // tooling/test contexts); a project-specific id rather than a `com.example.*` placeholder.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.akwnnwastaken.MacMiniMixer"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let processTap = Logger(subsystem: subsystem, category: "processTap")
    static let helperResolution = Logger(subsystem: subsystem, category: "helperResolution")
    static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
}
