import SwiftUI

@main
struct MacMiniMixerApp: App {
    @StateObject private var mixerViewModel: MixerViewModel

    init() {
        let applicationLister = WorkspaceApplicationLister()
        let audioController = MockAudioController()
        let outputDeviceLister = CoreAudioOutputDeviceLister()
        let outputDeviceController = CoreAudioOutputDeviceController()
        let systemVolumeReader = CoreAudioSystemVolumeReader()
        let systemVolumeController = CoreAudioSystemVolumeController()
        let processTapTester = CoreAudioProcessTapTester()
        let processTapReplayProbe = CoreAudioProcessTapReplayProbe()
        let processTapLiveController = CoreAudioProcessTapLiveController()

        _mixerViewModel = StateObject(
            wrappedValue: MixerViewModel(
                applicationLister: applicationLister,
                audioController: audioController,
                outputDeviceLister: outputDeviceLister,
                outputDeviceController: outputDeviceController,
                systemVolumeReader: systemVolumeReader,
                systemVolumeController: systemVolumeController,
                processTapTester: processTapTester,
                processTapReplayProbe: processTapReplayProbe,
                processTapLiveController: processTapLiveController
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(viewModel: mixerViewModel)
        } label: {
            Label(
                AppConstants.appTitle,
                systemImage: mixerViewModel.isProcessTapLiveControlActive ? "waveform.circle.fill" : "slider.horizontal.3"
            )
        }
        .menuBarExtraStyle(.window)
    }
}
