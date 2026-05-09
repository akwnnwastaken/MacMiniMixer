import Foundation

struct MockOutputDeviceLister: OutputDeviceListing {
    func listOutputDevices() -> [OutputDeviceItem] {
        OutputDeviceItem.mockDevices
    }
}
