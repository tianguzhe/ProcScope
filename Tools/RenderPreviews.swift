import AppKit
import SwiftUI

/// Public marketing images use deterministic fixtures and the actual views.
/// This executable never starts monitoring or invokes any process actions.
@main
struct RenderPreviews {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = AppStore()
        let fixtures: [(Int32, String, String, Double, UInt64)] = [
            (2401, "Terminal", "/System/Applications/Utilities/Terminal.app", 8.4, 148),
            (2402, "Safari", "/Applications/Safari.app", 5.2, 432),
            (2403, "Xcode", "/Applications/Xcode.app", 12.8, 824),
            (2404, "Notes", "/System/Applications/Notes.app", 0.3, 96),
            (2405, "Finder", "/System/Library/CoreServices/Finder.app", 0.6, 124),
            (2406, "Preview", "/System/Applications/Preview.app", 0.0, 72),
            (2407, "Music", "/System/Applications/Music.app", 1.2, 186),
        ]
        let apps = fixtures.map { pid, name, path, _, _ in
            ApplicationInfo(pid: pid, name: name, bundlePath: path, icon: NSWorkspace.shared.icon(forFile: path), isActive: name == "Terminal", isHidden: false)
        }
        var records = fixtures.map { pid, name, path, cpu, memory in
            record(pid, parent: 1, cpu: cpu, memory: memory, path: path + "/Contents/MacOS/" + name)
        }
        records += [
            record(3184, parent: 2401, cpu: 3.1, memory: 86, path: "/opt/homebrew/bin/node"),
            record(3210, parent: 2401, cpu: 0.2, memory: 42, path: "/opt/homebrew/bin/python3"),
            record(3256, parent: 1, cpu: 0.1, memory: 32, path: "/opt/homebrew/bin/redis-server"),
            record(3290, parent: 1, cpu: 0.3, memory: 64, path: "/opt/homebrew/bin/postgres"),
            record(1, parent: 0, cpu: 0.0, memory: 18, path: "/sbin/launchd"),
        ]
        store.applyProcessSnapshot(records, applications: apps)
        store.ports = [
            PortRecord(pid: 3184, processName: "node", transport: "TCP", address: "127.0.0.1:3000"),
            PortRecord(pid: 3210, processName: "python3", transport: "TCP", address: "127.0.0.1:8000"),
            PortRecord(pid: 3256, processName: "redis-server", transport: "TCP", address: "127.0.0.1:6379"),
            PortRecord(pid: 3290, processName: "postgres", transport: "TCP", address: "127.0.0.1:5432"),
        ]
        store.updatedAt = nil
        store.portsUpdatedAt = nil
        for (name, section, dark) in [("procscope-preview", Section.applications, false), ("procscope-ports", .ports, false), ("procscope-dark", .applications, true)] {
            store.section = section
            store.selectedPID = section == .ports ? 3184 : 2401
            store.selectedPortID = section == .ports ? store.ports.first?.id : nil
            let selected = store.selectedProcess!
            store.detail = ProcessDetail(identity: selected.identity!,
                command: section == .ports ? "node server.js --port 3000" : "/bin/zsh --login",
                workingDirectory: "/Users/demo/Projects/workspace", warnings: [])
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApplication.shared.appearance = appearance
            let view = NSHostingView(rootView: HStack(spacing: 0) {
                SidebarView()
                ProcessListView()
                Rectangle().fill(Palette.line).frame(width: 1)
                InspectorView()
            }.environment(store).environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }.tint(Palette.accent)
                .frame(width: 1240, height: 810))
            view.appearance = appearance
            view.frame = NSRect(x: 0, y: 0, width: 1240, height: 810)
            let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render preview") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            print("\(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
            window.contentView = nil
        }
    }
    static func record(_ pid: Int32, parent: Int32, cpu: Double, memory: UInt64, path: String) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: parent, uid: pid == 1 ? 0 : getuid(), cpu: cpu,
                      memoryBytes: memory * 1024 * 1024, rawState: "S", elapsed: "02:14:36", executable: path,
                      identity: ProcessIdentity(pid: pid, startSeconds: 1_700_000_000, startMicroseconds: 0))
    }
}
