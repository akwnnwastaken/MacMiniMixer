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

extension OutputDeviceItem {
    static let mockDevices: [OutputDeviceItem] = [
        OutputDeviceItem(
            id: "mock:macbook-speakers",
            name: "MacBook Speakers",
            iconSystemName: "macbook",
            isSystemDefault: true
        ),
        OutputDeviceItem(id: "mock:airpods-pro", name: "AirPods Pro", iconSystemName: "airpodspro"),
        OutputDeviceItem(id: "mock:studio-display", name: "Studio Display", iconSystemName: "display"),
        OutputDeviceItem(id: "mock:hdmi-output", name: "HDMI Output", iconSystemName: "cable.connector")
    ]
}
