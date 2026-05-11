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
            executablePath: executablePath
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
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}
