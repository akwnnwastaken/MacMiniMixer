protocol OutputDeviceControlling {
    @discardableResult
    func setDefaultOutputDevice(_ device: OutputDeviceItem) -> Bool
}
