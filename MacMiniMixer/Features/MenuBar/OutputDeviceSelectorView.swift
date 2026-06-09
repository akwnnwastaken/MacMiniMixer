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
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background(rowBackground(isSelected: device.id == selectedDeviceID))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(device.name))
                .accessibilityHint(Text("Switch system output to this device"))
                .accessibilityAddTraits(device.id == selectedDeviceID ? .isSelected : [])
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppConstants.Layout.cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                )
        )
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

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, lineWidth: 1)
            )
    }
}
