final class MockOutputDeviceController: OutputDeviceControlling {
    private(set) var selectedDeviceID: OutputDeviceItem.ID?
    private let shouldSucceed: Bool

    init(shouldSucceed: Bool = true) {
        self.shouldSucceed = shouldSucceed
    }

    func setDefaultOutputDevice(_ device: OutputDeviceItem) -> Bool {
        guard shouldSucceed else {
            return false
        }

        selectedDeviceID = device.id
        return true
    }
}
