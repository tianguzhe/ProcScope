import SwiftUI
import AppKit

struct PortListContent: View {
    @Environment(AppStore.self) var store
    var body: some View {
        if store.matchingPorts.isEmpty && store.offlineFavorites.isEmpty {
            EmptyState(symbol: store.favoritesOnly ? "star" : "network", title: store.favoritesOnly ? "还没有匹配的收藏" : "没有匹配的端口",
                       message: store.favoritesOnly ? "点击端口右侧的星标，收藏常用服务。" : "试试其他端口号、进程名称，或刷新列表。")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.matchingPorts) { port in
                        PortListRow(port: port)
                        Rectangle().fill(Palette.line.opacity(0.7)).frame(height: 1).padding(.horizontal, 16)
                    }
                    if !store.offlineFavorites.isEmpty {
                        HStack {
                            Text("收藏 · 未发现可见占用")
                            Spacer()
                            if store.portError != nil { Text("扫描失败，状态待确认") }
                        }.font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(16)
                        ForEach(store.offlineFavorites) { favorite in
                            HStack(spacing: 12) {
                                Image(systemName: "star.fill").foregroundStyle(Palette.orange)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(favorite.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                                    Text("\(favorite.transport) · \(String(favorite.port))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Button("命名") { store.editingFavorite = favorite }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                                IconButton(symbol: "star.slash", label: "取消收藏 \(favorite.port)") { store.removeFavorite(favorite) }
                            }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 12)
                        }
                    }
                }
            }
        }
    }
}

private struct PortListRow: View {
    @Environment(AppStore.self) var store
    let port: PortRecord
    var body: some View {
        HStack(spacing: 6) {
            Button { store.selectPort(port) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(port.port.map(String.init) ?? "—").font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink)
                        Text(port.transport).font(.system(size: 9, weight: .medium)).foregroundStyle(port.transport == "TCP" ? Palette.accent : Palette.orange)
                    }.frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.portName(port)).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text("PID \(port.pid) · \(port.processName)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(port.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                        Text(store.target(for: port) == nil ? "归属待核对" : port.isLoopback ? "仅本机" : port.status)
                            .font(.system(size: 9)).foregroundStyle(Palette.secondary)
                    }.frame(width: 120, alignment: .trailing)
                }.contentShape(Rectangle()).frame(height: 64)
            }.buttonStyle(.plain)
                .accessibilityLabel("端口 \(port.port ?? 0)，\(port.transport)，\(store.portName(port))，PID \(port.pid)")
            Button { store.toggleFavorite(port) } label: {
                Image(systemName: store.favorite(for: port) == nil ? "star" : "star.fill")
                    .foregroundStyle(store.favorite(for: port) == nil ? Palette.secondary : Palette.orange)
                    .font(.system(size: 12)).frame(width: 25, height: 32)
            }.buttonStyle(.plain).help(store.favorite(for: port) == nil ? "收藏端口" : "取消收藏")
                .accessibilityLabel("\(store.favorite(for: port) == nil ? "收藏" : "取消收藏") \(port.port ?? 0)")
        }.padding(.horizontal, 16).modifier(RowSurface(selected: store.selectedPortID == port.id))
            .contextMenu { PortContextActions(port: port) }
    }
}

struct PortContextActions: View {
    @Environment(AppStore.self) var store
    let port: PortRecord
    var body: some View {
        Button("查看进程详情") { store.selectPort(port) }
        Button(store.favorite(for: port) == nil ? "收藏端口" : "取消收藏") { store.toggleFavorite(port) }
        if let number = port.port {
            Button("命名收藏…") { store.editingFavorite = store.favorite(for: port) ?? PortFavorite(port: number, transport: port.transport, name: "") }
            Divider()
            Button("复制端口号") { store.copy(String(number)) }
        }
        Button("复制绑定地址") { store.copy(port.address) }
        if let url = store.browserURL(for: port) {
            Menu("在浏览器中打开") {
                Button("HTTP") { NSWorkspace.shared.open(url) }
                Button("HTTPS") { if let secure = store.browserURL(for: port, secure: true) { NSWorkspace.shared.open(secure) } }
            }
            Button("复制 HTTP 地址") { store.copy(url.absoluteString) }
        }
        if let target = store.target(for: port) {
            Divider()
            Button("结束进程…") { store.request(.terminate, for: target, port: port) }
                .disabled(SystemService.actionBlockReason(for: target) != nil || store.operation?.isPending == true)
        }
    }
}

struct FavoriteEditor: View {
    @Environment(AppStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let favorite: PortFavorite
    @State private var name: String
    init(favorite: PortFavorite) { self.favorite = favorite; _name = State(initialValue: favorite.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("为常用端口命名", systemImage: "star.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("\(favorite.transport) · \(String(favorite.port))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary)
            TextField("例如：网站前端、开发数据库", text: $name).textFieldStyle(.roundedBorder)
            Text("按协议和端口保存。服务停止或 PID 改变后，收藏仍然保留。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var value = favorite; value.name = name
                    store.saveFavorite(value); dismiss()
                }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 380)
    }
}
