import Foundation

/// Owns the transient status-message auto-clear lifecycle for `MixerViewModel`: it schedules a
/// delayed clear, cancels the previous pending clear when a newer message is shown, and only clears
/// a message that is still the current one (so a stale timer never wipes a newer message).
///
/// The message value itself stays a `@Published` property on the view model; this controller only
/// owns the timing/task plumbing, reading and writing that property through injected closures. The
/// sleeper is injectable so tests drive the delay deterministically instead of sleeping for real.
@MainActor
final class MixerStatusMessageController {
    private var clearTask: Task<Void, Never>?
    private let autoClearDelay: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void

    /// - Parameters:
    ///   - autoClearDelay: Seconds a message stays visible before it is auto-cleared. Defaults to
    ///     the existing `AppConstants.statusMessageAutoClearDelay` so production behavior is
    ///     unchanged.
    ///   - sleeper: The delay primitive. Defaults to a cancellable `Task.sleep`; tests inject a
    ///     controllable sleeper for determinism.
    init(
        autoClearDelay: TimeInterval = AppConstants.statusMessageAutoClearDelay,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.autoClearDelay = autoClearDelay
        self.sleeper = sleeper
    }

    /// Publishes `message` via `setMessage`, then schedules its delayed clear. Any previously
    /// scheduled clear is cancelled first. The returned task completes when the delayed clear
    /// resolves (used by tests to await deterministically).
    @discardableResult
    func show(
        _ message: MixerStatusMessage,
        setMessage: @escaping @MainActor (MixerStatusMessage?) -> Void,
        currentMessageID: @escaping @MainActor () -> MixerStatusMessage.ID?
    ) -> Task<Void, Never> {
        setMessage(message)

        clearTask?.cancel()
        let delay = autoClearDelay
        let sleeper = self.sleeper
        let messageID = message.id
        let task = Task { @MainActor in
            await sleeper(delay)
            // A cancelled timer never clears (e.g. an explicit `cancelPendingClear`). In the
            // show→show path the superseded timer is both cancelled here and would fail the id
            // guard below, so either check alone preserves the "newer message wins" behavior.
            guard !Task.isCancelled else {
                return
            }

            // Only clear if this scheduled message is still the visible one; a newer message
            // shown in the meantime carries a different id and must not be wiped by this timer.
            guard currentMessageID() == messageID else {
                return
            }

            setMessage(nil)
        }
        clearTask = task
        return task
    }

    /// Cancels any pending delayed clear without publishing a new message.
    func cancelPendingClear() {
        clearTask?.cancel()
        clearTask = nil
    }
}
