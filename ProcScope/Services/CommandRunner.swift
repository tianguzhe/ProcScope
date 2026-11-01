import Foundation
import Darwin

enum CommandError: LocalizedError {
    case timedOut, excessiveOutput
    var errorDescription: String? {
        switch self {
        case .timedOut: "系统采集超时，请重试。"
        case .excessiveOutput: "系统采集输出超出限制，请重试。"
        }
    }
}

enum CommandRunner {
    /// Poll a nonblocking pipe so cancellation, ignored SIGTERM and inherited pipe
    /// descriptors cannot leave a scan indefinitely waiting for EOF.
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 8) throws -> CommandResult {
        try autoreleasepool {
            try Task.checkCancellation()
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            let fd = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw SystemServiceError.failed("无法创建采集通道。")
            }
            defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
            try process.run()
            try? output.fileHandleForWriting.close()
            let start = ProcessInfo.processInfo.systemUptime
            var stopAt: Double?
            var didForceStop = false
            var failure: Error?
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                // Bound each drain pass even if a child continuously writes.
                for _ in 0..<16 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    if data.count + count <= 16 * 1024 * 1024 { data.append(contentsOf: buffer.prefix(count)) }
                    else { failure = CommandError.excessiveOutput; break }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if failure == nil {
                    if Task.isCancelled { failure = CancellationError() }
                    else if now - start >= timeout { failure = CommandError.timedOut }
                }
                if failure != nil && stopAt == nil {
                    stopAt = now
                    if process.isRunning { process.terminate() }
                }
                if let stopAt, process.isRunning, !didForceStop, now - stopAt >= 0.25 {
                    // Only the subprocess started above is eligible for escalation.
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    didForceStop = true
                }
                if !process.isRunning {
                    // One final bounded drain captures output written just before exit.
                    while data.count < 16 * 1024 * 1024 {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        guard count > 0 else { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    process.waitUntilExit()
                    break
                }
                if let stopAt, now - stopAt >= 1 { throw failure! }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 25)
                if descriptor.revents & Int16(POLLHUP) != 0 { usleep(10_000) }
            }
            if let failure { throw failure }
            return CommandResult(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus)
        }
    }

    static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility) { try operation() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

struct SnapshotSource: Sendable {
    var processes: @Sendable () async throws -> [ProcessRecord]
    var ports: @Sendable () async throws -> [PortRecord]
    var cpu: @Sendable () async throws -> CPUUsage? = { try await SystemCPUSampler.shared.sample() }
    static let live = SnapshotSource(
        processes: { try await CommandRunner.background { try SystemService.fetchProcesses() } },
        ports: { try await CommandRunner.background { try SystemService.fetchPorts() } }
    )
}
