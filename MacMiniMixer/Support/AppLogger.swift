import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.example.MacMiniMixer"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let processTap = Logger(subsystem: subsystem, category: "processTap")
    static let helperResolution = Logger(subsystem: subsystem, category: "helperResolution")
    static let cleanup = Logger(subsystem: subsystem, category: "cleanup")
}
