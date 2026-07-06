import AppKit
import Foundation

enum MixerAppIcon {
    case systemSymbol(String)
    case image(NSImage)
}

struct MixerAppItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: MixerAppIcon
    let processIdentifier: Int32?
    var volume: Double
    var isMuted: Bool

    /// Coarse *candidate* check only: whether this row has a usable process id at all. It is **not**
    /// a guarantee that the app can actually be tapped — real Process Tap eligibility (a visible PID
    /// that maps to a Core Audio process object, or a resolvable audio helper for browser/web rows)
    /// is determined later by target resolution. Treat a true value as "worth attempting", not
    /// "confirmed tappable"; the name is kept for API stability.
    var isEligibleForExperimentalLiveControl: Bool {
        guard let processIdentifier else {
            return false
        }

        return processIdentifier > 0
    }

    var isLikelyAudioRelevant: Bool {
        let searchableText = "\(name) \(id)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        if Self.nonAudioAppKeywords.contains(where: searchableText.contains) {
            return false
        }

        return Self.audioRelevantAppKeywords.contains(where: searchableText.contains)
    }

    init(
        id: String,
        name: String,
        icon: MixerAppIcon,
        processIdentifier: Int32? = nil,
        volume: Double,
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.processIdentifier = processIdentifier
        self.volume = volume
        self.isMuted = isMuted
    }

    static func == (lhs: MixerAppItem, rhs: MixerAppItem) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.processIdentifier == rhs.processIdentifier &&
            lhs.volume == rhs.volume &&
            lhs.isMuted == rhs.isMuted
    }

    private static let audioRelevantAppKeywords = [
        "spotify",
        "music",
        "muzik",
        "safari",
        "chrome",
        "firefox",
        "arc",
        "brave",
        "edge",
        "opera",
        "browser",
        "chatgpt",
        "discord",
        "zoom",
        "teams",
        "facetime",
        "quicktime",
        "vlc",
        "iina",
        "tv",
        "podcast",
        "youtube",
        "twitch",
        "whatsapp",
        "telegram",
        "slack",
        "meet",
        "webex",
        "obs",
        "garageband",
        "logic",
        "ableton",
        "audacity",
        "reaper",
        "final cut",
        "premiere",
        "audition",
        "media",
        "player",
        "audio",
        "sound"
    ]

    private static let nonAudioAppKeywords = [
        "finder",
        "notes",
        "notlar",
        "pages",
        "xcode",
        "system settings",
        "sistem ayarlari",
        "settings",
        "preview",
        "calendar",
        "takvim",
        "reminders",
        "animsaticilar",
        "contacts",
        "kisiler",
        "mail",
        "terminal",
        "textedit",
        "numbers",
        "keynote"
    ]
}
