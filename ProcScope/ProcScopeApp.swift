import SwiftUI
import AppKit

@main
struct ProcScopeApp: App {
    @State private var store = AppStore()
    @AppStorage("showMenuBar") private var showMenuBar = false
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("ProcScope", id: "main") {
            ContentView().environment(store)
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开 ProcScope") { openMainWindow() }.keyboardShortcut("0")
            }
            CommandMenu("监测") {
                Button("搜索") { NotificationCenter.default.post(name: .focusProcSearch, object: nil) }.keyboardShortcut("f")
                Button("立即刷新") { Task { await store.refresh(forcePorts: true) } }.keyboardShortcut("r")
                Button(store.isMonitoring ? "暂停自动刷新" : "开启自动刷新") { store.isMonitoring.toggle() }
                Divider()
                Button("应用") { store.switchSection(.applications) }.keyboardShortcut("1")
                Button("全部进程") { store.switchSection(.processes) }.keyboardShortcut("2")
                Button("监听端口") { store.switchSection(.ports) }.keyboardShortcut("3")
            }
        }
        Settings { SettingsView().environment(store) }
        MenuBarExtra("ProcScope", systemImage: "waveform.path.ecg", isInserted: $showMenuBar) {
            Button("打开 ProcScope") { openMainWindow() }
            Text("\(store.processes.count) 个进程 · \(store.ports.count) 个端口")
            Divider()
            Button("查看监听端口") { store.switchSection(.ports); openMainWindow() }
            Button("刷新") { Task { await store.refresh(forcePorts: true) } }
            Divider()
            Button("退出 ProcScope") { NSApplication.shared.terminate(nil) }
        }
    }
    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

struct SettingsView: View {
    @AppStorage("showMenuBar") private var showMenuBar = false
    @Environment(AppStore.self) var store
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 13) {
                BrandMark(size: 45)
                VStack(alignment: .leading, spacing: 5) {
                    Text("ProcScope").font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("进程透镜 · \(AppVersion.current)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Form {
                Toggle("在菜单栏显示快捷入口", isOn: $showMenuBar)
                Toggle("自动刷新进程与端口", isOn: $store.isMonitoring)
            }.formStyle(.grouped).frame(height: 125)
            VStack(alignment: .leading, spacing: 10) {
                Label("所有数据仅在本机处理，无网络上传。", systemImage: "lock.shield")
                Label("后台运行和睡眠等待都不代表应用无响应。", systemImage: "info.circle")
                Label("只对当前用户的进程提供管理操作。", systemImage: "person.crop.circle")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Text("macOS 14+ · Apple Silicon / Intel\n进程状态来自系统快照；部分进程详情可能受 macOS 权限限制。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(5)
        }.padding(30).frame(width: 470)
    }
}
