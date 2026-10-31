import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            SidebarView()
            ProcessListView()
            Rectangle().fill(Palette.line).frame(width: 1)
            InspectorView()
        }
        .frame(minWidth: 1160, minHeight: 740)
        .background(Palette.canvas)
        .tint(Palette.accent)
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                HStack(spacing: 8) {
                    Image(systemName: notice.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.isError ? Palette.orange : Palette.green)
                    Text(notice.message).font(.system(size: 11)).foregroundStyle(Palette.ink)
                    Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 13)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
                    .shadow(color: .black.opacity(0.08), radius: 15, y: 4)
                    .padding(.bottom, 20).padding(.horizontal, 240)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.gentle, value: store.notice?.id)
        .sheet(item: $store.pendingAction) { pending in ActionConfirmation(pending: pending) }
        .task { await store.startMonitoring() }
    }
}

struct ActionConfirmation: View {
    @Environment(AppStore.self) var store
    let pending: PendingAction
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 13) {
                Image(systemName: pending.action.symbol).font(.system(size: 27, weight: .light)).foregroundStyle(pending.action == .forceKill ? .red : Palette.accent)
                    .frame(width: 50, height: 50).background((pending.action == .forceKill ? Color.red : Palette.accent).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(pending.action.title)？").font(.system(size: 20, weight: .semibold))
                    Text("\(pending.displayName) · PID \(pending.target.pid)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Text(pending.action.explanation).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text(pending.target.executable).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("取消") { store.pendingAction = nil }.keyboardShortcut(.cancelAction)
                Button(pending.action.title, role: pending.action == .forceKill ? .destructive : nil) { store.perform(pending) }
                    .buttonStyle(.borderedProminent).tint(pending.action == .forceKill ? .red : Palette.accent)
            }
        }.padding(28).frame(width: 460)
    }
}
