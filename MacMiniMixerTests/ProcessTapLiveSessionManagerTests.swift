import CoreAudio
import XCTest
@testable import MacMiniMixer

final class ProcessTapLiveSessionManagerTests: XCTestCase {
    func testStartSessionSucceedsWhenNoSessionIsActive() async {
        let controller = FakeLiveController()
        let manager = ProcessTapLiveSessionManager(controller: controller)

        let start = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )

        XCTAssertEqual(start.result.outcome, .liveControlStarted)
        XCTAssertNotNil(start.sessionID)
        XCTAssertEqual(manager.activeSessions.count, 1)
        XCTAssertEqual(manager.activeSession?.processIdentifier, 101)
        XCTAssertEqual(controller.startCallCount, 1)
        XCTAssertEqual(controller.startTimeoutPolicies, [.limited(AppConstants.processTapLiveControlMaxDuration)])
    }

    func testStartSessionRejectsSecondSessionWhenMaxSessionsIsOne() async {
        let controllers = FakeLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: 1) {
            controllers.makeController()
        }

        let first = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let second = await manager.startSession(
            for: makeTarget(pid: 202),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )

        XCTAssertEqual(first.result.outcome, .liveControlStarted)
        XCTAssertEqual(second.result.outcome, .liveControlSetupFailed)
        XCTAssertNil(second.sessionID)
        XCTAssertEqual(second.result.message, "Live control is already active")
        XCTAssertEqual(manager.activeSessions.map(\.processIdentifier), [101])
        XCTAssertEqual(controllers.controllers.count, 2)
        XCTAssertEqual(controllers.controllers[0].startCallCount, 1)
        XCTAssertEqual(controllers.controllers[1].startCallCount, 0)
    }

    func testStopSessionStopsActiveSessionByID() async throws {
        let controller = FakeLiveController()
        let manager = ProcessTapLiveSessionManager(controller: controller)
        let start = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let sessionID = try XCTUnwrap(start.sessionID)

        let stop = await manager.stopSession(id: sessionID, reason: .userStopped)

        XCTAssertEqual(stop.outcome, .liveControlStopped)
        XCTAssertEqual(controller.stopReasons, [.userStopped])
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    func testStopSessionForUnknownIDReturnsSafeNotActiveResult() async {
        let controller = FakeLiveController()
        let manager = ProcessTapLiveSessionManager(controller: controller)

        let stop = await manager.stopSession(id: ProcessTapLiveSessionID(), reason: .userStopped)

        XCTAssertEqual(stop.outcome, .liveControlNotActive)
        XCTAssertEqual(stop.message, "Live control is not active")
        XCTAssertTrue(manager.activeSessions.isEmpty)
        XCTAssertEqual(controller.stopReasons, [])
    }

    func testStopAllIsSafeWhenNoSessionsAreActive() async {
        let manager = ProcessTapLiveSessionManager(controller: FakeLiveController())

        let results = await manager.stopAll(reason: .userStopped)

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    func testStopAllStopsAllActiveSessionsWhenMaxSessionsAllowsMoreThanOne() async {
        let controllers = FakeLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: 2) {
            controllers.makeController()
        }
        let first = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let second = await manager.startSession(
            for: makeTarget(pid: 202),
            gain: .options[2],
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )

        let results = await manager.stopAll(reason: .timedOut)

        XCTAssertNotNil(first.sessionID)
        XCTAssertNotNil(second.sessionID)
        XCTAssertEqual(results.map(\.outcome), [.liveControlStopped, .liveControlStopped])
        XCTAssertEqual(controllers.controllers.map(\.stopReasons), [[.timedOut], [.timedOut]])
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    func testUpdateGainRoutesToCorrectActiveSession() async throws {
        let controllers = FakeLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: 2) {
            controllers.makeController()
        }
        let first = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let second = await manager.startSession(
            for: makeTarget(pid: 202),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let firstID = try XCTUnwrap(first.sessionID)
        let secondID = try XCTUnwrap(second.sessionID)

        manager.updateGain(sessionID: secondID, gain: .options[3])

        XCTAssertEqual(manager.activeSessions.first { $0.id == firstID }?.gain, .defaultOption)
        XCTAssertEqual(manager.activeSessions.first { $0.id == secondID }?.gain, .options[3])
        XCTAssertEqual(controllers.controllers[0].gainUpdates, [])
        XCTAssertEqual(controllers.controllers[1].gainUpdates, [.options[3]])
    }

    func testUpdateGainForUnknownSessionIsSafe() {
        let controller = FakeLiveController()
        let manager = ProcessTapLiveSessionManager(controller: controller)

        manager.updateGain(sessionID: ProcessTapLiveSessionID(), gain: .options[3])

        XCTAssertTrue(manager.activeSessions.isEmpty)
        XCTAssertEqual(controller.gainUpdates, [])
    }

    func testActiveSessionStateReflectsStartAndStop() async throws {
        let manager = ProcessTapLiveSessionManager(controller: FakeLiveController())
        XCTAssertNil(manager.activeSession)
        XCTAssertTrue(manager.activeSessions.isEmpty)

        let start = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .options[1],
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let sessionID = try XCTUnwrap(start.sessionID)

        XCTAssertEqual(manager.activeSession?.id, sessionID)
        XCTAssertEqual(manager.activeSessions.count, 1)

        _ = await manager.stopSession(id: sessionID, reason: .userStopped)

        XCTAssertNil(manager.activeSession)
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    func testStartFailureDoesNotLeaveStaleActiveSessionState() async {
        let controller = FakeLiveController(startResult: .setupFailed(message: "setup failed"))
        let manager = ProcessTapLiveSessionManager(controller: controller)

        let start = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )

        XCTAssertEqual(start.result.outcome, .liveControlSetupFailed)
        XCTAssertNil(start.sessionID)
        XCTAssertTrue(manager.activeSessions.isEmpty)
        XCTAssertEqual(controller.startCallCount, 1)
    }

    func testStopNotActiveOutcomeRemovesSessionWithoutDependingOnMessageText() async throws {
        let controller = FakeLiveController(
            stopResult: ProcessTapTestResult(
                outcome: .liveControlNotActive,
                message: "controller-specific not-active text",
                severity: .info
            ),
            callsOnStoppedDuringStop: false
        )
        let manager = ProcessTapLiveSessionManager(controller: controller)
        let start = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let sessionID = try XCTUnwrap(start.sessionID)

        let stop = await manager.stopSession(id: sessionID, reason: .userStopped)

        XCTAssertEqual(stop.outcome, .liveControlNotActive)
        XCTAssertEqual(stop.message, "controller-specific not-active text")
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    func testStopFailureOutcomeDoesNotUseMessageTextForControlFlow() async throws {
        let controller = FakeLiveController(
            stopResult: ProcessTapTestResult(
                outcome: .tapCleanupFailed,
                message: "cleanup warning from fake controller",
                detail: "fake cleanup detail",
                severity: .warning
            )
        )
        let manager = ProcessTapLiveSessionManager(controller: controller)
        let start = await manager.startSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        let sessionID = try XCTUnwrap(start.sessionID)

        let stop = await manager.stopSession(id: sessionID, reason: .userStopped)

        XCTAssertEqual(stop.outcome, .tapCleanupFailed)
        XCTAssertEqual(stop.message, "cleanup warning from fake controller")
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    private func makeTarget(pid: Int32) -> ProcessTapTarget {
        ProcessTapTarget(
            appID: "test.app.\(pid)",
            appName: "Test App \(pid)",
            processIdentifier: pid
        )
    }
}

private final class FakeLiveControllerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var controllers: [FakeLiveController] = []

    func makeController() -> ProcessTapLiveControlling {
        let controller = FakeLiveController()
        lock.lock()
        controllers.append(controller)
        lock.unlock()
        return controller
    }
}

private final class FakeLiveController: ProcessTapLiveControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let startResult: ProcessTapTestResult
    private let stopResult: ProcessTapTestResult
    private let callsOnStoppedDuringStop: Bool
    private var onStopped: ((ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?

    private var _startCallCount = 0
    private var _stopReasons: [ProcessTapLiveStopReason] = []
    private var _gainUpdates: [ProcessTapReplayGainOption] = []
    private var _startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] = []

    init(
        startResult: ProcessTapTestResult = .started,
        stopResult: ProcessTapTestResult = .stopped,
        callsOnStoppedDuringStop: Bool = true
    ) {
        self.startResult = startResult
        self.stopResult = stopResult
        self.callsOnStoppedDuringStop = callsOnStoppedDuringStop
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCallCount
    }

    var stopReasons: [ProcessTapLiveStopReason] {
        lock.lock()
        defer { lock.unlock() }
        return _stopReasons
    }

    var gainUpdates: [ProcessTapReplayGainOption] {
        lock.lock()
        defer { lock.unlock() }
        return _gainUpdates
    }

    var startTimeoutPolicies: [ProcessTapLiveTimeoutPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return _startTimeoutPolicies
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        recordStart(timeoutPolicy: timeoutPolicy, onStopped: onStopped)

        return startResult
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        let callback = recordStop(reason: reason)

        if callsOnStoppedDuringStop {
            callback?(stopResult, nil)
        }

        return stopResult
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {
        lock.lock()
        _gainUpdates.append(gain)
        lock.unlock()
    }

    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        let callback = recordStop(reason: reason)

        if callsOnStoppedDuringStop {
            callback?(stopResult, nil)
        }

        return stopResult
    }

    private func recordStart(
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onStopped: @escaping (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) {
        lock.lock()
        _startCallCount += 1
        _startTimeoutPolicies.append(timeoutPolicy)
        self.onStopped = onStopped
        lock.unlock()
    }

    private func recordStop(
        reason: ProcessTapLiveStopReason
    ) -> ((ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)? {
        lock.lock()
        _stopReasons.append(reason)
        let callback = onStopped
        lock.unlock()
        return callback
    }
}

private extension ProcessTapTestResult {
    static let started = ProcessTapTestResult(
        outcome: .liveControlStarted,
        message: "started",
        severity: .info
    )

    static let stopped = ProcessTapTestResult(
        outcome: .liveControlStopped,
        message: "stopped",
        severity: .info
    )

    static func setupFailed(message: String) -> ProcessTapTestResult {
        ProcessTapTestResult(
            outcome: .liveControlSetupFailed,
            message: message,
            severity: .warning
        )
    }
}

/// Covers the pure tap-destroy retry helper that guards against the muted-tap leak: a process tap
/// created with `.mutedWhenTapped` that survives teardown leaves the tapped apps muted inside
/// coreaudiod until a restart, so destroy failures must be retried and never silently swallowed.
final class ProcessTapTeardownTests: XCTestCase {
    private let anyTapID: AudioObjectID = 4242

    func testDestroySucceedsOnFirstAttemptDoesNotRetryOrSleep() {
        var destroyCalls = 0
        var sleeps: [TimeInterval] = []

        let outcome = ProcessTapTeardown.destroyProcessTapWithRetry(
            tapID: anyTapID,
            maxAttempts: 3,
            retryDelay: 0.15,
            destroy: { _ in destroyCalls += 1; return noErr },
            sleep: { sleeps.append($0) }
        )

        XCTAssertEqual(outcome, .succeeded(attempts: 1))
        XCTAssertEqual(destroyCalls, 1)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testDestroyRetriesUntilSuccessAndReportsAttemptCount() {
        var destroyCalls = 0
        var sleeps: [TimeInterval] = []

        // Fails twice (transient, as during a route transition), then succeeds.
        let outcome = ProcessTapTeardown.destroyProcessTapWithRetry(
            tapID: anyTapID,
            maxAttempts: 3,
            retryDelay: 0.15,
            destroy: { _ in
                destroyCalls += 1
                return destroyCalls < 3 ? OSStatus(1852797029) : noErr
            },
            sleep: { sleeps.append($0) }
        )

        XCTAssertEqual(outcome, .succeeded(attempts: 3))
        XCTAssertEqual(destroyCalls, 3)
        // Delay applied between attempts only (not after the final, successful one).
        XCTAssertEqual(sleeps, [0.15, 0.15])
    }

    func testDestroyFailingEveryAttemptReportsFailureWithLastStatusAndExhaustsAttempts() {
        var destroyCalls = 0
        var sleeps: [TimeInterval] = []
        let failureStatus = OSStatus(560947818) // 'what' — stand-in for a HAL error

        let outcome = ProcessTapTeardown.destroyProcessTapWithRetry(
            tapID: anyTapID,
            maxAttempts: 3,
            retryDelay: 0.15,
            destroy: { _ in destroyCalls += 1; return failureStatus },
            sleep: { sleeps.append($0) }
        )

        // A persisted muted tap must surface as a failure, not be swallowed as clean.
        XCTAssertEqual(outcome, .failed(lastStatus: failureStatus, attempts: 3))
        XCTAssertEqual(destroyCalls, 3)
        // One settle delay between each of the three attempts (none after the last).
        XCTAssertEqual(sleeps, [0.15, 0.15])
    }

    func testDestroyAttemptsAtLeastOnceWhenMaxAttemptsIsNonPositive() {
        var destroyCalls = 0

        let outcome = ProcessTapTeardown.destroyProcessTapWithRetry(
            tapID: anyTapID,
            maxAttempts: 0,
            retryDelay: 0.15,
            destroy: { _ in destroyCalls += 1; return noErr },
            sleep: { _ in }
        )

        XCTAssertEqual(outcome, .succeeded(attempts: 1))
        XCTAssertEqual(destroyCalls, 1)
    }

    func testProductionDestroyConstantsAreSafeForRetry() {
        XCTAssertGreaterThanOrEqual(AppConstants.processTapDestroyMaxAttempts, 2)
        XCTAssertGreaterThan(AppConstants.processTapDestroyRetryDelay, 0)
    }

    // Pins the teardown-ordering contract the live cleanup relies on: the `beforeStoppingIO` hook
    // (where the live path now only fades the gain) runs strictly before the `afterDestroyingIOProc`
    // hook (where the live path now stops/disposes the output queue). cleanup runs the IOProc
    // stop/destroy between these two hooks, so disposing the queue in the later hook guarantees the
    // IOProc — the producer that enqueues into the queue — is already gone, which is what stops the
    // dropped-buffer spike during an output-device-change teardown. A fresh resource context has no
    // Core Audio objects, so cleanup exercises only the hook sequence here.
    func testCleanupRunsBeforeStoppingIOThenAfterDestroyingIOProcInOrder() {
        let context = ProcessTapResourceContext()
        var events: [String] = []

        let errors = context.cleanup(
            beforeStoppingIO: { events.append("fade (queue still live)") },
            afterDestroyingIOProc: { events.append("stop queue (IOProc gone)") }
        )

        XCTAssertEqual(events, ["fade (queue still live)", "stop queue (IOProc gone)"])
        XCTAssertTrue(errors.isEmpty)
    }

    func testCleanupIsIdempotentAndRunsHooksOnlyOnce() {
        let context = ProcessTapResourceContext()
        var beforeCount = 0
        var afterCount = 0

        _ = context.cleanup(beforeStoppingIO: { beforeCount += 1 }, afterDestroyingIOProc: { afterCount += 1 })
        _ = context.cleanup(beforeStoppingIO: { beforeCount += 1 }, afterDestroyingIOProc: { afterCount += 1 })

        XCTAssertEqual(beforeCount, 1)
        XCTAssertEqual(afterCount, 1)
    }
}

/// Thread-safe ordered event log for deterministic concurrency assertions (no sleeps/yields).
final class TestOrderedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var entries: [String] { lock.withLock { storage } }
    func append(_ event: String) { lock.withLock { storage.append(event) } }
}

/// An awaitable one-shot gate the test fulfills explicitly, so a background task can be held
/// suspended until the test releases it — deterministic, no polling or sleeping.
final class TestAsyncReleaser: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Records the settle-delay durations requested of the gate's sleeper, without ever sleeping.
final class TestRecordingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { storage } }
    func sleep(_ seconds: TimeInterval) async { lock.withLock { storage.append(seconds) } }
}

final class ProductRealStartSettleGateTests: XCTestCase {
    func testWaitSkipsSettleWhenNoTeardownPreceded() async {
        let sleeper = TestRecordingSleeper()
        let gate = ProductRealStartSettleGate(settleDelay: 0.2, sleeper: { await sleeper.sleep($0) })

        await gate.waitForReadyToStart()

        XCTAssertTrue(sleeper.delays.isEmpty)
    }

    func testWaitSettlesOnceAfterARegisteredStop() async {
        let sleeper = TestRecordingSleeper()
        let gate = ProductRealStartSettleGate(settleDelay: 0.2, sleeper: { await sleeper.sleep($0) })

        gate.registerStop(Task {})
        await gate.waitForReadyToStart()

        XCTAssertEqual(sleeper.delays, [0.2])
    }

    func testWaitAwaitsInFlightStopThenSettlesBeforeReturning() async {
        let log = TestOrderedLog()
        let releaser = TestAsyncReleaser()
        let gate = ProductRealStartSettleGate(
            settleDelay: 0.2,
            sleeper: { _ in log.append("settle") }
        )

        // A stop that does not finish until the test releases it; it logs "stop" on completion.
        gate.registerStop(Task { await releaser.wait(); log.append("stop") })

        // waitForReadyToStart must await the stop, then settle, then return ("ready").
        async let readyDone: Void = {
            await gate.waitForReadyToStart()
            log.append("ready")
        }()

        releaser.release()
        await readyDone

        // Order is guaranteed by the gate: stop completes, then settle, then ready.
        XCTAssertEqual(log.entries, ["stop", "settle", "ready"])
    }

    func testWaitAwaitsMultipleStopsThenSettlesExactlyOnce() async {
        let sleeper = TestRecordingSleeper()
        let log = TestOrderedLog()
        let gate = ProductRealStartSettleGate(settleDelay: 0.25, sleeper: { await sleeper.sleep($0) })

        for index in 0..<3 {
            gate.registerStop(Task { log.append("stop\(index)") })
        }
        await gate.waitForReadyToStart()

        XCTAssertEqual(Set(log.entries), ["stop0", "stop1", "stop2"])
        XCTAssertEqual(sleeper.delays, [0.25]) // a burst of stops settles once, not per-stop
    }

    func testSecondStartWithoutNewTeardownSkipsSettle() async {
        let sleeper = TestRecordingSleeper()
        let gate = ProductRealStartSettleGate(settleDelay: 0.2, sleeper: { await sleeper.sleep($0) })

        gate.registerStop(Task {})
        await gate.waitForReadyToStart() // first start after a teardown: settles
        await gate.waitForReadyToStart() // no new teardown since: no settle

        XCTAssertEqual(sleeper.delays, [0.2])
    }
}

/// Bounded, sleep-free spin on an observable condition. Yields the cooperative pool (letting queued
/// gate/session work advance) and fails the test if the condition never holds — an exact observable
/// wait, not a fixed `Task.yield()` count.
private func waitFor(
    _ condition: @Sendable () -> Bool,
    timeoutInYields: Int = 5_000,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<timeoutInYields {
        if condition() {
            return
        }
        await Task.yield()
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}

/// Covers the actor that serializes Product Real Core Audio create/destroy so no two session
/// setup/teardown operations overlap on the shared coreaudiod route (the combination-change
/// starvation/clicks hardening). Serialization is proven by observable event order, not timing.
final class ProductRealCoreAudioLifecycleGateTests: XCTestCase {
    func testPerformRunsOperationsSeriallySoTheSecondStartsAfterTheFirstFinishes() async {
        let gate = ProductRealCoreAudioLifecycleGate()
        let log = TestOrderedLog()
        let firstReleaser = TestAsyncReleaser()
        let secondReleaser = TestAsyncReleaser()

        // A enters the gate and blocks; it must fully finish before B is allowed to enter.
        async let first: Void = gate.perform {
            log.append("A-enter")
            await firstReleaser.wait()
            log.append("A-exit")
        }
        await waitFor { log.entries.contains("A-enter") }

        // B is enqueued while A is still holding the gate.
        async let second: Void = gate.perform {
            log.append("B-enter")
            await secondReleaser.wait()
            log.append("B-exit")
        }

        firstReleaser.release()
        // B-enter can only appear once A's operation has finished (A-exit). Waiting for B-enter and
        // asserting A-exit precedes it is the deterministic serialization proof: if the gate let B
        // run concurrently, B-enter would appear before A-exit and this order assertion would fail.
        await waitFor { log.entries.contains("B-enter") }
        XCTAssertEqual(log.entries, ["A-enter", "A-exit", "B-enter"])

        secondReleaser.release()
        await first
        await second
        XCTAssertEqual(log.entries, ["A-enter", "A-exit", "B-enter", "B-exit"])
    }

    func testPerformReturnsEachOperationsOwnResult() async {
        let gate = ProductRealCoreAudioLifecycleGate()

        let first = await gate.perform { 41 }
        let second = await gate.perform { "ok" }

        XCTAssertEqual(first, 41)
        XCTAssertEqual(second, "ok")
    }

    func testPerformRunsALoneOperationWithoutBlocking() async {
        let gate = ProductRealCoreAudioLifecycleGate()

        let ran = await gate.perform { true }

        XCTAssertTrue(ran)
    }
}

/// Manager-level serialization: every session start (Core Audio create) and stop (Core Audio
/// destroy) is funnelled through the lifecycle gate, so a peer's teardown never overlaps a new
/// session's setup while a third session keeps rendering — the exact combination-change scenario
/// (A + B active, stop B, start C) that produced real starvation/clicks.
final class ProcessTapLiveSessionLifecycleSerializationTests: XCTestCase {
    func testPeerTeardownAndNewStartAreSerializedWhileAnotherSessionStaysActive() async throws {
        let log = TestOrderedLog()
        let controllerA = BlockingLiveController(label: "A", log: log)
        let controllerB = BlockingLiveController(label: "B", log: log, stopReleaser: TestAsyncReleaser())
        let controllerC = BlockingLiveController(label: "C", log: log)
        let factory = BlockingControllerFactory([controllerA, controllerB, controllerC])
        let manager = ProcessTapLiveSessionManager(maxSessions: 3) { factory.make() }

        // A and B start (unblocked) and are active.
        let startA = await manager.startSession(for: lifecycleTarget(101), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })
        let startB = await manager.startSession(for: lifecycleTarget(202), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })
        let idA = try XCTUnwrap(startA.sessionID)
        let idB = try XCTUnwrap(startB.sessionID)
        XCTAssertEqual(Set(manager.activeSessions.map(\.id)), [idA, idB])

        // Stop B; its teardown blocks inside the gate, so the gate is held by a destroy.
        async let stopB: ProcessTapTestResult = manager.stopSession(id: idB, reason: .userStopped)
        await waitFor { log.entries.contains("destroy-enter-B") }

        // A must keep rendering while B tears down — the gate does not touch other sessions.
        XCTAssertTrue(manager.activeSessions.map(\.id).contains(idA))

        // Now request C's start. Its Core Audio create must wait behind B's in-flight destroy.
        async let startC: ProcessTapLiveSessionStartResult = manager.startSession(for: lifecycleTarget(303), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })
        // Give C's start every chance to (wrongly) begin creating while B is blocked; it must not.
        await waitFor { log.entries.count >= 3 || log.entries.contains("create-enter-C") }
        XCTAssertFalse(log.entries.contains("create-enter-C"))

        // Release B's teardown; only then may C create.
        controllerB.stopReleaser?.release()
        _ = await stopB
        let resultC = await startC
        let idC = try XCTUnwrap(resultC.sessionID)

        // C created strictly after B's destroy completed: no overlap of the two Core Audio ops.
        let entries = log.entries
        let destroyExitIndex = try XCTUnwrap(entries.firstIndex(of: "destroy-exit-B"))
        let createEnterIndex = try XCTUnwrap(entries.firstIndex(of: "create-enter-C"))
        XCTAssertLessThan(destroyExitIndex, createEnterIndex)

        // Final state: A stayed active, C is active, B is gone. Cap semantics intact (≤ maxSessions).
        XCTAssertEqual(Set(manager.activeSessions.map(\.id)), [idA, idC])
        XCTAssertLessThanOrEqual(manager.activeSessions.count, 3)
    }

    func testConcurrentSessionStartsDoNotOverlapCoreAudioCreation() async {
        let log = TestOrderedLog()
        let controllerA = BlockingLiveController(label: "A", log: log, startReleaser: TestAsyncReleaser())
        let controllerB = BlockingLiveController(label: "B", log: log, startReleaser: TestAsyncReleaser())
        let factory = BlockingControllerFactory([controllerA, controllerB])
        let manager = ProcessTapLiveSessionManager(maxSessions: 2) { factory.make() }

        async let startA: ProcessTapLiveSessionStartResult = manager.startSession(for: lifecycleTarget(101), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })
        async let startB: ProcessTapLiveSessionStartResult = manager.startSession(for: lifecycleTarget(202), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })

        // Exactly one create is admitted at a time: while the first is blocked, the second cannot
        // have entered Core Audio creation.
        await waitFor { log.entries.filter { $0.hasPrefix("create-enter") }.count == 1 }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("create-exit") }.count, 0)

        // Release both releasers (idempotent, one-shot): the first proceeds, then the second.
        controllerA.startReleaser?.release()
        controllerB.startReleaser?.release()
        _ = await startA
        _ = await startB

        // Strictly non-interleaved: each create-enter is immediately followed by its own create-exit.
        let entries = log.entries
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries[0].hasPrefix("create-enter"))
        XCTAssertEqual(entries[1], entries[0].replacingOccurrences(of: "enter", with: "exit"))
        XCTAssertTrue(entries[2].hasPrefix("create-enter"))
        XCTAssertEqual(entries[3], entries[2].replacingOccurrences(of: "enter", with: "exit"))
    }

    func testStopAllTeardownsAreSerializedOneAtATime() async {
        let log = TestOrderedLog()
        let controllerA = BlockingLiveController(label: "A", log: log, stopReleaser: TestAsyncReleaser())
        let controllerB = BlockingLiveController(label: "B", log: log, stopReleaser: TestAsyncReleaser())
        let factory = BlockingControllerFactory([controllerA, controllerB])
        let manager = ProcessTapLiveSessionManager(maxSessions: 2) { factory.make() }
        _ = await manager.startSession(for: lifecycleTarget(101), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })
        _ = await manager.startSession(for: lifecycleTarget(202), gain: .defaultOption, onDiagnostics: { _, _ in }, onStopped: { _, _, _ in })

        async let stopAll: [ProcessTapTestResult] = manager.stopAll(reason: .userStopped)

        // Only one teardown is in flight at a time; the second waits for the first to release.
        await waitFor { log.entries.filter { $0.hasPrefix("destroy-enter") }.count == 1 }
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("destroy-exit") }.count, 0)

        controllerA.stopReleaser?.release()
        controllerB.stopReleaser?.release()
        _ = await stopAll

        // Non-interleaved destroys: enter/exit pair up before the next destroy begins. (Filtered to
        // the destroy events; the two starts above also logged their own create enter/exit.)
        let destroys = log.entries.filter { $0.hasPrefix("destroy-") }
        XCTAssertEqual(destroys.count, 4)
        XCTAssertEqual(destroys[1], destroys[0].replacingOccurrences(of: "enter", with: "exit"))
        XCTAssertEqual(destroys[3], destroys[2].replacingOccurrences(of: "enter", with: "exit"))
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }
}

private func lifecycleTarget(_ pid: Int32) -> ProcessTapTarget {
    ProcessTapTarget(
        appID: "test.app.\(pid)",
        appName: "Test App \(pid)",
        processIdentifier: pid
    )
}

/// A controller whose Core Audio create (`startLiveControl`) and destroy (`stopLiveControl`) each
/// log an enter/exit event and can be held mid-operation by an injected releaser, so the lifecycle
/// gate's serialization can be observed deterministically without sleeps.
private final class BlockingLiveController: ProcessTapLiveControlling, @unchecked Sendable {
    let startReleaser: TestAsyncReleaser?
    let stopReleaser: TestAsyncReleaser?
    private let label: String
    private let log: TestOrderedLog
    private let lock = NSLock()
    private var storedOnStopped: (@Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void)?

    init(
        label: String,
        log: TestOrderedLog,
        startReleaser: TestAsyncReleaser? = nil,
        stopReleaser: TestAsyncReleaser? = nil
    ) {
        self.label = label
        self.log = log
        self.startReleaser = startReleaser
        self.stopReleaser = stopReleaser
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        log.append("create-enter-\(label)")
        if let startReleaser {
            await startReleaser.wait()
        }
        lock.lock()
        storedOnStopped = onStopped
        lock.unlock()
        log.append("create-exit-\(label)")
        return ProcessTapTestResult(outcome: .liveControlStarted, message: "started", severity: .info)
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        log.append("destroy-enter-\(label)")
        if let stopReleaser {
            await stopReleaser.wait()
        }
        lock.lock()
        let callback = storedOnStopped
        storedOnStopped = nil
        lock.unlock()
        let result = ProcessTapTestResult(outcome: .liveControlStopped, message: "stopped", severity: .info)
        callback?(result, nil)
        log.append("destroy-exit-\(label)")
        return result
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {}

    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        nil
    }
}

/// Vends pre-built blocking controllers in start order (the manager calls the factory once per
/// session start), so each session gets a controller with a known label and releaser.
private final class BlockingControllerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [BlockingLiveController]

    init(_ controllers: [BlockingLiveController]) {
        queue = controllers
    }

    func make() -> ProcessTapLiveControlling {
        lock.lock()
        defer { lock.unlock() }
        return queue.removeFirst()
    }
}
