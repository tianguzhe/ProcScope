import SwiftUI
import AppKit
import Darwin
import Observation

struct ApplicationInfo: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let bundlePath: String
    let icon: NSImage?
    let isActive: Bool
    let isHidden: Bool
}

@MainActor
@Observable
final class AppStore {
    var section: Section = .applications { didSet { rebuildMatches() } }
    var search = "" { didSet { rebuildMatches() } }
    var filter: ProcessFilter = .all { didSet { rebuildMatches() } }
    var sort: ProcessSort = .cpu { didSet { rebuildMatches() } }
    var transportFilter = "全部" { didSet { rebuildMatches() } }
    var selectedPID: Int32?
    var selectedPortID: String?
    var processes: [ProcessRecord] = [] { didSet { if !applyingSnapshot { rebuildIndexes() } } }
    var ports: [PortRecord] = [] {
        didSet {
            portsByPID = Dictionary(grouping: ports, by: \.pid)
            rebuildMatches()
        }
    }
    var applications: [ApplicationInfo] = [] { didSet { if !applyingSnapshot { rebuildIndexes() } } }
    var detail: ProcessDetail?
    var detailLoading = false
    var detailError: String?
    var isRefreshing = false
    var isMonitoring = true
    var updatedAt: Date?
    var portsUpdatedAt: Date?
    var scanError: String?
    var portError: String?
    var pendingAction: PendingAction?
    var notice: Notice?
    private(set) var matchingProcesses: [ProcessRecord] = []
    private(set) var matchingPorts: [PortRecord] = []
    private(set) var activityHistory: [Double] = []
    private(set) var memoryHistory: [Double] = []
    private(set) var portHistory: [Double] = []
    private(set) var totalCPU: Double = 0
    private(set) var totalMemory: UInt64 = 0
    private var processesByPID: [Int32: ProcessRecord] = [:]
    private var appsByPID: [Int32: ApplicationInfo] = [:]
    private var groupsByPID: [Int32: [ProcessRecord]] = [:]
    private var childrenByPID: [Int32: [ProcessRecord]] = [:]
    private var portsByPID: [Int32: [PortRecord]] = [:]
    @ObservationIgnored private var applicationRecords: [ProcessRecord] = []
    @ObservationIgnored private var applyingSnapshot = false
    @ObservationIgnored private var hasSelectedInitialProcess = false
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let detailLoader = DetailLoader()
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    let currentUID = getuid()

    var selectedProcess: ProcessRecord? { selectedPID.flatMap { processesByPID[$0] } }
    var selectedApp: ApplicationInfo? { selectedPID.flatMap { appsByPID[$0] } }
    var selectedPorts: [PortRecord] { selectedPID.flatMap { portsByPID[$0] } ?? [] }
    var childProcesses: [ProcessRecord] { selectedPID.flatMap { childrenByPID[$0] } ?? [] }
    var ancestry: [ProcessRecord] {
        guard var process = selectedProcess else { return [] }
        var result: [ProcessRecord] = []
        var visited: Set<Int32> = [process.pid]
        while let parent = processesByPID[process.parentPID], visited.insert(parent.pid).inserted, result.count < 12 {
            result.insert(parent, at: 0)
            process = parent
        }
        return result
    }
    var foregroundApp: ApplicationInfo? { applications.first { $0.isActive } }

    func app(for pid: Int32) -> ApplicationInfo? { appsByPID[pid] }
    func associatedProcesses(_ app: ApplicationInfo) -> [ProcessRecord] { groupsByPID[app.pid] ?? [] }
    func displayName(for record: ProcessRecord) -> String {
        if section == .applications, let app = appsByPID[record.pid] { return app.name }
        return record.name
    }

    /// Rebuild joins once per system snapshot, rather than for every visible row.
    private func rebuildIndexes() {
        processesByPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        childrenByPID = Dictionary(grouping: processes, by: \.parentPID).mapValues { $0.sorted { $0.pid < $1.pid } }
        let directApps = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let bundles = Dictionary(applications.filter { !$0.bundlePath.isEmpty }.map { ($0.bundlePath, $0) }, uniquingKeysWith: { first, _ in first })
        var owners = directApps
        var groups: [Int32: [ProcessRecord]] = [:]
        for record in processes {
            // Walk path ancestors to find the most specific running app bundle.
            var owner = directApps[record.pid]
            if owner == nil {
                var path = record.executable[...]
                while let separator = path.lastIndex(of: "/") {
                    path = path[..<separator]
                    if let app = bundles[String(path)] { owner = app; break }
                }
            }
            if let owner {
                owners[record.pid] = owner
                groups[owner.pid, default: []].append(record)
            }
        }
        appsByPID = owners
        groupsByPID = groups
        applicationRecords = applications.compactMap { app in
            guard let main = processesByPID[app.pid] else { return nil }
            let group = groups[app.pid] ?? [main]
            return ProcessRecord(pid: main.pid, parentPID: main.parentPID, uid: main.uid,
                                 cpu: group.reduce(0) { $0 + $1.cpu },
                                 memoryBytes: group.reduce(0) { $0 + $1.memoryBytes },
                                 rawState: main.rawState, elapsed: main.elapsed,
                                 executable: main.executable, identity: main.identity)
        }
        totalCPU = processes.reduce(0) { $0 + $1.cpu }
        totalMemory = processes.reduce(0) { $0 + $1.memoryBytes }
        rebuildMatches()
    }

    private func rebuildMatches() {
        guard !applyingSnapshot else { return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = section == .applications ? applicationRecords : processes
        let matched = sorted(records.filter { record in
            let matchesSearch = query.isEmpty || (record.searchableText + " " + (appsByPID[record.pid]?.name ?? "")).localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .mine: matchesFilter = record.uid == currentUID
            case .active: matchesFilter = record.cpu >= 1
            case .paused: matchesFilter = record.state == .stopped
            }
            return matchesSearch && matchesFilter
        })
        if matchingProcesses != matched { matchingProcesses = matched }
        let sockets = ports.filter { port in
            (transportFilter == "全部" || port.transport == transportFilter)
                && (query.isEmpty || "\(port.address) \(port.pid) \(port.processName) \(appsByPID[port.pid]?.name ?? "")".localizedCaseInsensitiveContains(query))
        }
        if matchingPorts != sockets { matchingPorts = sockets }
    }

    func sorted(_ records: [ProcessRecord]) -> [ProcessRecord] {
        records.sorted { a, b in
            switch sort {
            case .cpu: return a.cpu == b.cpu ? a.pid < b.pid : a.cpu > b.cpu
            case .memory: return a.memoryBytes == b.memoryBytes ? a.pid < b.pid : a.memoryBytes > b.memoryBytes
            case .pid: return a.pid < b.pid
            case .name:
                let left = displayName(for: a), right = displayName(for: b)
                let order = left.localizedStandardCompare(right)
                return order == .orderedSame ? a.pid < b.pid : order == .orderedAscending
            }
        }
    }
    func switchSection(_ newSection: Section) {
        applyingSnapshot = true
        section = newSection
        search = ""
        filter = .all
        selectedPortID = nil
        applyingSnapshot = false
        rebuildMatches()
    }

    func startMonitoring() async {
        await refresh(forcePorts: true)
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(NSApp.isActive ? 3 : 9)) } catch { return }
            if isMonitoring { await refresh() }
        }
    }
    func refresh(forcePorts: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let shouldScanPorts = forcePorts || (portsUpdatedAt.map { Date().timeIntervalSince($0) >= 6 } ?? true)
        let portTask = shouldScanPorts ? Task.detached(priority: .utility) { try SystemService.fetchPorts() } : nil
        do {
            let result = try await Task.detached(priority: .utility) { try SystemService.fetchProcesses() }.value
            if Task.isCancelled { return }
            let runningApps = NSWorkspace.shared.runningApplications.filter {
                !$0.isTerminated && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory) && $0.bundleURL != nil
            }
            let infos: [ApplicationInfo] = runningApps.map { app -> ApplicationInfo in
                let path = app.bundleURL?.path ?? ""
                let icon = iconCache[path] ?? app.icon
                if let icon { iconCache[path] = icon }
                return ApplicationInfo(pid: app.processIdentifier, name: app.localizedName ?? "未命名应用",
                                       bundlePath: path, icon: icon, isActive: app.isActive, isHidden: app.isHidden)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let livePaths = Set(infos.map(\.bundlePath))
            iconCache = iconCache.filter { livePaths.contains($0.key) }
            applyProcessSnapshot(result, applications: infos)
            activityHistory = Array((activityHistory + [totalCPU]).suffix(30))
            memoryHistory = Array((memoryHistory + [Double(totalMemory)]).suffix(30))
            scanError = nil
            updatedAt = Date()
            if selectedPID == nil && !hasSelectedInitialProcess {
                hasSelectedInitialProcess = true
                let first = applications.first { $0.isActive && $0.pid != getpid() } ?? applications.first { $0.pid != getpid() }
                select(first?.pid)
            }
        } catch { scanError = error.localizedDescription }
        if let portTask {
            do {
                let sockets = try await portTask.value
                guard !Task.isCancelled else { return }
                ports = sockets
                portHistory = Array((portHistory + [Double(sockets.count)]).suffix(30))
                portsUpdatedAt = Date()
                portError = nil
            } catch { portError = error.localizedDescription }
        }

    }

    /// Capture selection when applying the result, since the user may select another
    /// process while the asynchronous system scan is in flight.
    func applyProcessSnapshot(_ result: [ProcessRecord], applications newApplications: [ApplicationInfo]? = nil) {
        let selectedIdentity = selectedProcess?.identity
        applyingSnapshot = true
        if let newApplications { applications = newApplications }
        processes = result
        applyingSnapshot = false
        rebuildIndexes()
        guard let pid = selectedPID else { return }
        guard let process = processesByPID[pid], process.identity == selectedIdentity else {
            select(nil)
            showNotice("所选进程已退出，列表已更新。")
            return
        }
    }

    func select(_ pid: Int32?, portID: String? = nil) {
        if selectedPID == pid, (detail != nil || detailLoading) {
            selectedPortID = portID
            return
        }
        selectedPID = pid
        selectedPortID = portID
        detail = nil
        detailError = nil
        detailTask?.cancel()
        guard let target = selectedProcess else { detailLoading = false; return }
        detailLoading = true
        detailTask = Task {
            do {
                // A brief settling interval coalesces fast keyboard / mouse navigation.
                try await Task.sleep(for: .milliseconds(140))
                let result = try await detailLoader.fetch(target)
                guard !Task.isCancelled, selectedProcess?.identity == result.identity else { return }
                detail = result
                detailLoading = false
            } catch {
                guard !Task.isCancelled, selectedPID == target.pid else { return }
                detailLoading = false
                detailError = error.localizedDescription
            }
        }
    }
    func inspectPID(_ pid: Int32) {
        section = .processes
        search = ""
        filter = .all
        select(pid)
    }
    func request(_ action: ProcessAction, for target: ProcessRecord) {
        if let reason = SystemService.actionBlockReason(for: target) { showNotice(reason, isError: true); return }
        let name = applications.first(where: { $0.pid == target.pid })?.name ?? target.name
        pendingAction = PendingAction(action: action, target: target, displayName: name)
    }
    func perform(_ pending: PendingAction) {
        pendingAction = nil
        do {
            try SystemService.validateTarget(pending.target)
            if pending.action == .quit {
                guard let application = NSRunningApplication(processIdentifier: pending.target.pid), !application.isTerminated else { throw SystemServiceError.staleProcess }
                guard application.terminate() else { throw SystemServiceError.failed("应用未接受退出请求。可以切换到应用，检查是否有未保存内容。") }
            } else { try SystemService.send(pending.action, to: pending.target) }
            showNotice("已向 \(pending.displayName)（\(pending.target.pid)）发送\(pending.action.title)请求。")
            Task { await refresh(forcePorts: true) }
        } catch { showNotice(error.localizedDescription, isError: true) }
    }
    func activate(_ app: ApplicationInfo) {
        guard let target = processesByPID[app.pid],
              let identity = target.identity, SystemService.readIdentity(pid: app.pid) == identity,
              let running = NSRunningApplication(processIdentifier: app.pid) else {
            showNotice("应用已退出，请刷新后重试。", isError: true); return
        }
        running.activate(options: [])
    }
    func showNotice(_ message: String, isError: Bool = false) {
        noticeTask?.cancel()
        notice = Notice(message: message, isError: isError)
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { notice = nil }
        }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showNotice("已复制到剪贴板。")
    }
}

/// Serial execution bounds expensive lsof queries to one in flight. Cancelled
/// selections are checked before starting work; the small cache expires quickly.
actor DetailLoader {
    private var cache: [ProcessIdentity: (date: Date, detail: ProcessDetail)] = [:]
    func fetch(_ target: ProcessRecord) throws -> ProcessDetail {
        try Task.checkCancellation()
        guard let identity = target.identity,
              SystemService.readIdentity(pid: target.pid) == identity else { throw SystemServiceError.staleProcess }
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.date) < 15 }
        if let cached = cache[identity] { return cached.detail }
        let detail = try SystemService.fetchDetail(for: target)
        try Task.checkCancellation()
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[identity] = (now, detail)
        return detail
    }
}
