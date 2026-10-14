import SwiftUI

struct OutputDeviceSelectorView: View {
    let devices: [OutputDeviceItem]
    let selectedDeviceID: OutputDeviceItem.ID
    let selectDevice: (OutputDeviceItem.ID) -> Void
    let refreshDevices: () -> Void

    var body: some View {
        VStack(spacing: AppConstants.Layout.deviceRowSpacing) {
            ForEach(devices) { device in
                Button {
                    selectDevice(device.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: device.iconSystemName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(device.id == selectedDeviceID ? .blue : .secondary)
                            .frame(width: 18)

                        Text(device.name)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if device.isSystemDefault {
                            Text("Default")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(.quaternary.opacity(0.45))
                                )
                                .transition(.opacity)
                        }

                        Spacer()

                        if device.id == selectedDeviceID {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.blue)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: AppConstants.Layout.rowCornerRadius, style: .continuous))
                    .background(rowBackground(isSelected: device.id == selectedDeviceID))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(deviceSpokenLabel(device)))
                .accessibilityHint(Text("Switch system output to this device"))
                .accessibilityAddTraits(device.id == selectedDeviceID ? .isSelected : [])
            }
        }
        .padding(6)
        .platter()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Output devices"))
        .animation(.snappy(duration: 0.16), value: selectedDeviceID)
        .onAppear(perform: refreshDevices)
        .task {
            await runRefreshLoop()
        }
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(AppConstants.outputDeviceRefreshInterval * 1_000_000_000)
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                refreshDevices()
            }
        }
    }

    /// The row's explicit label replaces its children, so the visible "Default" badge is folded in.
    private func deviceSpokenLabel(_ device: OutputDeviceItem) -> String {
        device.isSystemDefault ? "\(device.name), system default" : device.name
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppConstants.Layout.rowCornerRadius, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}
