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

    func testSessionSpecificCompatibilityAPIStopsOnlyRequestedSession() async throws {
        let controllers = FakeLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: 2) {
            controllers.makeController()
        }
        let first = await manager.startLiveControlSession(
            for: makeTarget(pid: 101),
            gain: .defaultOption,
            timeoutPolicy: .indefinite,
            onDiagnostics: { _ in },
            onStopped: { _, _ in }
        )
        let second = await manager.startLiveControlSession(
            for: makeTarget(pid: 202),
            gain: .options[2],
            timeoutPolicy: .standard,
            onDiagnostics: { _ in },
            onStopped: { _, _ in }
        )
        let firstID = try XCTUnwrap(first.sessionID)
        let secondID = try XCTUnwrap(second.sessionID)

        let stop = await manager.stopLiveControlSession(id: firstID, reason: .userStopped)

        XCTAssertEqual(stop.outcome, .liveControlStopped)
        XCTAssertEqual(controllers.controllers[0].stopReasons, [.userStopped])
        XCTAssertEqual(controllers.controllers[1].stopReasons, [])
        XCTAssertEqual(manager.activeSessions.map(\.id), [secondID])
    }

    func testPendingStoppedSessionBlocksOverlapThenReleasesSlotAfterLateSuccessCleanup() async throws {
        let controllers = ControllableLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: 1) {
            controllers.makeController()
        }

        let startATask = Task {
            await manager.startSession(
                for: makeTarget(pid: 101),
                gain: .defaultOption,
                onDiagnostics: { _, _ in },
                onStopped: { _, _, _ in }
            )
        }
        await waitFor { controllers.controllers.first?.pendingStartCount == 1 }
        let sessionA = try XCTUnwrap(manager.activeSession?.id)

        let stopA = await manager.stopSession(id: sessionA, reason: .userStopped)
        XCTAssertEqual(stopA.outcome, .liveControlNotActive)
        XCTAssertEqual(manager.activeSessions.map(\.id), [sessionA])

        let blockedB = await manager.startSession(
            for: makeTarget(pid: 202),
            gain: .defaultOption,
            onDiagnostics: { _, _ in },
            onStopped: { _, _, _ in }
        )
        XCTAssertEqual(blockedB.result.outcome, .liveControlSetupFailed)
        XCTAssertNil(blockedB.sessionID)
        XCTAssertEqual(controllers.controllers.count, 2)
        XCTAssertEqual(controllers.controllers[1].startCallCount, 0)

        controllers.controllers[0].completeNextStart(.started)
        let lateA = await startATask.value
        XCTAssertEqual(lateA.result.outcome, .liveControlStarted)
        XCTAssertEqual(lateA.sessionID, sessionA)
        await waitFor { manager.activeSessions.isEmpty }
        XCTAssertEqual(controllers.controllers[0].stopReasons, [.userStopped, .userStopped])

        let retryBTask = Task {
            await manager.startSession(
                for: makeTarget(pid: 202),
                gain: .defaultOption,
                onDiagnostics: { _, _ in },
                onStopped: { _, _, _ in }
            )
        }
        await waitFor { controllers.controllers.count == 3 && controllers.controllers[2].pendingStartCount == 1 }
        controllers.controllers[2].completeNextStart(.started)
        let retryB = await retryBTask.value
        XCTAssertEqual(retryB.result.outcome, .liveControlStarted)
        XCTAssertNotNil(retryB.sessionID)
        XCTAssertEqual(manager.activeSessions.map(\.processIdentifier), [202])
    }

    func testRepeatedPendingSessionSpecificStopIsSafeAndLateSuccessReleasesSlot() async throws {
        let controllers = ControllableLiveControllerFactory()
        let manager = ProcessTapLiveSessionManager(maxSessions: 1) {
            controllers.makeController()
        }

        let startTask = Task {
            await manager.startSession(
                for: makeTarget(pid: 101),
                gain: .defaultOption,
                onDiagnostics: { _, _ in },
                onStopped: { _, _, _ in }
            )
        }
        await waitFor { controllers.controllers.first?.pendingStartCount == 1 }
        let sessionID = try XCTUnwrap(manager.activeSession?.id)

        let firstStop = await manager.stopLiveControlSession(id: sessionID, reason: .userStopped)
        let secondStop = await manager.stopLiveControlSession(id: sessionID, reason: .userStopped)

        XCTAssertEqual(firstStop.outcome, .liveControlNotActive)
        XCTAssertEqual(secondStop.outcome, .liveControlNotActive)
        XCTAssertEqual(manager.activeSessions.map(\.id), [sessionID])

        controllers.controllers[0].completeNextStart(.started)
        _ = await startTask.value

        await waitFor { manager.activeSessions.isEmpty }
        XCTAssertEqual(controllers.controllers[0].stopReasons, [.userStopped, .userStopped, .userStopped])
    }

    private func makeTarget(pid: Int32) -> ProcessTapTarget {
        ProcessTapTarget(
            appID: "test.app.\(pid)",
            appName: "Test App \(pid)",
            processIdentifier: pid
        )
    }

    private func waitFor(
        timeoutInYields: Int = 10_000,
        _ predicate: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<timeoutInYields {
            if predicate() {
                return
            }

            await Task.yield()
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
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

private final class ControllableLiveControllerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var controllers: [ControllableLiveController] = []

    func makeController() -> ProcessTapLiveControlling {
        let controller = ControllableLiveController()
        lock.lock()
        controllers.append(controller)
        lock.unlock()
        return controller
    }
}

private final class ControllableLiveController: ProcessTapLiveControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingStartContinuations: [CheckedContinuation<ProcessTapTestResult, Never>] = []
    private var _startCallCount = 0
    private var _stopReasons: [ProcessTapLiveStopReason] = []

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCallCount
    }

    var pendingStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingStartContinuations.count
    }

    var stopReasons: [ProcessTapLiveStopReason] {
        lock.lock()
        defer { lock.unlock() }
        return _stopReasons
    }

    func completeNextStart(_ result: ProcessTapTestResult) {
        lock.lock()
        let continuation = pendingStartContinuations.isEmpty ? nil : pendingStartContinuations.removeFirst()
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func startLiveControl(
        for target: ProcessTapTarget,
        gain: ProcessTapReplayGainOption,
        timeoutPolicy: ProcessTapLiveTimeoutPolicy,
        onDiagnostics: @escaping @Sendable (ProcessTapLiveDiagnostics) -> Void,
        onStopped: @escaping @Sendable (ProcessTapTestResult, ProcessTapLiveDiagnostics?) -> Void
    ) async -> ProcessTapTestResult {
        recordStartCall()

        return await withCheckedContinuation { continuation in
            appendPendingStart(continuation)
        }
    }

    func stopLiveControl(reason: ProcessTapLiveStopReason) async -> ProcessTapTestResult {
        recordStop(reason)
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    func updateLiveControlGain(_ gain: ProcessTapReplayGainOption) {}

    func stopLiveControlNow(reason: ProcessTapLiveStopReason) -> ProcessTapTestResult? {
        recordStop(reason)
        return ProcessTapTestResult(outcome: .liveControlNotActive, message: "Live control is not active", severity: .info)
    }

    private func recordStartCall() {
        lock.lock()
        _startCallCount += 1
        lock.unlock()
    }

    private func appendPendingStart(_ continuation: CheckedContinuation<ProcessTapTestResult, Never>) {
        lock.lock()
        pendingStartContinuations.append(continuation)
        lock.unlock()
    }

    private func recordStop(_ reason: ProcessTapLiveStopReason) {
        lock.lock()
        _stopReasons.append(reason)
        lock.unlock()
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
