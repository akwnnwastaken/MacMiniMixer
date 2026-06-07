import Foundation

struct MixerStatusMessage: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        case success
        case warning
    }

    /// Optional inline action offered alongside a status message. Kept UI-framework free:
    /// the view maps each case to a button label and handler.
    enum Action: Equatable {
        case openSystemAudioRecordingSettings

        var label: String {
            switch self {
            case .openSystemAudioRecordingSettings:
                return "Open Settings"
            }
        }
    }

    let id: UUID
    let text: String
    let style: Style
    let action: Action?

    init(
        id: UUID = UUID(),
        text: String,
        style: Style,
        action: Action? = nil
    ) {
        self.id = id
        self.text = text
        self.style = style
        self.action = action
    }
}
