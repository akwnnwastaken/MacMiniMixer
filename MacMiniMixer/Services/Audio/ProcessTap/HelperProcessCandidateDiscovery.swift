import Foundation

struct HelperProcessDiscoveryTarget: Equatable, Sendable {
    let id: String
    let name: String
    let processIdentifier: Int32?
}

enum HelperProcessCandidateDiscovery {
    static func candidates(
        for target: HelperProcessDiscoveryTarget,
        processes: [SystemProcessInfo]
    ) -> [HelperProcessCandidate] {
        guard let appPID = target.processIdentifier, appPID > 0 else {
            return []
        }

        var processByPID = Dictionary(
            uniqueKeysWithValues: processes.map { process in
                (process.processIdentifier, process)
            }
        )

        if processByPID[appPID] == nil {
            processByPID[appPID] = SystemProcessInfo(
                processIdentifier: appPID,
                parentProcessIdentifier: nil,
                name: target.name,
                executablePath: nil
            )
        }

        let candidates = processByPID.values.compactMap { process -> HelperProcessCandidate? in
            guard let relation = helperProcessRelation(
                for: process,
                selectedTarget: target,
                processByPID: processByPID
            ) else {
                return nil
            }

            return HelperProcessCandidate(
                process: process,
                relation: relation,
                eligibility: ProcessTapCoreAudio.processTapEligibility(for: process.processIdentifier)
            )
        }

        return candidates
            .sorted(by: helperProcessCandidateSort)
            .prefix(helperProcessCandidateDisplayLimit)
            .map { $0 }
    }

    static func isLikelyHelperResolvable(_ target: HelperProcessDiscoveryTarget) -> Bool {
        let searchableText = normalizedSearchText("\(target.name) \(target.id)")
        return browserSearchKeywords.contains { searchableText.contains($0) }
    }

    private static let helperProcessCandidateDisplayLimit = 30

    private static let browserSearchKeywords = [
        "safari",
        "chrome",
        "chromium",
        "youtube",
        "browser",
        "webkit",
        "arc",
        "brave",
        "edge",
        "opera"
    ]

    private static func helperProcessRelation(
        for process: SystemProcessInfo,
        selectedTarget: HelperProcessDiscoveryTarget,
        processByPID: [Int32: SystemProcessInfo]
    ) -> HelperProcessRelation? {
        guard let selectedPID = selectedTarget.processIdentifier else {
            return nil
        }

        if process.processIdentifier == selectedPID {
            return .directApp
        }

        if process.parentProcessIdentifier == selectedPID {
            return .child
        }

        if isDescendant(process, of: selectedPID, processByPID: processByPID) {
            return .descendant
        }

        if matchesHelperNameHeuristic(process, selectedTarget: selectedTarget) {
            return .nameMatch
        }

        return nil
    }

    private static func isDescendant(
        _ process: SystemProcessInfo,
        of rootPID: Int32,
        processByPID: [Int32: SystemProcessInfo]
    ) -> Bool {
        var visitedPIDs = Set<Int32>()
        var parentPID = process.parentProcessIdentifier

        for _ in 0..<64 {
            guard let currentPID = parentPID,
                  visitedPIDs.insert(currentPID).inserted else {
                return false
            }

            if currentPID == rootPID {
                return true
            }

            parentPID = processByPID[currentPID]?.parentProcessIdentifier
        }

        return false
    }

    private static func matchesHelperNameHeuristic(
        _ process: SystemProcessInfo,
        selectedTarget: HelperProcessDiscoveryTarget
    ) -> Bool {
        let candidateText = normalizedSearchText(
            "\(process.name) \(process.executablePath ?? "")"
        )
        let keywords = helperDiscoveryKeywords(for: selectedTarget)

        return keywords.contains { keyword in
            candidateText.contains(keyword)
        }
    }

    private static func helperDiscoveryKeywords(for target: HelperProcessDiscoveryTarget) -> [String] {
        let selectedText = normalizedSearchText("\(target.name) \(target.id)")

        if selectedText.contains("safari") || selectedText.contains("webkit") {
            return ["safari", "webkit", "webcontent", "com.apple.webkit"]
        }

        if selectedText.contains("chrome") ||
            selectedText.contains("chromium") ||
            selectedText.contains("brave") ||
            selectedText.contains("edge") ||
            selectedText.contains("arc") ||
            selectedText.contains("opera") {
            return [
                "chrome helper",
                "chrome",
                "chromium",
                "renderer",
                "gpu",
                "utility",
                "audio",
                "brave",
                "edge",
                "arc",
                "opera"
            ]
        }

        if selectedText.contains("youtube") {
            return [
                "youtube",
                "safari",
                "webkit",
                "webcontent",
                "chrome helper",
                "chrome",
                "chromium",
                "renderer",
                "gpu",
                "utility",
                "audio"
            ]
        }

        return selectedText
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 }
            .prefix(3)
            .map { $0 }
    }

    private static func helperProcessCandidateSort(
        lhs: HelperProcessCandidate,
        rhs: HelperProcessCandidate
    ) -> Bool {
        if lhs.relation.sortPriority != rhs.relation.sortPriority {
            return lhs.relation.sortPriority < rhs.relation.sortPriority
        }

        if lhs.isTapEligible != rhs.isTapEligible {
            return lhs.isTapEligible && !rhs.isTapEligible
        }

        let nameComparison = lhs.process.name.localizedCaseInsensitiveCompare(rhs.process.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        return lhs.process.processIdentifier < rhs.process.processIdentifier
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
