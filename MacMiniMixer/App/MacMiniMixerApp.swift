import SwiftUI

@main
struct MacMiniMixerApp: App {
    @StateObject private var mixerViewModel: MixerViewModel

    init() {
        let applicationLister = WorkspaceApplicationLister()
        let audioController = PreviewAudioStateController()
        let outputDeviceLister = CoreAudioOutputDeviceLister()
        let outputDeviceController = CoreAudioOutputDeviceController()
        let systemVolumeReader = CoreAudioSystemVolumeReader()
        let systemVolumeController = CoreAudioSystemVolumeController()
        let processTapTester = CoreAudioProcessTapTester()
        let processTapReplayProbe = CoreAudioProcessTapReplayProbe()
        // Product Real session manager. `maxConcurrentLiveSessions` is nil (owner decision: no
        // app-count limit), so this manager admits every session the product start path requests.
        let processTapLiveController = ProcessTapLiveSessionManager(
            maxSessions: AppConstants.maxConcurrentLiveSessions,
            controllerFactory: { CoreAudioProcessTapLiveController() }
        )
        let twoAppReadinessTester = CoreAudioProcessTapTwoAppReadinessTester()
        let helperProcessAudioProbe = CoreAudioProcessTapCandidateAudioProbe()
        let processLister = SystemProcessLister()
        let appAudioTargetResolver = HelperAudioTargetResolver(
            processLister: processLister,
            helperProcessAudioProbe: helperProcessAudioProbe
        )

        _mixerViewModel = StateObject(
            wrappedValue: { () -> MixerViewModel in
                let viewModel = MixerViewModel(
                    applicationLister: applicationLister,
                    audioController: audioController,
                    outputDeviceLister: outputDeviceLister,
                    outputDeviceController: outputDeviceController,
                    systemVolumeReader: systemVolumeReader,
                    systemVolumeController: systemVolumeController,
                    processTapTester: processTapTester,
                    processTapReplayProbe: processTapReplayProbe,
                    processTapLiveController: processTapLiveController,
                    twoAppReadinessTester: twoAppReadinessTester,
                    helperProcessAudioProbe: helperProcessAudioProbe,
                    appAudioTargetResolver: appAudioTargetResolver,
                    processLister: processLister
                )
                // Real app control is always on in the shipped app (owner decision). Nothing is
                // captured here: a session still only starts when the user moves an eligible row's
                // slider or mute.
                viewModel.setExperimentalRealAppControlEnabled(AppConstants.realAppControlEnabledAtLaunch)
                return viewModel
            }()
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
