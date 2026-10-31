import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigation
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 33)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ProcScope").font(.system(size: 18, weight: .semibold, design: .rounded)).tracking(-0.5).foregroundStyle(.white)
                    Text("进 程 透 镜").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.mint.opacity(0.65))
                }
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 42)

            Text("工作空间").font(.system(size: 9, weight: .medium)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.38)).padding(.horizontal, 25).padding(.bottom, 14)
            VStack(spacing: 7) {
                ForEach(Section.allCases) { section in
                    Button { store.switchSection(section) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: section.icon).font(.system(size: 14, weight: .medium)).frame(width: 18)
                            Text(section.title).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(count(for: section)).font(.system(size: 10, design: .monospaced))
                                .opacity(store.section == section ? 0.7 : 0.5)
                        }.padding(.horizontal, 13).frame(height: 45).contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(QuietButtonStyle())
                    .foregroundStyle(store.section == section ? Palette.sidebar : Color.white.opacity(0.66))
                    .background {
                        if store.section == section {
                            RoundedRectangle(cornerRadius: 10).fill(Palette.mint)
                                .matchedGeometryEffect(id: "navigation", in: navigation)
                        }
                    }
                    .accessibilityAddTraits(store.section == section ? .isSelected : [])
                }
            }.padding(.horizontal, 12)
                .animation(reduceMotion ? nil : Motion.gentle, value: store.section)

            VStack(alignment: .leading, spacing: 16) {
                Text("随手，掌控全局。")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                shortcut("快速搜索", key: "⌘ F")
                shortcut("立即刷新", key: "⌘ R")
                shortcut("切换视图", key: "⌘ 1–3")
            }.padding(.horizontal, 25).padding(.top, 43)
            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer").font(.system(size: 16, weight: .light))
                    Text("这台 Mac").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Circle().fill(store.isMonitoring ? Palette.mint : Palette.orange).frame(width: 5, height: 5)
                }.foregroundStyle(.white.opacity(0.8))
                Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
                HStack(spacing: 5) {
                    Image(systemName: store.isMonitoring ? "waveform.path" : "pause.circle").font(.system(size: 10))
                    Text(store.isMonitoring ? "实时采集中" : "自动刷新已暂停").font(.system(size: 10))
                }.foregroundStyle(Palette.mint.opacity(0.8))
                Text("本机处理 · 隐私留在本机").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }.padding(15)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
                .padding(.horizontal, 14).padding(.bottom, 22)
            HStack {
                Button { openSettings() } label: { Label("偏好设置", systemImage: "slider.horizontal.3").font(.system(size: 10)) }.buttonStyle(QuietButtonStyle())
                Spacer()
                Text(AppVersion.current).font(.system(size: 9, design: .monospaced)).opacity(0.6)
            }.foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 25).padding(.bottom, 24)
        }.frame(width: 208).frame(maxHeight: .infinity).background(Palette.sidebar)
    }
    private func count(for section: Section) -> String {
        switch section {
        case .applications: String(store.applications.count)
        case .processes: String(store.processes.count)
        case .ports: String(store.ports.count)
        }
    }
    private func shortcut(_ title: String, key: String) -> some View {
        HStack {
            Text(title).font(.system(size: 10))
            Spacer()
            Text(key).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.56))
        }.foregroundStyle(.white.opacity(0.38))
    }
}
