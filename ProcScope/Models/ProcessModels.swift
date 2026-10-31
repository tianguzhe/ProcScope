import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct ProcessRecord: Identifiable, Hashable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let cpu: Double
    let memoryBytes: UInt64
    let rawState: String
    let elapsed: String
    var executable: String
    var identity: ProcessIdentity?
    var name: String { URL(fileURLWithPath: executable).lastPathComponent }
    var state: ProcessState { ProcessState(raw: rawState) }
    var searchableText: String { "\(pid) \(parentPID) \(name) \(executable)" }
}

enum ProcessState: String, Sendable {
    case running, sleeping, stopped, zombie, idle, uninterruptible, unknown
    init(raw: String) {
        switch raw.first {
        case "R": self = .running
        case "S": self = .sleeping
        case "T": self = .stopped
        case "Z": self = .zombie
        case "I": self = .idle
        case "U", "D": self = .uninterruptible
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .running: "运行中"
        case .sleeping: "等待中"
        case .stopped: "已暂停"
        case .zombie: "已退出"
        case .idle: "空闲"
        case .uninterruptible: "内核等待"
        case .unknown: "未知"
        }
    }
    var explanation: String {
        switch self {
        case .running: "正在执行，或等待 CPU 调度。"
        case .sleeping: "正在等待事件或资源，是正常状态，不代表应用卡住。"
        case .stopped: "进程已停止调度，可通过恢复操作继续执行。"
        case .zombie: "进程已结束，正在等待父进程回收退出信息。"
        case .idle: "进程处于空闲状态，暂时没有工作。"
        case .uninterruptible: "正在等待内核操作完成，可能暂时无法响应信号。"
        case .unknown: "当前无法读取进程状态。"
        }
    }
}

struct PortRecord: Identifiable, Hashable, Sendable {
    var id: String { "\(pid)|\(transport)|\(address)" }
    let pid: Int32
    let processName: String
    let transport: String
    let address: String
    var port: Int? { address.split(separator: ":").last.flatMap { Int($0) } }
    var isLoopback: Bool {
        address.hasPrefix("127.") || address.hasPrefix("[::1]:") || address.hasPrefix("localhost:")
    }
    var scope: String { isLoopback ? "仅本机" : "\(transport == "UDP" ? "绑定" : "监听")地址" }
    var status: String { transport == "UDP" ? "已绑定" : "监听中" }
}

struct ProcessDetail: Sendable {
    let identity: ProcessIdentity
    let command: String?
    let workingDirectory: String?
    let warnings: [String]
}

enum Section: String, CaseIterable, Identifiable {
    case applications, processes, ports
    var id: Self { self }
    var title: String {
        switch self {
        case .applications: "应用"
        case .processes: "全部进程"
        case .ports: "监听端口"
        }
    }
    var icon: String {
        switch self {
        case .applications: "square.grid.2x2"
        case .processes: "waveform.path.ecg"
        case .ports: "network"
        }
    }
    var subtitle: String {
        switch self {
        case .applications: "看清正在运行的应用，以及它们的资源占用。"
        case .processes: "从系统服务到开发进程，每一个运行中的任务。"
        case .ports: "从一个端口，找到它背后的进程与应用。"
        }
    }
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "全部", mine = "我的进程", active = "CPU ≥ 1%", paused = "已暂停"
    var id: Self { self }
}

enum ProcessSort: String, CaseIterable, Identifiable {
    case name = "名称", cpu = "CPU", memory = "内存", pid = "PID"
    var id: Self { self }
}

enum ProcessAction: String, Identifiable {
    case quit, terminate, forceKill, pause, resume
    var id: Self { self }
    var title: String {
        switch self {
        case .quit: "正常退出"
        case .terminate: "结束进程"
        case .forceKill: "强制结束"
        case .pause: "暂停进程"
        case .resume: "恢复进程"
        }
    }
    var symbol: String {
        switch self {
        case .quit, .terminate: "stop.circle"
        case .forceKill: "xmark.octagon"
        case .pause: "pause.circle"
        case .resume: "play.circle"
        }
    }
    var explanation: String {
        switch self {
        case .quit: "请求应用正常退出。应用可能会提示保存内容，或取消退出。"
        case .terminate: "向这个进程发送结束请求（SIGTERM）。仅处理所选 PID，进程可能延迟或拒绝退出。"
        case .forceKill: "立即结束这个进程（SIGKILL）。未保存的内容可能丢失；由系统服务管理的进程可能重新启动。"
        case .pause: "暂停这个进程（SIGSTOP）。它会保留内存、文件和端口占用；应用界面可能停止响应。"
        case .resume: "恢复这个进程的执行（SIGCONT）。"
        }
    }
}

struct PendingAction: Identifiable {
    let id = UUID()
    let action: ProcessAction
    let target: ProcessRecord
    let displayName: String
}

struct Notice: Identifiable {
    let id = UUID()
    let message: String
    var isError = false
}

extension UInt64 {
    var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .memory)
    }
}

enum AppVersion {
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
}
