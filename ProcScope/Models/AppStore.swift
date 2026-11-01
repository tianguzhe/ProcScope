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
    var favoritesOnly = false { didSet { rebuildMatches() } }
    private(set) var favorites: [PortFavorite] = []
    var editingFavorite: PortFavorite?
    var operation: OperationStatus?
    var selectedPID: Int32?
    var selectedPortID: String?
    var processes: [ProcessRecord] = [] { didSet { if !applyingSnapshot { rebuildIndexes() } } }
    var ports: [PortRecord] = [] {
        didSet {
            portsByPID = Dictionary(grouping: ports, by: \.pid)
            rebuildMatches()
            if let id = selectedPortID, !ports.contains(where: { $0.id == id && target(for: $0) != nil }) { select(nil) }
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
    private(set) var systemCPUHistory: [Double] = []
    private(set) var systemCPU: CPUUsage?
    private(set) var systemCPUError: String?
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
    @ObservationIgnored private let detailLoader: DetailLoader
    @ObservationIgnored private let source: SnapshotSource
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var monitoringTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var portsRequested = false
    @ObservationIgnored private var detailRequested = false
    @ObservationIgnored private var detailLoadedAt: Date?
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    let currentUID = getuid()

    init(defaults: UserDefaults? = .standard, source: SnapshotSource = .live, detailLoader: DetailLoader = DetailLoader()) {
        self.defaults = defaults
        self.source = source
        self.detailLoader = detailLoader
        if let data = defaults?.data(forKey: "portFavorites"), let saved = try? JSONDecoder().decode([PortFavorite].self, from: data) {
            var seen = Set<String>()
            favorites = saved.filter { $0.isValid && seen.insert($0.id).inserted }
        }
    }

    var selectedProcess: ProcessRecord? { selectedPID.flatMap { processesByPID[$0] } }
    var selectedApp: ApplicationInfo? { selectedPID.flatMap { appsByPID[$0] } }
    var selectedPorts: [PortRecord] { (selectedPID.flatMap { portsByPID[$0] } ?? []).filter { target(for: $0) != nil } }
    var offlineFavorites: [PortFavorite] {
        let active = Set(ports.map(\.favoriteKey))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return favorites.filter {
            !active.contains($0.id) && (transportFilter == "全部" || transportFilter == $0.transport)
                && (query.isEmpty || "\($0.port) \($0.transport) \($0.name)".localizedCaseInsensitiveContains(query))
        }.sorted { $0.port == $1.port ? $0.transport < $1.transport : $0.port < $1.port }
    }
    func target(for port: PortRecord) -> ProcessRecord? {
        guard let identity = port.identity, let process = processesByPID[port.pid], process.identity == identity else { return nil }
        return process
    }
    func favorite(for port: PortRecord) -> PortFavorite? { favorites.first { $0.id == port.favoriteKey } }
    func portName(_ port: PortRecord) -> String {
        if let favorite = favorite(for: port), !favorite.name.isEmpty { return favorite.name }
        return target(for: port).flatMap { app(for: $0.pid)?.name } ?? port.processName
    }
    func toggleFavorite(_ port: PortRecord) {
        if let saved = favorite(for: port) { removeFavorite(saved) }
        else if let number = port.port { saveFavorite(PortFavorite(port: number, transport: port.transport, name: "")) }
    }
    func saveFavorite(_ favorite: PortFavorite) {
        guard favorite.isValid else { return }
        var value = favorite
        value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        favorites.removeAll { $0.id == value.id }
        favorites.append(value)
        persistFavorites()
    }
    func removeFavorite(_ favorite: PortFavorite) {
        favorites.removeAll { $0.id == favorite.id }
        persistFavorites()
    }
    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) { defaults?.set(data, forKey: "portFavorites") }
        rebuildMatches()
    }
    func selectPort(_ port: PortRecord) {
        guard target(for: port) != nil else {
            showNotice("端口归属已变化或暂不可验证，正在重新扫描。", isError: true)
            Task { await refresh(forcePorts: true) }
            return
        }
        select(port.pid, portID: port.id)
    }
    func browserURL(for port: PortRecord, secure: Bool = false) -> URL? {
        guard var components = port.browserURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.scheme = secure ? "https" : "http"
        return components.url
    }
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
                && (!favoritesOnly || favorite(for: port) != nil)
                && (query.isEmpty || "\(port.address) \(port.pid) \(port.processName) \(portName(port))".localizedCaseInsensitiveContains(query))
        }.sorted {
            let left = favorite(for: $0) != nil, right = favorite(for: $1) != nil
            if left != right { return left }
            return ($0.port ?? 0, $0.transport, $0.address, $0.pid) < ($1.port ?? 0, $1.transport, $1.address, $1.pid)
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
        guard monitoringTask == nil else { return }
        // Monitoring belongs to the app, so closing the main window does not
        // silently freeze the menu bar's data.
        monitoringTask = Task { [weak self] in
            await self?.refresh(forcePorts: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(NSApp.isActive ? 3 : 9)) } catch { return }
                guard let self else { return }
                if self.isMonitoring { await self.refresh() }
            }
        }
    }
    func refresh(forcePorts: Bool = false) async {
        refreshRequested = true
        portsRequested = portsRequested || forcePorts
        detailRequested = detailRequested || forcePorts
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await drainRefreshes() }
        refreshTask = task
        await task.value
    }
    private func drainRefreshes() async {
        isRefreshing = true
        defer { isRefreshing = false; refreshTask = nil }
        while refreshRequested {
            let forcePorts = portsRequested, forceDetail = detailRequested
            refreshRequested = false; portsRequested = false; detailRequested = false
            await scanOnce(forcePorts: forcePorts)
            loadDetail(force: forceDetail)
        }
    }
    private func scanOnce(forcePorts: Bool) async {
        let shouldScanPorts = forcePorts || (portsUpdatedAt.map { Date().timeIntervalSince($0) >= 6 } ?? true)
        let source = source
        let cpuTask = Task { try await source.cpu() }
        let portTask = shouldScanPorts ? Task { try await source.ports() } : nil
        defer { portTask?.cancel(); cpuTask.cancel() }
        do {
            let result = try await source.processes()
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
            memoryHistory = Array((memoryHistory + [Double(totalMemory)]).suffix(30))
            scanError = nil
            updatedAt = Date()
            if selectedPID == nil && !hasSelectedInitialProcess {
                hasSelectedInitialProcess = true
                let first = applications.first { $0.isActive && $0.pid != getpid() } ?? applications.first { $0.pid != getpid() }
                select(first?.pid)
            }
        } catch { scanError = error.localizedDescription }
        do {
            applySystemCPU(try await cpuTask.value)
        } catch {
            systemCPU = nil
            systemCPUError = error.localizedDescription
            systemCPUHistory = []
        }
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

    func applySystemCPU(_ usage: CPUUsage?) {
        systemCPU = usage
        systemCPUError = nil
        if let usage { systemCPUHistory = Array((systemCPUHistory + [usage.busy]).suffix(30)) }
        else { systemCPUHistory = [] }
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
        if selectedPID == pid {
            selectedPortID = portID
            loadDetail()
            return
        }
        selectedPID = pid
        selectedPortID = portID
        detail = nil
        detailError = nil
        detailLoadedAt = nil
        detailTask?.cancel()
        detailLoading = false
        loadDetail()
    }
    func loadDetail(force: Bool = false) {
        guard let target = selectedProcess else { detailLoading = false; return }
        if !force && (detailLoading || (detail != nil && detailLoadedAt.map { Date().timeIntervalSince($0) < 15 } == true)) { return }
        detailTask?.cancel()
        detailLoading = true
        detailError = nil
        detailTask = Task {
            do {
                // A brief settling interval coalesces fast keyboard / mouse navigation.
                try await Task.sleep(for: .milliseconds(140))
                let result = try await detailLoader.fetch(target, force: force)
                guard !Task.isCancelled, selectedProcess?.identity == result.identity else { return }
                detail = result
                detailLoadedAt = Date()
                detailLoading = false
            } catch {
                guard !Task.isCancelled, selectedPID == target.pid else { return }
                detailLoading = false
                detail = nil
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
    func request(_ action: ProcessAction, for target: ProcessRecord, port explicitPort: PortRecord? = nil) {
        guard operation?.isPending != true else { showNotice("请等待当前操作完成。", isError: true); return }
        if let reason = SystemService.actionBlockReason(for: target) { showNotice(reason, isError: true); return }
        let port = explicitPort ?? (section == .ports && selectedPID == target.pid ? ports.first { $0.id == selectedPortID } : nil)
        if let port, self.target(for: port) == nil { showNotice("端口归属已变化，请刷新后重试。", isError: true); return }
        let name = applications.first(where: { $0.pid == target.pid })?.name ?? target.name
        pendingAction = PendingAction(action: action, target: target, displayName: name, port: port)
    }
    func perform(_ pending: PendingAction) {
        pendingAction = nil
        guard operation?.isPending != true else { return }
        operation = OperationStatus(targetPID: pending.target.pid, message: "正在核对 \(pending.displayName) 的身份…")
        Task { await execute(pending) }
    }
    private func execute(_ pending: PendingAction) async {
        do {
            try await CommandRunner.background {
                if let port = pending.port { try SystemService.validatePort(port, target: pending.target) }
                else { try SystemService.validateTarget(pending.target) }
            }
            if pending.action == .quit {
                try SystemService.validateTarget(pending.target)
                guard let application = NSRunningApplication(processIdentifier: pending.target.pid), !application.isTerminated else { throw SystemServiceError.staleProcess }
                guard application.terminate() else { throw SystemServiceError.failed("应用未接受退出请求。请检查是否有未保存内容。") }
            } else { try SystemService.send(pending.action, to: pending.target) }
            operation?.message = "已发送\(pending.action.title)请求，正在确认结果…"
            var state = SystemService.observedState(of: pending.target)
            for _ in 0..<30 {
                if Self.actionCompleted(pending.action, state: state) { break }
                try await Task.sleep(for: .milliseconds(100))
                state = SystemService.observedState(of: pending.target)
            }
            let completed = Self.actionCompleted(pending.action, state: state)
            await refresh(forcePorts: true)
            var message: String
            if completed {
                message = state == .exited ? "\(pending.displayName) 已退出。" : pending.action == .pause ? "\(pending.displayName) 已暂停。" : "\(pending.displayName) 已恢复。"
                if let port = pending.port, state == .exited {
                    if portError != nil { message += "端口复查失败，请重新扫描。" }
                    else if ports.contains(where: { $0.favoriteKey == port.favoriteKey }) { message += "\(port.transport) \(port.port ?? 0) 仍有监听或绑定。" }
                    else { message += "未再发现 \(port.transport) \(port.port ?? 0) 的可见占用。" }
                }
            } else { message = "\(pending.displayName) 尚未确认\(pending.action.title)。可检查进程状态后再操作。" }
            operation = OperationStatus(targetPID: pending.target.pid, message: message, isPending: false, isWarning: !completed || (pending.port != nil && portError != nil))
        } catch {
            operation = OperationStatus(targetPID: pending.target.pid, message: error.localizedDescription, isPending: false, isWarning: true)
        }
    }
    static func actionCompleted(_ action: ProcessAction, state: SystemService.ObservedState) -> Bool {
        switch action {
        case .quit, .terminate, .forceKill: state == .exited
        case .pause: state == .paused
        case .resume: state == .running
        }
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

/// Serial native detail reads with cancellation and a bounded, short-lived cache.
actor DetailLoader {
    private var cache: [ProcessIdentity: (date: Date, detail: ProcessDetail)] = [:]
    private let reader: @Sendable (ProcessRecord) throws -> ProcessDetail
    init(reader: @escaping @Sendable (ProcessRecord) throws -> ProcessDetail = { try SystemService.fetchDetail(for: $0) }) { self.reader = reader }
    func fetch(_ target: ProcessRecord, force: Bool = false) throws -> ProcessDetail {
        try Task.checkCancellation()
        guard let identity = target.identity,
              SystemService.readIdentity(pid: target.pid) == identity else { throw SystemServiceError.staleProcess }
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.date) < 15 }
        if !force, let cached = cache[identity] { return cached.detail }
        let detail = try reader(target)
        try Task.checkCancellation()
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[identity] = (now, detail)
        return detail
    }
}
