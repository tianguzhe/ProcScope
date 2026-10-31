import SwiftUI

extension Notification.Name { static let focusProcSearch = Notification.Name("focusProcSearch") }

struct ProcessListView: View {
    @Environment(AppStore.self) var store
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            header
            if store.section == .ports {
                portSummary
            } else {
                HStack(spacing: 10) {
                    StatCard(label: "进程 CPU 合计", value: String(format: "%.1f%%", store.totalCPU), symbol: "cpu", caption: "单核 100% · 全部进程", history: store.activityHistory)
                    StatCard(label: "驻留内存合计", value: store.totalMemory.memoryLabel, symbol: "memorychip", caption: "RSS · 含重复共享页面", color: Palette.orange, history: store.memoryHistory)
                    StatCard(label: "监听与绑定", value: String(store.ports.count), symbol: "point.3.connected.trianglepath.dotted", caption: "TCP 监听 / UDP 绑定", color: Palette.green, history: store.portHistory)
                }.padding(.horizontal, 28).padding(.bottom, 26)
            }
            searchBar.padding(.horizontal, 28).padding(.bottom, 14)
            filters.padding(.horizontal, 28).padding(.bottom, 14)
            if let error = store.scanError { errorBanner(error).padding(.horizontal, 28).padding(.bottom, 12) }
            if store.section == .ports, let error = store.portError { errorBanner(error).padding(.horizontal, 28).padding(.bottom, 12) }
            VStack(spacing: 0) {
                columnHeader
                Rectangle().fill(Palette.line).frame(height: 1)
                if store.updatedAt == nil && store.isRefreshing {
                    VStack(spacing: 12) { ProgressView().controlSize(.small); Text("正在读取系统进程…").font(.system(size: 12)).foregroundStyle(Palette.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.section == .ports {
                    PortListContent()
                } else {
                    processList
                }
            }
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
            .padding(.horizontal, 28)
            footer
        }.frame(minWidth: 630, maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
            .sheet(item: $store.editingFavorite) { FavoriteEditor(favorite: $0).environment(store) }
            .onReceive(NotificationCenter.default.publisher(for: .focusProcSearch)) { _ in searchFocused = true }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Text("系统观察台").tracking(2)
                    Text("/").opacity(0.4)
                    Text("\(store.applications.count) 个应用在线").monospacedDigit()
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(store.section.title).font(.system(size: 28, weight: .semibold)).tracking(-0.8).foregroundStyle(Palette.ink)
                        .contentTransition(.interpolate)
                        .animation(reduceMotion ? nil : Motion.quick, value: store.section)
                    StatusBadge(text: store.isMonitoring ? "实时" : "已暂停", color: store.isMonitoring ? Palette.green : Palette.orange)
                }
                Text(store.section.subtitle).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                IconButton(symbol: store.isMonitoring ? "pause" : "play", label: store.isMonitoring ? "暂停自动刷新" : "开启自动刷新") { store.isMonitoring.toggle() }
                IconButton(symbol: "arrow.clockwise", label: "立即刷新（⌘R）") { Task { await store.refresh(forcePorts: true) } }
            }.padding(4).background(Palette.card, in: Capsule()).overlay(Capsule().stroke(Palette.line))
        }.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 27)
    }
    private var searchBar: some View {
        @Bindable var store = store
        return HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            TextField(store.section == .ports ? "搜索端口、进程或应用…" : "搜索应用、进程名称或 PID…", text: $store.search)
                .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                .accessibilityLabel("搜索进程或端口")
            if !store.search.isEmpty {
                IconButton(symbol: "xmark.circle.fill", label: "清除搜索") { store.search = "" }
            } else { Text("⌘ F").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary) }
        }.padding(.horizontal, 13).frame(height: 44)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(searchFocused ? Palette.accent.opacity(0.6) : Palette.line))
            .shadow(color: Palette.accent.opacity(searchFocused ? 0.07 : 0), radius: 6, y: 2)
            .animation(reduceMotion ? nil : Motion.quick, value: searchFocused)
    }
    private var filters: some View {
        @Bindable var store = store
        return HStack(spacing: 2) {
            if store.section == .ports {
                PillButton(title: "收藏", isSelected: store.favoritesOnly) { store.favoritesOnly.toggle() }
                Rectangle().fill(Palette.line).frame(width: 1, height: 14).padding(.horizontal, 6)
                ForEach(["全部", "TCP", "UDP"], id: \.self) { value in
                    PillButton(title: value, isSelected: store.transportFilter == value) { store.transportFilter = value }
                }
            } else {
                ForEach(ProcessFilter.allCases) { filter in
                    PillButton(title: filter.rawValue, isSelected: store.filter == filter) { store.filter = filter }
                }
            }
            Spacer(minLength: 4)
            if store.section != .ports {
                Menu {
                    Picker("排序", selection: $store.sort) { ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) } }
                } label: {
                    Label(store.sort.rawValue, systemImage: "arrow.up.arrow.down").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }.menuStyle(.borderlessButton).fixedSize().help("排序方式")
            }
        }
    }
    private var columnHeader: some View {
        HStack(spacing: 8) {
            if store.section == .ports {
                Text("端口 / 协议").frame(width: 110, alignment: .leading)
                Text("所属进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("绑定地址").frame(width: 120, alignment: .trailing)
                Text("收藏").frame(width: 25)
            } else {
                Text(store.section == .applications ? "应用" : "进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("状态").frame(width: 67, alignment: .leading)
                Button { store.sort = .cpu } label: { Text(store.sort == .cpu ? "CPU ↓" : "CPU").foregroundStyle(store.sort == .cpu ? Palette.accent : Palette.secondary).frame(width: 60, alignment: .trailing) }.buttonStyle(.plain)
                Button { store.sort = .memory } label: { Text(store.sort == .memory ? "内存 ↓" : "内存").foregroundStyle(store.sort == .memory ? Palette.accent : Palette.secondary).frame(width: 72, alignment: .trailing) }.buttonStyle(.plain)
                Text("PID").frame(width: 55, alignment: .trailing)
            }
        }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary).padding(.horizontal, 16).frame(height: 38).background(Palette.canvas.opacity(0.65))
    }
    private var processList: some View {
        Group {
            if store.matchingProcesses.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "没有匹配的进程", message: "试试其他关键词，或切换到“全部”筛选。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.matchingProcesses) { record in
                            processRow(record)
                            Rectangle().fill(Palette.line.opacity(0.7)).frame(height: 1).padding(.leading, 58)
                        }
                    }
                }.id(store.section)
            }
        }
    }
    private func processRow(_ record: ProcessRecord) -> some View {
        let app = store.app(for: record.pid)
        let selected = store.selectedPID == record.pid
        return Button { store.select(record.pid) } label: {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    AppIcon(image: app?.icon, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.displayName(for: record)).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(subtitle(record, app: app)).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if record.state == .stopped || record.state == .zombie { StatusBadge(text: record.state.title, color: record.state.color) }
                    else if store.section == .applications, let app { StatusBadge(text: app.isActive ? "前台" : "后台", color: app.isActive ? Palette.green : Palette.secondary) }
                    else { StatusBadge(text: record.state.title, color: record.state.color) }
                }.frame(width: 67, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(String(format: "%.1f%%", record.cpu)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(record.cpu >= 80 ? Palette.orange : Palette.ink)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.accent.opacity(0.10))
                        Capsule().fill(record.cpu >= 80 ? Palette.orange.opacity(0.7) : Palette.accent.opacity(0.45))
                            .frame(width: proxy.size.width * min(max(record.cpu / 100, 0), 1))
                    }.frame(width: 42, height: 3).accessibilityHidden(true)
                }.frame(width: 60, alignment: .trailing)
                Text(record.memoryBytes.memoryLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink).frame(width: 72, alignment: .trailing)
                Text(String(record.pid)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary).frame(width: 55, alignment: .trailing)
            }.padding(.horizontal, 16).frame(height: 66).contentShape(Rectangle())
                .modifier(RowSurface(selected: selected))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(store.displayName(for: record))，PID \(record.pid)，\(record.state.title)")
            .contextMenu {
                Button("查看详情") { store.select(record.pid) }
                if let app { Button("切换到应用") { store.activate(app) } }
                Button("复制 PID") { store.copy(String(record.pid)) }
                Divider()
                if store.applications.contains(where: { $0.pid == record.pid }) {
                    Button("正常退出…") { store.request(.quit, for: record) }.disabled(SystemService.actionBlockReason(for: record) != nil)
                }
                Button("结束进程…") { store.request(.terminate, for: record) }.disabled(SystemService.actionBlockReason(for: record) != nil)
                Button("强制结束…", role: .destructive) { store.request(.forceKill, for: record) }.disabled(SystemService.actionBlockReason(for: record) != nil)
            }
    }
    private func subtitle(_ record: ProcessRecord, app: ApplicationInfo?) -> String {
        if store.section == .applications, let app { return "\(store.associatedProcesses(app).count) 个关联进程\(app.isHidden ? " · 窗口已隐藏" : "")" }
        return app?.name ?? (record.uid == store.currentUID ? "当前用户" : "UID \(record.uid) · 系统 / 其他用户")
    }
    private var portSummary: some View {
        HStack(spacing: 18) {
            Label("\(store.ports.count) 个监听 / 绑定", systemImage: "network")
            Label("\(store.favorites.count) 个收藏", systemImage: "star")
            Spacer()
            Text("常用服务，随手可达").foregroundStyle(Palette.secondary)
        }.font(.system(size: 11)).foregroundStyle(Palette.accent)
            .padding(14).background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 28).padding(.bottom, 18)
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill((store.section == .ports ? store.portError : store.scanError) == nil ? (store.isMonitoring ? Palette.green : Palette.secondary) : Palette.orange).frame(width: 5, height: 5)
            Text("\(store.section == .ports ? store.matchingPorts.count : store.matchingProcesses.count) 项").font(.system(size: 10))
            if store.section == .applications { Text("· CPU / 内存含关联进程").font(.system(size: 9)) }
            if store.section == .ports { Text("· 仅当前权限可见 · \(store.offlineFavorites.count) 个收藏未发现占用").font(.system(size: 9)) }
            Spacer()
            if let date = store.section == .ports ? store.portsUpdatedAt : store.updatedAt {
                Text("更新于 \(date.formatted(date: .omitted, time: .standard))").font(.system(size: 9, design: .monospaced))
            }
        }.foregroundStyle(Palette.secondary).padding(.horizontal, 28).frame(height: 44)
    }
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.orange).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Palette.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
