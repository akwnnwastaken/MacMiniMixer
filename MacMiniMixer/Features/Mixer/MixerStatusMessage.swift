import Foundation

struct MixerStatusMessage: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        case success
        case warning
    }

    let id: UUID
    let text: String
    let style: Style

    init(
        id: UUID = UUID(),
        text: String,
        style: Style
    ) {
        self.id = id
        self.text = text
        self.style = style
    }
}
