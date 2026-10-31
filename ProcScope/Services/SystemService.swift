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

enum CommandRunner {
    /// Fixed executables and individual arguments only; never execute a shell string.
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 8) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
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
        let result = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-FpcfPnT"], timeout: 10)
        // lsof returns 1 when no matching sockets are visible.
        guard result.status == 0 || (result.status == 1 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw SystemServiceError.failed("端口扫描未完成。部分进程可能受系统权限限制，请重试。")
        }
        return parsePorts(result.output)
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
        let command = try CommandRunner.run("/bin/ps", ["-ww", "-p", String(target.pid), "-o", "command="])
        let cwd = try CommandRunner.run("/usr/sbin/lsof", ["-a", "-p", String(target.pid), "-d", "cwd", "-Fn"], timeout: 5)
        let directory = cwd.output.split(separator: "\n").first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) }
        if directory == nil { warnings.append("工作目录不可读取，可能受进程权限限制。") }
        guard readIdentity(pid: target.pid) == identity else { throw SystemServiceError.staleProcess }
        return ProcessDetail(identity: identity,
                             command: command.status == 0 ? command.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                             workingDirectory: directory, warnings: warnings)
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
