import Foundation
import Darwin

struct CPUUsage: Equatable, Sendable {
    let user: Double
    let system: Double
    var busy: Double { min(100, max(0, user + system)) }
}

struct CPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    /// HOST_CPU_LOAD_INFO accounts for all logical CPUs. Use interval deltas,
    /// including UInt32 counter rollover, rather than process percentages.
    func usage(since previous: CPUTicks) -> CPUUsage? {
        let userTicks = UInt64(user &- previous.user) + UInt64(nice &- previous.nice)
        let systemTicks = UInt64(system &- previous.system)
        let total = userTicks + systemTicks + UInt64(idle &- previous.idle)
        guard total > 0 else { return nil }
        return CPUUsage(user: Double(userTicks) / Double(total) * 100,
                        system: Double(systemTicks) / Double(total) * 100)
    }

    static func read() throws -> CPUTicks {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw SystemServiceError.failed("无法读取系统 CPU 使用率，请刷新重试。") }
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}

actor SystemCPUSampler {
    static let shared = SystemCPUSampler()
    private var previous: (ticks: CPUTicks, time: TimeInterval)?
    private var latest: CPUUsage?
    private let read: @Sendable () throws -> CPUTicks
    private let clock: @Sendable () -> TimeInterval

    init(read: @escaping @Sendable () throws -> CPUTicks = { try CPUTicks.read() },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.read = read
        self.clock = clock
    }

    func sample() throws -> CPUUsage? {
        let now = clock()
        // Rapid manual refreshes must not produce noisy near-zero intervals.
        if let previous, now >= previous.time, now - previous.time < 0.2 { return latest }
        do {
            let ticks = try read()
            defer { previous = (ticks, now) }
            guard let previous, now > previous.time, now - previous.time <= 30 else {
                latest = nil // First reading, resume after a long pause, or wake.
                return nil
            }
            latest = ticks.usage(since: previous.ticks)
            return latest
        } catch {
            previous = nil
            latest = nil
            throw error
        }
    }
}
