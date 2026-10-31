import SwiftUI
import AppKit

struct InspectorView: View {
    @Environment(AppStore.self) var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("进程详情", systemImage: "sidebar.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                Spacer()
                if let record = store.selectedProcess {
                    Menu {
                        Button("复制 PID") { store.copy(String(record.pid)) }
                        Button("复制可执行文件路径") { store.copy(record.executable) }
                        if let command = store.detail?.command { Button("复制启动命令") { store.copy(command) } }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(Palette.secondary) }.menuStyle(.borderlessButton).fixedSize()
                }
            }.padding(.horizontal, 23).frame(height: 55)
            Rectangle().fill(Palette.line).frame(height: 1)
            if let record = store.selectedProcess {
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        identityHeader(record)
                        overview(record)
                        stateSection(record)
                        Rectangle().fill(Palette.line).frame(height: 1)
                        portsSection
                        if store.detailLoading {
                            HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("正在读取启动信息…").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                        }
                        if let detail = store.detail {
                            if let directory = detail.workingDirectory { pathSection("工作目录", text: directory, directory: true) }
                            if let command = detail.command { commandSection(command) }
                            ForEach(detail.warnings, id: \.self) { warning in
                                Text(warning).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
                            }
                        }
                        if let error = store.detailError {
                            Text(error).font(.system(size: 10)).foregroundStyle(Palette.orange).lineSpacing(4)
                        }
                        pathSection("可执行文件", text: record.executable)
                        ancestrySection(record)
                        if !store.childProcesses.isEmpty { childrenSection }
                    }.padding(24)
                }.id(record.identity)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : Motion.quick, value: record.identity)
                actions(record)
            } else {
                EmptyState(symbol: "sidebar.right", title: "选择一个进程", message: "查看它的来源、端口和运行状态。")
            }
        }.frame(width: 320).frame(maxHeight: .infinity).background(Palette.card)
    }
    private func identityHeader(_ record: ProcessRecord) -> some View {
        let app = store.app(for: record.pid)
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                AppIcon(image: app?.icon, size: 56)
                    .padding(12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 20))
                Spacer()
                if let app {
                    Button { store.activate(app) } label: { Image(systemName: "arrow.up.forward.app").font(.system(size: 14)).foregroundStyle(Palette.accent).padding(8).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7)) }
                        .buttonStyle(.plain).help("切换到 \(app.name)").accessibilityLabel("切换到应用")
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(store.selectedApp?.pid == record.pid ? (store.selectedApp?.name ?? record.name) : record.name)
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.ink).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 8) {
                    Text("PID \(record.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                    StatusBadge(text: record.state.title, color: record.state.color)
                }
            }
        }
    }
    private func overview(_ record: ProcessRecord) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("进程 CPU").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", record.cpu))
                    Text("%").font(.system(size: 11))
                }
            }.font(.system(size: 21, weight: .medium, design: .rounded)).foregroundStyle(Palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                .help("ps 报告的进程 CPU 使用率；单个核心为 100%。")
            Rectangle().fill(Palette.line).frame(width: 1, height: 35).padding(.trailing, 17)
            VStack(alignment: .leading, spacing: 6) {
                Text("驻留内存").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                Text(record.memoryBytes.memoryLabel).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Palette.ink)
            }.frame(maxWidth: .infinity, alignment: .leading).help("当前进程 RSS；共享页面可能被多个进程重复统计。")
        }.padding(16).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.6)))
    }
    private func stateSection(_ record: ProcessRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SmallSectionTitle(title: "运行状态")
            infoRow("运行时长", value: record.elapsed)
            infoRow("所属用户", value: record.uid == store.currentUID ? "当前用户 · \(record.uid)" : "UID \(record.uid)")
            if let app = store.app(for: record.pid) {
                infoRow("应用位置", value: app.isActive ? "前台应用" : app.isHidden ? "后台 · 窗口已隐藏" : "后台应用")
            }
            Text(record.state.explanation).font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var portsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmallSectionTitle(title: "监听 / 绑定端口", trailing: "\(store.selectedPorts.count)")
            if store.selectedPorts.isEmpty {
                Text(store.portError == nil ? "未发现此进程的可见监听端口。" : "端口扫描暂不可用。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).lineSpacing(4)
            } else {
                ForEach(store.selectedPorts) { port in
                    HStack {
                        Text(port.transport).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.accent).frame(width: 30)
                        Text(port.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink).textSelection(.enabled).lineLimit(2)
                        Spacer(minLength: 0)
                        Circle().fill(Palette.green).frame(width: 5, height: 5)
                    }.padding(10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                        .contextMenu { PortContextActions(port: port) }
                }
            }
        }
    }
    private func pathSection(_ title: String, text: String, directory: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SmallSectionTitle(title: title)
                if text.hasPrefix("/") {
                    IconButton(symbol: "folder", label: "在 Finder 中显示") {
                        let url = URL(fileURLWithPath: text)
                        if directory { NSWorkspace.shared.open(url) }
                        else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                .textSelection(.enabled).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func commandSection(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SmallSectionTitle(title: "启动命令")
                IconButton(symbol: "doc.on.doc", label: "复制启动命令") { store.copy(command) }
            }
            ScrollView(.horizontal) {
                Text(command).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink).textSelection(.enabled).padding(12)
            }.frame(maxHeight: 100).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7))
        }
    }
    private func ancestrySection(_ record: ProcessRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SmallSectionTitle(title: "启动来源", trailing: "父进程链")
            if store.ancestry.isEmpty {
                Text("父进程不可见或已退出（PPID \(record.parentPID)）。").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.ancestry) { parent in
                        Button { store.inspectPID(parent.pid) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(Palette.secondary.opacity(0.6))
                                Text(parent.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(String(parent.pid)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary)
                            }.foregroundStyle(Palette.ink).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("查看父进程 \(parent.pid)")
                    }
                    HStack(spacing: 8) {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6)
                        Text(record.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text("当前").font(.system(size: 9))
                    }.foregroundStyle(Palette.accent).padding(.vertical, 8)
                }
            }
        }
    }
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SmallSectionTitle(title: "直接子进程", trailing: "\(store.childProcesses.count)")
            ForEach(store.childProcesses.prefix(12)) { child in
                Button { store.inspectPID(child.pid) } label: {
                    HStack {
                        Text(child.name).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        Text(String(child.pid)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Palette.secondary)
                    }.foregroundStyle(Palette.ink).padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if store.childProcesses.count > 12 { Text("另有 \(store.childProcesses.count - 12) 个子进程").font(.system(size: 9)).foregroundStyle(Palette.secondary) }
        }
    }
    private func actions(_ record: ProcessRecord) -> some View {
        let blocked = SystemService.actionBlockReason(for: record)
        let nativeApp = store.applications.contains(where: { $0.pid == record.pid })
        return VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Palette.line).frame(height: 1)
            if let blocked {
                Label(blocked, systemImage: "lock").font(.system(size: 9)).foregroundStyle(Palette.secondary).lineSpacing(3).padding(.horizontal, 21).padding(.top, 5)
            }
            HStack(spacing: 8) {
                Button { store.request(nativeApp ? .quit : .terminate, for: record) } label: {
                    Label(nativeApp ? "正常退出" : "结束进程", systemImage: "stop.circle").font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 34)
                }.buttonStyle(QuietButtonStyle()).foregroundStyle(Palette.accent).background(Palette.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
                Menu {
                    Button(record.state == .stopped ? "恢复进程…" : "暂停进程…") { store.request(record.state == .stopped ? .resume : .pause, for: record) }
                    Divider()
                    Button("强制结束…", role: .destructive) { store.request(.forceKill, for: record) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 28, height: 34) }
                    .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 7).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
                    .help("暂停、恢复或强制结束")
            }.disabled(blocked != nil || store.operation?.isPending == true).padding(.horizontal, 21).padding(.bottom, 18)
        }.background(Palette.card)
    }
    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Palette.secondary)
            Spacer(minLength: 10)
            Text(value).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 10))
    }
}
