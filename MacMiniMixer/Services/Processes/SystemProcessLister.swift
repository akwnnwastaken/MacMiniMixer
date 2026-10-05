import Darwin
import Foundation

struct SystemProcessLister: ProcessListing {
    private let pidPathBufferSize = 4096

    func listProcesses() -> [SystemProcessInfo] {
        let pidBufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidBufferSize > 0 else {
            return []
        }

        let pidCapacity = Int(pidBufferSize) / MemoryLayout<pid_t>.stride
        guard pidCapacity > 0 else {
            return []
        }

        var pids = [pid_t](repeating: 0, count: pidCapacity)
        let returnedByteCount = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }

        guard returnedByteCount > 0 else {
            return []
        }

        let returnedCount = min(Int(returnedByteCount) / MemoryLayout<pid_t>.stride, pids.count)

        return pids.prefix(returnedCount)
            .filter { $0 > 0 }
            .compactMap(processInfo(for:))
            .sorted { first, second in
                first.processIdentifier < second.processIdentifier
            }
    }

    /// Walks only the parent chains of `processIdentifiers` (one `proc_pidinfo` per hop, bounded and
    /// cycle-safe) instead of listing every process, so the synchronous product start path can check
    /// descendants cheaply. Names are best-effort (`proc_name`, else empty).
    func listProcessAncestry(of processIdentifiers: [Int32]) -> [SystemProcessInfo] {
        var processByPID: [Int32: SystemProcessInfo] = [:]

        for processIdentifier in processIdentifiers where processIdentifier > 0 {
            var currentPID: Int32? = processIdentifier
            for _ in 0..<64 {
                guard let pid = currentPID, pid > 0, processByPID[pid] == nil else {
                    break
                }

                let parentPID = parentProcessIdentifier(for: pid_t(pid))
                processByPID[pid] = SystemProcessInfo(
                    processIdentifier: pid,
                    parentProcessIdentifier: parentPID,
                    name: processName(for: pid_t(pid)) ?? "",
                    executablePath: nil,
                    resourceCoalitionID: resourceCoalitionID(for: pid_t(pid))
                )
                currentPID = parentPID
            }
        }

        return processByPID.values.sorted { first, second in
            first.processIdentifier < second.processIdentifier
        }
    }

    private func processInfo(for pid: pid_t) -> SystemProcessInfo? {
        let name = processName(for: pid)
        let executablePath = processPath(for: pid)

        guard let displayName = name ?? executablePath?.lastPathComponent,
              !displayName.isEmpty else {
            return nil
        }

        return SystemProcessInfo(
            processIdentifier: Int32(pid),
            parentProcessIdentifier: parentProcessIdentifier(for: pid),
            name: displayName,
            executablePath: executablePath,
            resourceCoalitionID: resourceCoalitionID(for: pid)
        )
    }

    private func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }

        guard status > 0 else {
            return nil
        }

        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pidPathBufferSize)
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }

        guard status > 0 else {
            return nil
        }

        let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func parentProcessIdentifier(for pid: pid_t) -> Int32? {
        var info = proc_bsdinfo()
        let resultSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )
        }

        guard resultSize == Int32(MemoryLayout<proc_bsdinfo>.stride),
              info.pbi_ppid > 0 else {
            return nil
        }

        return Int32(info.pbi_ppid)
    }

    // MARK: - Resource coalition
    //
    // `proc_pidinfo` (public libproc) with flavor `PROC_PIDCOALITIONINFO` returns
    // `struct proc_pidcoalitioninfo { uint64_t coalition_id[COALITION_NUM_TYPES]; uint64_t reserved1,
    // reserved2, reserved3; }`. Verified against XNU (apple-oss-distributions/xnu):
    //   - `bsd/sys/proc_info_private.h`: `#define PROC_PIDCOALITIONINFO 20` and the struct above;
    //   - `osfmk/mach/coalition.h`: `COALITION_TYPE_RESOURCE (0)`, `COALITION_TYPE_JETSAM (1)`,
    //     `COALITION_NUM_TYPES (COALITION_TYPE_MAX + 1)` = 2 — so the struct is 5 x uint64_t = 40 bytes;
    //   - `bsd/kern/proc_info.c`: the flavor needs no same-user check, zero-fills the struct, fills
    //     `coalition_id` from the process's coalitions, and returns `sizeof(struct
    //     proc_pidcoalitioninfo)` (40) on success.
    // The flavor and struct live in XNU's *private* proc_info header, so the macOS SDK's Swift overlay
    // does not expose them; the raw flavor value and a 5-word buffer mirror them here instead. A
    // failed or short read, or a 0 id, yields nil (unknown), and process matching then falls back to
    // the bundle-id rules.

    /// `PROC_PIDCOALITIONINFO` (XNU `bsd/sys/proc_info_private.h`).
    private static let coalitionInfoFlavor: Int32 = 20
    /// `struct proc_pidcoalitioninfo`: `coalition_id[2]` + three reserved words, all `uint64_t`.
    static let coalitionInfoWordCount = 5
    /// `COALITION_TYPE_RESOURCE` (XNU `osfmk/mach/coalition.h`): index into `coalition_id`.
    private static let resourceCoalitionTypeIndex = 0

    private func resourceCoalitionID(for pid: pid_t) -> UInt64? {
        var words = [UInt64](repeating: 0, count: SystemProcessLister.coalitionInfoWordCount)
        let bufferSize = Int32(SystemProcessLister.coalitionInfoWordCount * MemoryLayout<UInt64>.size)
        let resultSize = words.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                pid,
                SystemProcessLister.coalitionInfoFlavor,
                0,
                buffer.baseAddress,
                bufferSize
            )
        }

        return SystemProcessLister.resourceCoalitionID(
            fromCoalitionInfoWords: words,
            returnedByteCount: resultSize
        )
    }

    /// Parses a `proc_pidcoalitioninfo` read: the resource coalition id, or nil when the read failed
    /// or was short (`returnedByteCount` below the 40-byte struct size), or when the id is 0 (no
    /// coalition). Pure, so it is unit-tested.
    static func resourceCoalitionID(
        fromCoalitionInfoWords words: [UInt64],
        returnedByteCount: Int32
    ) -> UInt64? {
        let expectedByteCount = coalitionInfoWordCount * MemoryLayout<UInt64>.size
        guard Int(returnedByteCount) >= expectedByteCount,
              words.count > resourceCoalitionTypeIndex else {
            return nil
        }

        let coalitionID = words[resourceCoalitionTypeIndex]
        return coalitionID == 0 ? nil : coalitionID
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}
