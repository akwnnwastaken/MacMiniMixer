import XCTest
@testable import MacMiniMixer

@MainActor
final class MixerStatusMessageControllerTests: XCTestCase {
    // MainActor-isolated manual sleeper: each scheduled clear suspends here until the test releases
    // it, so delays are driven deterministically with no real sleeping and no timing reliance.
    private final class ManualSleeper {
        private var continuations: [CheckedContinuation<Void, Never>] = []

        var pendingCount: Int { continuations.count }

        func sleep() async {
            await withCheckedContinuation { continuations.append($0) }
        }

        func releaseNext() {
            guard !continuations.isEmpty else {
                return
            }

            continuations.removeFirst().resume()
        }
    }

    private func makeMessage(_ text: String) -> MixerStatusMessage {
        MixerStatusMessage(text: text, style: .warning)
    }

    private func makeController(_ sleeper: ManualSleeper) -> MixerStatusMessageController {
        MixerStatusMessageController(autoClearDelay: 0) { _ in await sleeper.sleep() }
    }

    /// Spins the cooperative main-actor queue until `count` clear tasks have reached the sleeper.
    private func waitUntilPending(_ sleeper: ManualSleeper, _ count: Int) async {
        while sleeper.pendingCount < count {
            await Task.yield()
        }
    }

    func testShowPublishesMessage() async {
        let sleeper = ManualSleeper()
        let controller = makeController(sleeper)
        var current: MixerStatusMessage?

        let message = makeMessage("hello")
        controller.show(
            message,
            setMessage: { current = $0 },
            currentMessageID: { current?.id }
        )

        XCTAssertEqual(current?.id, message.id)
        XCTAssertEqual(current?.text, "hello")
    }

    func testDelayedClearRemovesTheMessageThatScheduledIt() async {
        let sleeper = ManualSleeper()
        let controller = makeController(sleeper)
        var current: MixerStatusMessage?

        let message = makeMessage("hello")
        let task = controller.show(
            message,
            setMessage: { current = $0 },
            currentMessageID: { current?.id }
        )

        await waitUntilPending(sleeper, 1)
        sleeper.releaseNext()
        await task.value

        XCTAssertNil(current)
    }

    func testStaleClearDoesNotWipeNewerMessage() async {
        let sleeper = ManualSleeper()
        let controller = makeController(sleeper)
        var current: MixerStatusMessage?
        let setMessage: @MainActor (MixerStatusMessage?) -> Void = { current = $0 }
        let currentID: @MainActor () -> MixerStatusMessage.ID? = { current?.id }

        let first = makeMessage("first")
        let firstTask = controller.show(first, setMessage: setMessage, currentMessageID: currentID)

        let second = makeMessage("second")
        let secondTask = controller.show(second, setMessage: setMessage, currentMessageID: currentID)

        XCTAssertEqual(current?.id, second.id)

        await waitUntilPending(sleeper, 2)

        // Release the first (now stale) clear: it must not clear the newer "second" message.
        sleeper.releaseNext()
        await firstTask.value
        XCTAssertEqual(current?.id, second.id)

        // Release the second (current) clear: it clears its own message.
        sleeper.releaseNext()
        await secondTask.value
        XCTAssertNil(current)
    }

    func testCancelPendingClearPreventsClearing() async {
        let sleeper = ManualSleeper()
        let controller = makeController(sleeper)
        var current: MixerStatusMessage?

        let message = makeMessage("hello")
        let task = controller.show(
            message,
            setMessage: { current = $0 },
            currentMessageID: { current?.id }
        )

        await waitUntilPending(sleeper, 1)
        controller.cancelPendingClear()

        // Even after the (cancelled) timer resolves, the message stays because its id still matches
        // and cancellation is expected to leave the visible message intact.
        sleeper.releaseNext()
        await task.value

        XCTAssertEqual(current?.id, message.id)
    }
}
