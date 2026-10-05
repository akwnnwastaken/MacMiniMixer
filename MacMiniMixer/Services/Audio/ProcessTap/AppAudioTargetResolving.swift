import Foundation

struct AppAudioTargetRequest: Equatable, Sendable {
    /// Another running app row, reduced to what per-app process matching needs.
    struct OtherRunningApp: Equatable, Sendable {
        let processIdentifier: Int32?
        /// From a `bundle:<id>` row id; nil for executable/pid-based rows.
        let bundleIdentifier: String?
    }

    let appID: String
    let appName: String
    let processIdentifier: Int32?
    /// Every *other* running app row (never this one), so `AppAudioProcessMatcher` never hands this
    /// row a process that plainly belongs to another row and holds back Safari's WebKit fallback
    /// while a Safari web app runs. Empty by default (no such exclusions). Not part of the helper
    /// cache key.
    var otherRunningApps: [OtherRunningApp] = []

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
        /// The app's visible process plus its other audio processes (helpers, WebKit GPU process,
        /// children), tapped together in one multi-process tap.
        case audioProcessGroup
    }

    enum Source: Equatable, Sendable {
        case directVisibleApp
        case discoveredHelper
        case cachedHelper
        /// Matched from the HAL's own process object list (`AppAudioProcessMatcher`), no probing.
        case matchedAudioProcesses
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

    /// Synchronous and probe-free: the pids of every Core Audio process object that belongs to the
    /// app in `request` (see `AppAudioProcessMatcher`), best match first; empty when none does. Used
    /// by the Product Real start path to widen a visible-PID target to the app's audio helpers.
    func matchedAudioProcessIdentifiers(for request: AppAudioTargetRequest) -> [Int32]
}

extension AppAudioTargetResolving {
    /// Default: no process-object matching (keeps simple resolvers and test fakes single-process).
    func matchedAudioProcessIdentifiers(for request: AppAudioTargetRequest) -> [Int32] {
        []
    }
}

/// Pure (no Core Audio, no syscalls) matcher from a visible app row to the Core Audio process
/// objects that render its audio, using the HAL's own list of client processes plus each process's
/// parent and resource coalition (`SystemProcessInfo`). The first rule that applies decides:
///   1. its pid is the app's pid → match;
///   -  its pid is another running row's own app pid (`AppAudioTargetRequest.otherRunningApps`) →
///      never a match (that process is the other row's, even as a child or coalition member);
///   2. its pid descends from the app's pid (parent chain, cycle-safe) → match — Chromium /
///      Electron / Firefox helpers are children of the main process;
///   3. **resource coalition**, when both the app process's and the object's ids are known: match
///      iff they are equal. macOS runs the XPC services an app uses (WebKit GPU / WebContent /
///      Networking) and the helpers it spawns in the app's resource coalition, so Safari's WebKit
///      GPU process goes to Safari and a Safari web app's (`com.apple.Safari.WebApp.<UUID>`) to that
///      web app; Chrome, a Chrome PWA shim and Chrome Canary each keep their own. Authoritative: no
///      bundle-id rule is consulted in this mode;
///   4. bundle-id fallback, only when a coalition id is unknown (for the app or the object), and
///      never for an object whose bundle id is exactly another running row's:
///      - its bundle id equals the app's (from a `bundle:<id>` row id) or names one of its helpers
///        (`isHelperBundleIdentifier`: `<app>.helper`, `<app>.helper.*`, `<app>.framework.*`); a
///        sub-app (`<app>.app.*`, `<app>.WebApp.*`) or sibling channel (`<app>.canary`, `.beta`,
///        `.dev`) is not a helper;
///      - Safari / Safari Technology Preview only: a `com.apple.WebKit.*` process (launched by
///        launchd, so neither descendant nor helper-named), unless another running row owns WebKit
///        processes of its own (`isKnownWebKitProcessOwner`: a Safari web app or the other Safari
///        flavor) — then they could be that row's, so they are withheld (and logged).
/// MacMiniMixer's own pid is never included. Results are sorted running-output first, then by pid,
/// and deduplicated by pid.
/// Known limit: two rows whose apps share one coalition (e.g. an app started from Terminal, or a
/// game spawned by its launcher) both match that coalition's helpers; the start path's "never tap a
/// process twice" exclusion then gives each helper to whichever row starts first.
enum AppAudioProcessMatcher {
    static let safariBundleIdentifiers: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview"
    ]

    static let webKitBundleIdentifierPrefix = "com.apple.webkit."

    /// Safari web apps (macOS 14+ "Add to Dock"), lowercased: `com.apple.Safari.WebApp.<UUID>`, each
    /// its own app process with its own WebKit GPU / WebContent / Networking processes.
    static let safariWebAppBundleIdentifierPrefix = "com.apple.safari.webapp."

    private static let bundleAppIDPrefix = "bundle:"

    /// Whether `candidateBundleIdentifier` names a helper process of the app `appBundleIdentifier`
    /// (case-insensitive): `<app>.helper` and `<app>.helper.<kind>` — the Chromium (Chrome, Edge,
    /// Brave, Arc, Opera, Vivaldi) and Electron (Discord, Slack, VS Code, Spotify) helper naming,
    /// e.g. `.helper.renderer` / `.helper.gpu` / `.helper.plugin` / `.helper.alerts` — or
    /// `<app>.framework.<service>` (Chrome's `framework.AlertNotificationService`). A bare shared
    /// prefix (`com.google.ChromeRemoteDesktop`), a sub-app (`com.google.Chrome.app.<id>` PWA shims,
    /// `com.apple.Safari.WebApp.<UUID>`) and a sibling channel (`com.google.Chrome.canary`, `.beta`,
    /// `.dev`, `com.brave.Browser.nightly`) are not helpers.
    static func isHelperBundleIdentifier(_ candidateBundleIdentifier: String, ofApp appBundleIdentifier: String) -> Bool {
        let candidate = candidateBundleIdentifier.lowercased()
        let appPrefix = appBundleIdentifier.lowercased() + "."
        guard candidate.hasPrefix(appPrefix) else {
            return false
        }

        let components = candidate
            .dropFirst(appPrefix.count)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { String($0) }
        guard let firstComponent = components.first else {
            return false
        }

        switch firstComponent {
        case "helper":
            return true
        case "framework":
            return components.count > 1
        default:
            return false
        }
    }

    /// Whether a running app with this bundle id (case-insensitive) owns WebKit processes of its own
    /// that a Safari row's bundle-id fallback could otherwise take: a Safari web app, or a Safari
    /// flavor (Safari / Safari Technology Preview, i.e. the other one when both run).
    static func isKnownWebKitProcessOwner(_ bundleIdentifier: String) -> Bool {
        let normalizedBundleIdentifier = bundleIdentifier.lowercased()
        return normalizedBundleIdentifier.hasPrefix(safariWebAppBundleIdentifierPrefix) ||
            safariBundleIdentifiers.contains(normalizedBundleIdentifier)
    }

    /// The process's resource coalition id, treating a missing process, nil and 0 as unknown.
    private static func knownResourceCoalitionID(of process: SystemProcessInfo?) -> UInt64? {
        guard let coalitionID = process?.resourceCoalitionID, coalitionID != 0 else {
            return nil
        }

        return coalitionID
    }

    /// The bundle identifier encoded in a `WorkspaceApplicationLister` row id (`bundle:<id>`), or nil
    /// for executable/pid-based ids.
    static func bundleIdentifier(forAppID appID: String) -> String? {
        guard appID.hasPrefix(bundleAppIDPrefix) else {
            return nil
        }

        let bundleIdentifier = String(appID.dropFirst(bundleAppIDPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bundleIdentifier.isEmpty ? nil : bundleIdentifier
    }

    static func matchingProcessObjects(
        for request: AppAudioTargetRequest,
        processObjects: [AudioProcessObjectInfo],
        processes: [SystemProcessInfo],
        ownProcessIdentifier: Int32
    ) -> [AudioProcessObjectInfo] {
        let appProcessIdentifier = request.processIdentifier.flatMap { $0 > 0 ? $0 : nil }
        let appBundleIdentifier = bundleIdentifier(forAppID: request.appID)?.lowercased()
        guard appProcessIdentifier != nil || appBundleIdentifier != nil else {
            return []
        }

        let processByPID = Dictionary(
            processes.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let appCoalitionID = appProcessIdentifier.flatMap { knownResourceCoalitionID(of: processByPID[$0]) }

        // Other rows' own app pids and exact bundle ids. An entry for this very app (same pid or
        // bundle id, e.g. a duplicate row) is ignored, so it can never exclude the app's own processes.
        var otherAppProcessIdentifiers = Set<Int32>()
        var otherAppBundleIdentifiers = Set<String>()
        for otherApp in request.otherRunningApps {
            if let otherProcessIdentifier = otherApp.processIdentifier,
               otherProcessIdentifier > 0,
               otherProcessIdentifier != appProcessIdentifier {
                otherAppProcessIdentifiers.insert(otherProcessIdentifier)
            }

            if let otherBundleIdentifier = otherApp.bundleIdentifier?.lowercased(),
               !otherBundleIdentifier.isEmpty,
               otherBundleIdentifier != appBundleIdentifier {
                otherAppBundleIdentifiers.insert(otherBundleIdentifier)
            }
        }

        let isSafari = appBundleIdentifier.map { safariBundleIdentifiers.contains($0) } ?? false
        // Fallback-only guard: another running row with WebKit processes of its own (a Safari web
        // app, the other Safari flavor) means a WebKit process cannot be assumed to be Safari's.
        let webKitOwningOtherAppBundleIdentifier = isSafari
            ? otherAppBundleIdentifiers.sorted().first(where: { isKnownWebKitProcessOwner($0) })
            : nil

        var matches: [AudioProcessObjectInfo] = []
        var withheldWebKitProcessIdentifiers: [Int32] = []
        for object in processObjects {
            let objectPID = object.processIdentifier
            guard objectPID > 0, objectPID != ownProcessIdentifier else {
                continue
            }

            // 1. The app's own process.
            if objectPID == appProcessIdentifier {
                matches.append(object)
                continue
            }

            // Another row's own app process belongs to that row, whatever the rules below say (a
            // child app, or a coalition shared with a launcher).
            if otherAppProcessIdentifiers.contains(objectPID) {
                continue
            }

            let objectProcess = processByPID[objectPID]

            // 2. Descendants of the app's process.
            if let appProcessIdentifier,
               let objectProcess,
               HelperProcessCandidateDiscovery.isDescendant(
                objectProcess,
                of: appProcessIdentifier,
                processByPID: processByPID
               ) {
                matches.append(object)
                continue
            }

            // 3. Resource coalition: authoritative whenever both ids are known.
            if let appCoalitionID,
               let objectCoalitionID = knownResourceCoalitionID(of: objectProcess) {
                if objectCoalitionID == appCoalitionID {
                    matches.append(object)
                }
                continue
            }

            // 4. Bundle-id fallback (a coalition id is unknown). Never another row's exact bundle id.
            guard let appBundleIdentifier,
                  let objectBundleIdentifier = object.bundleIdentifier?.lowercased(),
                  !otherAppBundleIdentifiers.contains(objectBundleIdentifier) else {
                continue
            }

            if objectBundleIdentifier == appBundleIdentifier ||
                isHelperBundleIdentifier(objectBundleIdentifier, ofApp: appBundleIdentifier) {
                matches.append(object)
                continue
            }

            if isSafari, objectBundleIdentifier.hasPrefix(webKitBundleIdentifierPrefix) {
                if webKitOwningOtherAppBundleIdentifier == nil {
                    matches.append(object)
                } else {
                    withheldWebKitProcessIdentifiers.append(objectPID)
                }
            }
        }

        if let webKitOwningOtherAppBundleIdentifier, !withheldWebKitProcessIdentifiers.isEmpty {
            let withheldPIDs = withheldWebKitProcessIdentifiers.map { String($0) }.joined(separator: ",")
            AppLogger.helperResolution.info("Safari WebKit fallback withheld processes app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public) withheldPIDs=\(withheldPIDs, privacy: .public) otherWebKitOwner=\(webKitOwningOtherAppBundleIdentifier, privacy: .public) reason=coalitionUnknown")
        }

        let sortedMatches = matches.sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput
            }

            return lhs.processIdentifier < rhs.processIdentifier
        }

        var seenProcessIdentifiers = Set<Int32>()
        var uniqueMatches: [AudioProcessObjectInfo] = []
        for match in sortedMatches {
            if seenProcessIdentifiers.insert(match.processIdentifier).inserted {
                uniqueMatches.append(match)
            }
        }
        return uniqueMatches
    }

    /// The multi-process target for `request` over `matchedProcessIdentifiers`, or nil when nothing
    /// matched. The visible app's pid stays the primary process whenever it is valid — the live
    /// controller watches the primary pid for app exit, and a browser can restart its audio helper —
    /// and every other matched pid is additional. Without a valid visible pid the first match is
    /// primary.
    static func target(
        for request: AppAudioTargetRequest,
        matchedProcessIdentifiers: [Int32]
    ) -> ProcessTapTarget? {
        let validMatches = matchedProcessIdentifiers.filter { $0 > 0 }
        guard let firstMatch = validMatches.first else {
            return nil
        }

        let primary: Int32
        if let visibleProcessIdentifier = request.processIdentifier, visibleProcessIdentifier > 0 {
            primary = visibleProcessIdentifier
        } else {
            primary = firstMatch
        }

        var additional: [Int32] = []
        for processIdentifier in validMatches where processIdentifier != primary && !additional.contains(processIdentifier) {
            additional.append(processIdentifier)
        }

        return ProcessTapTarget(
            appID: request.appID,
            appName: request.appName,
            processIdentifier: primary,
            additionalProcessIdentifiers: additional
        )
    }

    /// Shown when an app has no Core Audio process object yet and is not a known browser: a process
    /// only joins the HAL's list after it has used audio.
    static func playAudioFirstMessage(appName: String) -> String {
        "No audio from \(appName) yet. Start playing audio in it, then try again."
    }
}

final class HelperAudioTargetResolver: AppAudioTargetResolving, @unchecked Sendable {
    private let processLister: ProcessListing
    private let helperProcessAudioProbe: ProcessTapCandidateAudioProbing
    private let processTapEligibility: @Sendable (Int32?) -> ProcessTapProcessEligibility
    private let audioProcessObjectLister: AudioProcessObjectListing
    private let ownProcessIdentifier: Int32
    private let lock = NSLock()
    private var currentResolutionID: UUID?
    private var cachedHelpersByKey: [AppAudioHelperResolutionCacheKey: AppAudioHelperResolutionCacheEntry] = [:]

    init(
        processLister: ProcessListing,
        helperProcessAudioProbe: ProcessTapCandidateAudioProbing,
        processTapEligibility: @escaping @Sendable (Int32?) -> ProcessTapProcessEligibility = {
            ProcessTapCoreAudio.processTapEligibility(for: $0)
        },
        audioProcessObjectLister: AudioProcessObjectListing = CoreAudioProcessObjectLister(),
        ownProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.processLister = processLister
        self.helperProcessAudioProbe = helperProcessAudioProbe
        self.processTapEligibility = processTapEligibility
        self.audioProcessObjectLister = audioProcessObjectLister
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    func matchedAudioProcessIdentifiers(for request: AppAudioTargetRequest) -> [Int32] {
        let processObjects = audioProcessObjectLister.listAudioProcessObjects()
        guard !processObjects.isEmpty else {
            return []
        }

        // The app's own pid is listed too, so its resource coalition is known even when the app
        // process itself is not a HAL client (Safari: only its WebKit processes are).
        var listedProcessIdentifiers = processObjects.map(\.processIdentifier)
        if let appProcessIdentifier = request.processIdentifier, appProcessIdentifier > 0 {
            listedProcessIdentifiers.append(appProcessIdentifier)
        }
        let processes = processLister.listProcessAncestry(of: listedProcessIdentifiers)
        let matches = AppAudioProcessMatcher.matchingProcessObjects(
            for: request,
            processObjects: processObjects,
            processes: processes,
            ownProcessIdentifier: ownProcessIdentifier
        )
        if !matches.isEmpty {
            // pid/bundle id/resource coalition of every match, so a field log shows why each process
            // was attributed to this app (coalition "?" = unknown, i.e. the bundle-id fallback).
            let processByPID = Dictionary(
                processes.map { ($0.processIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let matchedDescription = matches.map { match -> String in
                let coalition = processByPID[match.processIdentifier]?.resourceCoalitionID.map { String($0) } ?? "?"
                return "\(match.processIdentifier):\(match.bundleIdentifier ?? "-"):\(coalition)"
            }.joined(separator: ",")
            let appCoalition = request.processIdentifier
                .flatMap { processByPID[$0]?.resourceCoalitionID }
                .map { String($0) } ?? "?"
            AppLogger.helperResolution.info("Audio process objects matched app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public) appCoalition=\(appCoalition, privacy: .public) matched=\(matchedDescription, privacy: .public) halObjects=\(processObjects.count, privacy: .public) otherApps=\(request.otherRunningApps.count, privacy: .public)")
        }
        return matches.map(\.processIdentifier)
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

        let visibleEligibility = processTapEligibility(request.processIdentifier)

        // Platform/configuration problems block every Process Tap, matched or not. (An eligible
        // visible PID never carries one of these reasons, so checking them first changes nothing
        // for the direct path.)
        if visibleEligibility.reason == ProcessTapCoreAudio.unsupportedOSMessage ||
            visibleEligibility.reason == ProcessTapPermissionMessage.missingUsageDescriptionReason {
            AppLogger.helperResolution.warning("Visible app PID unavailable for platform/config app=\(request.appName, privacy: .public) reason=\(visibleEligibility.reason ?? "unknown", privacy: .public)")
            return .unavailable(
                ProcessTapPermissionMessage.message(
                    forEligibilityReason: visibleEligibility.reason,
                    fallback: visibleEligibility.reason ?? "Process Tap is unavailable"
                )
            )
        }

        // First ask the HAL which of its client processes belong to this app (main process, helper
        // children, the app's resource coalition — its WebKit / helper processes — or, when a
        // coalition is unknown, its bundle-id helpers; see `AppAudioProcessMatcher`). A match
        // resolves at once, without probing, and also wins over an eligible visible PID: a
        // Chromium/Electron main process can be a Core Audio client while its helper renders the
        // actual audio.
        // Deliberately not cached: re-matching is cheap and avoids stale helper PIDs.
        let matchedProcessIdentifiers = await Task.detached(priority: .userInitiated) {
            self.matchedAudioProcessIdentifiers(for: request)
        }.value

        guard isCurrentResolution(resolutionID) else {
            AppLogger.helperResolution.info("Helper resolution cancelled after audio process matching app=\(request.appName, privacy: .public)")
            return .cancelled
        }

        if let matchedTarget = AppAudioProcessMatcher.target(
            for: request,
            matchedProcessIdentifiers: matchedProcessIdentifiers
        ) {
            let isVisibleProcessOnly = matchedTarget.additionalProcessIdentifiers.isEmpty &&
                matchedTarget.processIdentifier == request.processIdentifier
            AppLogger.helperResolution.info("Helper resolution matched audio processes app=\(request.appName, privacy: .public) primaryPID=\(matchedTarget.processIdentifier ?? -1, privacy: .public) additionalCount=\(matchedTarget.additionalProcessIdentifiers.count, privacy: .public)")
            return .resolved(
                ResolvedAppAudioTarget(
                    visibleAppID: request.appID,
                    visibleAppName: request.appName,
                    target: matchedTarget,
                    kind: isVisibleProcessOnly ? .visibleApp : .audioProcessGroup,
                    source: isVisibleProcessOnly ? .directVisibleApp : .matchedAudioProcesses
                )
            )
        }

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

        // Nothing in the HAL list belongs to this app yet. Known browsers still get the probe-based
        // helper search below; any other app simply has not used audio since it launched (a process
        // only joins the HAL list once it has), so ask the user to play something first.
        guard HelperProcessCandidateDiscovery.isLikelyHelperResolvable(request.helperDiscoveryTarget) else {
            AppLogger.helperResolution.warning("App has no matched audio process and is not helper-resolvable app=\(request.appName, privacy: .public) pid=\(request.processIdentifier ?? -1, privacy: .public) reason=\(visibleEligibility.reason ?? "unknown", privacy: .public)")
            return .unavailable(AppAudioProcessMatcher.playAudioFirstMessage(appName: request.appName))
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
            .candidates(
                for: request.helperDiscoveryTarget,
                processes: processes,
                eligibilityChecker: { processTapEligibility($0) }
            )
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

        let eligibility = processTapEligibility(process.processIdentifier)
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
