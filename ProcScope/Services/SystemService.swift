import Foundation
import Darwin

struct CommandResult: Sendable {
    let output: String
    let status: Int32
}

enum SystemServiceError: LocalizedError {
    case failed(String)
    case staleProcess
    case protectedProcess
    case permissionDenied
    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .staleProcess: "这个进程已经退出或发生变化。请刷新列表后重新选择。"
        case .protectedProcess: "系统进程、其他用户进程及 ProcScope 自身不支持在此操作。"
        case .permissionDenied: "macOS 拒绝了这个操作。该进程可能受系统保护。"
        }
    }
}

enum SystemService {
    static func readIdentity(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(procscope_path_buffer_size()))
        let size = UInt32(buffer.count)
        guard proc_pidpath(pid, &buffer, size) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func fetchProcesses() throws -> [ProcessRecord] {
        let result = try CommandRunner.run("/bin/ps", ["-ww", "-axo", "pid=,ppid=,uid=,%cpu=,rss=,state=,etime=,comm="])
        guard result.status == 0 else { throw SystemServiceError.failed("无法读取进程列表：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return parseProcesses(result.output).map { process in
            var process = process
            process.identity = readIdentity(pid: process.pid)
            process.executable = executablePath(pid: process.pid) ?? process.executable
            return process
        }
    }

    static func parseProcesses(_ output: String) -> [ProcessRecord] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(maxSplits: 7, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard columns.count == 8,
                  let pid = Int32(columns[0]), let parent = Int32(columns[1]),
                  let uid = UInt32(columns[2]), let cpu = Double(columns[3]),
                  let rss = UInt64(columns[4]), rss <= UInt64.max / 1024 else { return nil }
            return ProcessRecord(pid: pid, parentPID: parent, uid: uid, cpu: cpu,
                                 memoryBytes: rss * 1024, rawState: String(columns[5]),
                                 elapsed: String(columns[6]), executable: String(columns[7]), identity: nil)
        }
    }

    static func fetchPorts() throws -> [PortRecord] {
        // Bracket the scan: a PID reused during lsof must not inherit an old socket.
        let capacity = max(proc_listallpids(nil, 0) + 256, 1024)
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        let before = pids.prefix(max(0, min(Int(count), pids.count))).reduce(into: [Int32: ProcessIdentity]()) { result, pid in
            result[pid] = readIdentity(pid: pid)
        }
        let result = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpcfPnT"], timeout: 10)
        // lsof returns 1 when no matching sockets are visible.
        guard result.status == 0 || (result.status == 1 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw SystemServiceError.failed("端口扫描未完成。部分进程可能受系统权限限制，请重试。")
        }
        return parsePorts(result.output).map { socket in
            var socket = socket
            if let identity = before[socket.pid], readIdentity(pid: socket.pid) == identity {
                socket.identity = identity
            }
            return socket
        }
    }

    static func parsePorts(_ output: String) -> [PortRecord] {
        var pid: Int32 = 0
        var name = ""
        var transport = ""
        var address = ""
        var state = ""
        var results: [PortRecord] = []
        var seen = Set<String>()
        func flush() {
            guard pid > 0, !address.isEmpty, !address.contains("->"),
                  transport == "UDP" || (transport == "TCP" && state == "LISTEN") else { return }
            let record = PortRecord(pid: pid, processName: name, transport: transport, address: address)
            guard let port = record.port, (1...65535).contains(port) else { return }
            if seen.insert(record.id).inserted { results.append(record) }
        }
        for line in output.split(separator: "\n") {
            guard let type = line.first else { continue }
            let value = String(line.dropFirst())
            switch type {
            case "p":
                flush(); pid = Int32(value) ?? 0; name = ""; transport = ""; address = ""; state = ""
            case "c": name = value
            case "f": flush(); transport = ""; address = ""; state = ""
            case "P": transport = value
            case "n": address = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return results.sorted { ($0.port ?? 0, $0.pid, $0.address) < ($1.port ?? 0, $1.pid, $1.address) }
    }

    static func fetchDetail(for target: ProcessRecord) throws -> ProcessDetail {
        guard let identity = target.identity, readIdentity(pid: target.pid) == identity else { throw SystemServiceError.staleProcess }
        var warnings: [String] = []
        let command = commandLine(pid: target.pid)
        let directory = workingDirectory(pid: target.pid)
        if command == nil { warnings.append("启动命令不可读取，可能受进程权限限制。") }
        if directory == nil { warnings.append("工作目录不可读取，可能受进程权限限制。") }
        guard readIdentity(pid: target.pid) == identity else { throw SystemServiceError.staleProcess }
        return ProcessDetail(identity: identity,
                             command: command,
                             workingDirectory: directory, warnings: warnings)
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    static func commandLine(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4 * 1024 * 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(bytes.prefix(size)))
    }

    static func parseArguments(_ bytes: [UInt8]) -> String? {
        guard bytes.count > 4 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= bytes.count else { return nil }
        var position = 4
        while position < bytes.count && bytes[position] != 0 { position += 1 }
        while position < bytes.count && bytes[position] == 0 { position += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard position < bytes.count else { return nil }
            let start = position
            while position < bytes.count && bytes[position] != 0 { position += 1 }
            guard position < bytes.count else { return nil }
            let argument = String(decoding: bytes[start..<position], as: UTF8.self)
            // Preserve argument boundaries; never read the environment after argc.
            arguments.append(argument.isEmpty || argument.contains(where: { $0.isWhitespace || "'\"\\".contains($0) })
                             ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" : argument)
            position += 1
        }
        return arguments.joined(separator: " ")
    }

    static func validatePort(_ port: PortRecord, target: ProcessRecord) throws {
        guard let identity = port.identity, identity == target.identity else { throw SystemServiceError.staleProcess }
        try validateTarget(target)
        let sockets = try fetchPorts()
        guard sockets.contains(where: { $0.id == port.id && $0.identity == identity }) else { throw SystemServiceError.staleProcess }
        try validateTarget(target)
    }

    enum ObservedState { case exited, paused, running, unknown }
    static func observedState(of target: ProcessRecord) -> ObservedState {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(target.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return Darwin.kill(target.pid, 0) == -1 && errno == ESRCH ? .exited : .unknown
        }
        let identity = ProcessIdentity(pid: target.pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        if identity != target.identity || info.pbi_status == SZOMB { return .exited }
        return info.pbi_status == SSTOP ? .paused : .running
    }

    static func actionBlockReason(for target: ProcessRecord, currentUID: UInt32 = getuid(), ownPID: Int32 = getpid()) -> String? {
        guard target.pid > 1, target.pid != ownPID, target.uid == currentUID else {
            return "系统进程、其他用户进程及 ProcScope 自身为只读。"
        }
        guard target.identity != nil else { return "无法确认进程身份，暂时不能执行操作。" }
        guard target.state != .zombie else { return "这个进程已经退出，等待父进程回收。" }
        return nil
    }

    static func validateTarget(_ target: ProcessRecord) throws {
        guard actionBlockReason(for: target) == nil else { throw SystemServiceError.protectedProcess }
        guard let identity = target.identity, readIdentity(pid: target.pid) == identity else { throw SystemServiceError.staleProcess }
    }

    static func send(_ action: ProcessAction, to target: ProcessRecord) throws {
        try validateTarget(target)
        let signal: Int32
        switch action {
        case .terminate: signal = SIGTERM
        case .forceKill: signal = SIGKILL
        case .pause: signal = SIGSTOP
        case .resume: signal = SIGCONT
        case .quit: throw SystemServiceError.failed("正常退出需要选择一个 macOS 应用。")
        }
        guard Darwin.kill(target.pid, signal) == 0 else {
            if errno == ESRCH { throw SystemServiceError.staleProcess }
            if errno == EPERM { throw SystemServiceError.permissionDenied }
            throw SystemServiceError.failed("操作失败：\(String(cString: strerror(errno)))")
        }
    }
}
