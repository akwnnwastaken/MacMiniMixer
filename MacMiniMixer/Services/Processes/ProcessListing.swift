import Foundation

protocol ProcessListing: Sendable {
    func listProcesses() -> [SystemProcessInfo]

    /// Enough processes to walk the parent chain of every pid in `processIdentifiers`: each of
    /// those processes plus all of its ancestors (name/path may be left empty). Used for cheap
    /// "is this pid a descendant of the app?" checks. The default lists every process.
    func listProcessAncestry(of processIdentifiers: [Int32]) -> [SystemProcessInfo]
}

extension ProcessListing {
    func listProcessAncestry(of processIdentifiers: [Int32]) -> [SystemProcessInfo] {
        listProcesses()
    }
}

struct SystemProcessInfo: Identifiable, Equatable, Sendable {
    var id: Int32 { processIdentifier }

    let processIdentifier: Int32
    let parentProcessIdentifier: Int32?
    let name: String
    let executablePath: String?
}

enum HelperProcessRelation: String, Equatable, Sendable {
    case directApp
    case child
    case descendant
    case nameMatch
    case unknown

    var label: String {
        switch self {
        case .directApp:
            return "Direct app"
        case .child:
            return "Child"
        case .descendant:
            return "Descendant"
        case .nameMatch:
            return "Name match"
        case .unknown:
            return "Unknown"
        }
    }

    var sortPriority: Int {
        switch self {
        case .directApp:
            return 0
        case .child:
            return 1
        case .descendant:
            return 2
        case .nameMatch:
            return 3
        case .unknown:
            return 4
        }
    }
}

struct HelperProcessCandidate: Identifiable, Equatable, Sendable {
    var id: Int32 { process.processIdentifier }

    let process: SystemProcessInfo
    let relation: HelperProcessRelation
    let eligibility: ProcessTapProcessEligibility

    var isTapEligible: Bool {
        eligibility.isEligible
    }
}
