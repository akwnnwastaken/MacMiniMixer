import Foundation

protocol OutputDeviceListing {
    func listOutputDevices() -> [OutputDeviceItem]
}
