import Foundation

enum AppConstants {
    static let appTitle = "MacMiniMixer"
    static let volumeRange: ClosedRange<Double> = 0...100
    static let outputDeviceRefreshInterval: TimeInterval = 2
    static let systemVolumeRefreshInterval: TimeInterval = 1
    static let statusMessageAutoClearDelay: TimeInterval = 2.5
    static let processTapDiagnosticDuration: TimeInterval = 2.5
    static let processTapReplayProbeDuration: TimeInterval = 2.5
    static let processTapLiveControlMaxDuration: TimeInterval = 60
    static let processTapTwoAppReadinessDuration: TimeInterval = 10
    static let processTapLiveFadeInDuration: TimeInterval = 0.06
    static let processTapLiveFadeOutDuration: TimeInterval = 0.04
    static let processTapLivePrimingBufferCount = 2
    static let processTapReplayFallbackSampleRate: Double = 48_000
    static let processTapReplayBufferCount = 8
    static let processTapReplayBufferByteSize: UInt32 = 65_536
    static let processTapLevelMeterUpdateInterval: TimeInterval = 0.1
    static let defaultSystemOutputRestoreVolume: Double = 50

    enum Layout {
        static let panelWidth: CGFloat = 352
        static let panelPadding: CGFloat = 12
        static let panelSpacing: CGFloat = 9
        static let sectionSpacing: CGFloat = 8
        static let sectionPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 14
        static let panelCornerRadius: CGFloat = 22
        static let rowCornerRadius: CGFloat = 10
        static let rowSpacing: CGFloat = 8
        static let rowInnerSpacing: CGFloat = 5
        static let rowIconSize: CGFloat = 36
        static let rowIconImageArtworkSize: CGFloat = 31
        static let rowIconSymbolFrameSize: CGFloat = 36
        static let rowIconSymbolSize: CGFloat = 18
        static let rowIconMuteBadgeSize: CGFloat = 14
        static let rowLiveButtonSize: CGFloat = 24
        static let headerButtonSize: CGFloat = 28
        static let appNameWidth: CGFloat = 66
        static let volumeValueWidth: CGFloat = 28
        static let deviceRowSpacing: CGFloat = 2
        static let appRowApproxHeight: CGFloat = 48
        static let appListMinHeight: CGFloat = 56
        static let appListMaxHeight: CGFloat = 450
    }
}
