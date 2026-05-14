import Foundation

struct AppAudioTargetRequest: Equatable, Sendable {
    let appID: String
    let appName: String
    let processIdentifier: Int32?

    var helperDiscoveryTarget: HelperProcessDiscoveryTarget {
        HelperProcessDiscoveryTarget(
            id: appID,
            name: appName,
            processIdentifier: processIdentifier
        )
    }
}

struct ResolvedAppAudioTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case visibleApp
        case helper
    }

    enum Source: Equatable, Sendable {
        case directVisibleApp
        case discoveredHelper
        case cachedHelper
    }

    let visibleAppID: String
    let visibleAppName: String
    let target: ProcessTapTarget
    let kind: Kind
    let source: Source
}

enum AppAudioResolutionState: Equatable, Sendable {
    case resolving
}

struct AppAudioResolutionProgress: Equatable, Sendable {
    let testedCandidateCount: Int
    let totalCandidateCount: Int
}

enum AppAudioTargetResolutionResult: Equatable, Sendable {
    case resolved(ResolvedAppAudioTarget)
    case unavailable(String)
    case cancelled
}

protocol AppAudioTargetResolving: Sendable {
    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason)
    func invalidateCachedTarget(for request: AppAudioTargetRequest)
    func invalidateAllCachedTargets()
}

final class HelperAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    private let processLister: ProcessListing
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let lock = NSLock()
    private var currentResolutionID: UUID?
    private var cachedHelpersByKey: [AppAudioHelperResolutionCacheKey: AppAudioHelperResolutionCacheEntry] = [:]

    init(
        processLister: ProcessListing,
        helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    ) {
        self.processLister = processLister
        self.helperProcessAudioProbe = helperProcessAudioProbe
    }

    func resolveTarget(
        for request: AppAudioTargetRequest,
        allowsCachedLookup: Bool = true,
        onProgress: @escaping @Sendable (AppAudioResolutionProgress) -> Void
    ) async -> AppAudioTargetResolutionResult {
        let resolutionID = UUID()
        guard beginResolution(id: resolutionID) else {
            AppLogger.helperResolution.warning("Helper resolution rejected: already running app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public)")
            return .unavailable("Audio helper resolution is already running")
        }

        AppLogger.helperResolution.info("Helper resolution started app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public) cacheAllowed=\(allowsCachedLookup, privacy: .public)")
        defer {
            finishResolution(id: resolutionID)
        }

        let visibleEligibility = ProcessTapCoreAudio.processTapEligibility(
            for: request.processIdentifier
        )
        if visibleEligibility.isEligible {
            AppLogger.helperResolution.info("Visible app PID is Process Tap eligible app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public)")
            return .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: request.appID,
                    visibleAppName: request.appName,
                    target: ProcessTapTarget(
                        appID: request.appID,
                        appName: request.appName,
                        processIdentifier: request.processIdentifier
                    ),
                    kind: .visibleApp,
                    source: .directVisibleApp
                )
            )
        }

        if visibleEligibility.reason == ProcessTapCoreAudio.unsupportedOSMessage ||
            visibleEligibility.reason == "Missing audio capture usage description" {
            AppLogger.helperResolution.warning("Visible app PID unavailable for platform/config app=\(request.appName, privacy: .public) reason=\(visibleEligibility.reason ?? "unknown", privacy: .public)")
            return .unavailable(visibleEligibility.reason ?? "Process Tap is unavailable")
        }

        guard HelperProcessCandidateDiscovery.isLikelyHelperResolvable(request.helperDiscoveryTarget) else {
            AppLogger.helperResolution.warning("App is not helper-resolvable app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public) reason=\(visibleEligibility.reason ?? "unknown", privacy: .public)")
            return .unavailable(visibleEligibility.reason ?? "Core Audio process unavailable")
        }

        guard isCurrentResolution(resolutionID) else {
            AppLogger.helperResolution.info("Helper resolution cancelled before process listing app=\(request.appName, privacy: .public)")
            return .cancelled
        }

        let processes = await Task.detached(priority: .userInitiated) {
            self.processLister.listProcesses()
        }.value

        guard isCurrentResolution(resolutionID) else {
            AppLogger.helperResolution.info("Helper resolution cancelled after process listing app=\(request.appName, privacy: .public)")
            return .cancelled
        }

        if allowsCachedLookup,
           let cachedTarget = validatedCachedTarget(for: request, processes: processes) {
            AppLogger.helperResolution.info("Helper resolution using validated cache app=\(request.appName, privacy: .public) helperPID=\(cachedTarget.target.processIdentifier ?? -1, privacy: .public)")
            return .resolved(cachedTarget)
        }

        let eligibleCandidates = HelperProcessCandidateDiscovery
            .candidates(for: request.helperDiscoveryTarget, processes: processes)
            .filter(\.isTapEligible)

        guard !eligibleCandidates.isEmpty else {
            AppLogger.helperResolution.warning("Helper resolution found no tap-eligible candidates app=\(request.appName, privacy: .public)")
            return .unavailable("No active audio helper found")
        }

        AppLogger.helperResolution.info("Helper resolution probing candidates app=\(request.appName, privacy: .public) count=\(eligibleCandidates.count, privacy: .public)")
        var scoredCandidates: [AppAudioTargetCandidateScore] = []
        for (index, candidate) in eligibleCandidates.enumerated() {
            guard isCurrentResolution(resolutionID) else {
                AppLogger.helperResolution.info("Helper resolution cancelled before candidate probe app=\(request.appName, privacy: .public) tested=\(index, privacy: .public)")
                return .cancelled
            }

            onProgress(
                AppAudioResolutionProgress(
                    testedCandidateCount: index + 1,
                    totalCandidateCount: eligibleCandidates.count
                )
            )

            let progressBox = AppAudioResolutionProgressBox()
            let processIdentifier = candidate.process.processIdentifier
            let target = ProcessTapTarget(
                appID: "helper:\(request.appID):\(processIdentifier)",
                appName: request.appName,
                processIdentifier: processIdentifier
            )

            let result = await helperProcessAudioProbe.probeAudio(
                for: target,
                duration: AppConstants.processTapHelperAutoDetectDuration
            ) { progress in
                progressBox.update(progress)
            }

            guard isCurrentResolution(resolutionID) else {
                AppLogger.helperResolution.info("Helper resolution cancelled after candidate probe app=\(request.appName, privacy: .public) pid=\(processIdentifier, privacy: .public)")
                return .cancelled
            }

            let progress = progressBox.snapshot()
            if result.outcome == .helperProbeTargetExited ||
                result.outcome == .helperProbeOutputChanged ||
                result.outcome == .helperProbeStopped {
                AppLogger.helperResolution.info("Helper resolution probe stopped app=\(request.appName, privacy: .public) pid=\(processIdentifier, privacy: .public) outcome=\(String(describing: result.outcome), privacy: .public)")
                return .cancelled
            }

            scoredCandidates.append(
                AppAudioTargetCandidateScore(
                    candidate: candidate,
                    result: result,
                    progress: progress
                )
            )

            guard let latestScore = scoredCandidates.last else {
                continue
            }

            if latestScore.isStrongEnoughForProductFastPath {
                AppLogger.helperResolution.info("Helper resolution early-accepted candidate app=\(request.appName, privacy: .public) helperPID=\(processIdentifier, privacy: .public) rms=\(latestScore.progress.rmsLevel, privacy: .public) peak=\(latestScore.progress.peakLevel, privacy: .public)")
                cacheResolvedHelper(latestScore, for: request)
                return .resolved(resolvedHelperTarget(from: latestScore, for: request))
            }
        }

        guard let bestCandidate = scoredCandidates.max(),
              bestCandidate.hasDetectedAudio else {
            AppLogger.helperResolution.warning("Helper resolution found no active audio helper app=\(request.appName, privacy: .public) candidates=\(scoredCandidates.count, privacy: .public)")
            return .unavailable("No active audio helper found")
        }

        AppLogger.helperResolution.info("Helper resolution selected best candidate app=\(request.appName, privacy: .public) helperPID=\(bestCandidate.candidate.process.processIdentifier, privacy: .public) rms=\(bestCandidate.progress.rmsLevel, privacy: .public) peak=\(bestCandidate.progress.peakLevel, privacy: .public)")
        cacheResolvedHelper(bestCandidate, for: request)
        return .resolved(resolvedHelperTarget(from: bestCandidate, for: request))
    }

    func cancelCurrentResolution(reason: ProcessTapCandidateProbeStopReason) {
        AppLogger.helperResolution.info("Helper resolution cancellation requested reason=\(String(describing: reason), privacy: .public)")
        lock.lock()
        currentResolutionID = nil
        lock.unlock()
        helperProcessAudioProbe.stopCurrentProbe(reason: reason)
    }

    func invalidateCachedTarget(for request: AppAudioTargetRequest) {
        guard let key = AppAudioHelperResolutionCacheKey(request: request) else {
            return
        }

        lock.lock()
        cachedHelpersByKey[key] = nil
        lock.unlock()
        AppLogger.helperResolution.info("Helper cache invalidated appID=\(request.appID, privacy: .public) visiblePID=\(request.processIdentifier ?? -1, privacy: .public)")
    }

    func invalidateAllCachedTargets() {
        lock.lock()
        let cachedCount = cachedHelpersByKey.count
        cachedHelpersByKey.removeAll()
        lock.unlock()
        AppLogger.helperResolution.info("Helper cache cleared count=\(cachedCount, privacy: .public)")
    }

    private func beginResolution(id: UUID) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard currentResolutionID == nil else {
            return false
        }

        currentResolutionID = id
        return true
    }

    private func finishResolution(id: UUID) {
        lock.lock()
        if currentResolutionID == id {
            currentResolutionID = nil
        }
        lock.unlock()
    }

    private func isCurrentResolution(_ id: UUID) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        return currentResolutionID == id
    }

    private func validatedCachedTarget(
        for request: AppAudioTargetRequest,
        processes: [SystemProcessInfo]
    ) -> ResolvedAppAudioTarget? {
        guard let key = AppAudioHelperResolutionCacheKey(request: request) else {
            return nil
        }

        lock.lock()
        let cachedEntry = cachedHelpersByKey[key]
        lock.unlock()

        guard let cachedEntry else {
            AppLogger.helperResolution.info("Helper cache miss app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public)")
            return nil
        }

        guard let process = processes.first(where: { $0.processIdentifier == cachedEntry.helperProcessIdentifier }) else {
            AppLogger.helperResolution.warning("Helper cache invalid: helper process missing app=\(request.appName, privacy: .public) helperPID=\(cachedEntry.helperProcessIdentifier, privacy: .public)")
            removeCachedHelper(for: key)
            return nil
        }

        let eligibility = ProcessTapCoreAudio.processTapEligibility(for: process.processIdentifier)
        guard eligibility.isEligible else {
            AppLogger.helperResolution.warning("Helper cache invalid: helper not tap-eligible app=\(request.appName, privacy: .public) helperPID=\(process.processIdentifier, privacy: .public) reason=\(eligibility.reason ?? "unknown", privacy: .public)")
            removeCachedHelper(for: key)
            return nil
        }

        return ResolvedAppAudioTarget(
            visibleAppID: request.appID,
            visibleAppName: request.appName,
            target: ProcessTapTarget(
                appID: request.appID,
                appName: request.appName,
                processIdentifier: cachedEntry.helperProcessIdentifier
            ),
            kind: .helper,
            source: .cachedHelper
        )
    }

    private func cacheResolvedHelper(
        _ score: AppAudioTargetCandidateScore,
        for request: AppAudioTargetRequest
    ) {
        guard let key = AppAudioHelperResolutionCacheKey(request: request) else {
            return
        }

        let process = score.candidate.process
        let entry = AppAudioHelperResolutionCacheEntry(
            helperProcessIdentifier: process.processIdentifier,
            helperProcessName: process.name,
            resolvedAt: Date(),
            confidenceScore: score.confidenceScore
        )

        lock.lock()
        cachedHelpersByKey[key] = entry
        lock.unlock()
        AppLogger.helperResolution.info("Helper cache stored app=\(request.appName, privacy: .public) visiblePID=\(request.processIdentifier ?? -1, privacy: .public) helperPID=\(process.processIdentifier, privacy: .public) score=\(entry.confidenceScore, privacy: .public)")
    }

    private func resolvedHelperTarget(
        from score: AppAudioTargetCandidateScore,
        for request: AppAudioTargetRequest
    ) -> ResolvedAppAudioTarget {
        let helperPID = score.candidate.process.processIdentifier
        return ResolvedAppAudioTarget(
            visibleAppID: request.appID,
            visibleAppName: request.appName,
            target: ProcessTapTarget(
                appID: request.appID,
                appName: request.appName,
                processIdentifier: helperPID
            ),
            kind: .helper,
            source: .discoveredHelper
        )
    }

    private func removeCachedHelper(for key: AppAudioHelperResolutionCacheKey) {
        lock.lock()
        cachedHelpersByKey[key] = nil
        lock.unlock()
    }
}

private struct AppAudioTargetCandidateScore: Comparable {
    let candidate: HelperProcessCandidate
    let result: ProcessTapTestResult
    let progress: ProcessTapDiagnosticProgress

    var hasDetectedAudio: Bool {
        progress.audioDetected || result.outcome == .streamDiagnosticsDetectedAudio
    }

    var confidenceScore: Double {
        let detectedBonus = hasDetectedAudio ? 10_000 : 0
        return Double(detectedBonus) +
            (progress.rmsLevel * 1_000) +
            (progress.peakLevel * 100) +
            (Double(progress.callbackCount) / 100_000)
    }

    var isStrongEnoughForProductFastPath: Bool {
        hasDetectedAudio &&
            (
                progress.rmsLevel >= AppConstants.processTapHelperEarlyAcceptRMSLevel ||
                    progress.peakLevel >= AppConstants.processTapHelperEarlyAcceptPeakLevel
            )
    }

    static func < (lhs: AppAudioTargetCandidateScore, rhs: AppAudioTargetCandidateScore) -> Bool {
        if lhs.hasDetectedAudio != rhs.hasDetectedAudio {
            return !lhs.hasDetectedAudio && rhs.hasDetectedAudio
        }

        if lhs.progress.rmsLevel != rhs.progress.rmsLevel {
            return lhs.progress.rmsLevel < rhs.progress.rmsLevel
        }

        if lhs.progress.peakLevel != rhs.progress.peakLevel {
            return lhs.progress.peakLevel < rhs.progress.peakLevel
        }

        return lhs.progress.callbackCount < rhs.progress.callbackCount
    }
}

private struct AppAudioHelperResolutionCacheKey: Hashable, Sendable {
    let visibleAppID: String
    let visibleProcessIdentifier: Int32

    init?(request: AppAudioTargetRequest) {
        guard let processIdentifier = request.processIdentifier, processIdentifier > 0 else {
            return nil
        }

        self.visibleAppID = request.appID
        self.visibleProcessIdentifier = processIdentifier
    }
}

private struct AppAudioHelperResolutionCacheEntry: Sendable {
    let helperProcessIdentifier: Int32
    let helperProcessName: String
    let resolvedAt: Date
    let confidenceScore: Double
}

private final class AppAudioResolutionProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ProcessTapDiagnosticProgress(
        callbackCount: 0,
        peakLevel: 0,
        rmsLevel: 0,
        audioDetected: false
    )

    func update(_ progress: ProcessTapDiagnosticProgress) {
        lock.lock()
        self.progress = progress
        lock.unlock()
    }

    func snapshot() -> ProcessTapDiagnosticProgress {
        lock.lock()
        defer {
            lock.unlock()
        }

        return progress
    }
}
