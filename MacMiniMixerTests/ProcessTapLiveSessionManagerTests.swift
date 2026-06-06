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
