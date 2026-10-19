import Foundation

struct OutputDeviceItem: Identifiable, Equatable {
    let id: String
    let name: String
    let iconSystemName: String
    let isSystemDefault: Bool
    let audioDeviceID: UInt32?

    init(
        id: String,
        name: String,
        iconSystemName: String,
        isSystemDefault: Bool = false,
        audioDeviceID: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.isSystemDefault = isSystemDefault
        self.audioDeviceID = audioDeviceID
    }
}
