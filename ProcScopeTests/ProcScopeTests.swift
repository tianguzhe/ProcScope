import XCTest
@testable import ProcScope
import Darwin

final class ProcScopeTests: XCTestCase {
    func testProcessParsingPreservesSpacesAndStates() throws {
        let text = """
          42 1 501 12.5 2048 S 02:05 /Applications/My Editor.app/Contents/MacOS/My Editor
          43 42 501 0.0 512 T 00:08 /bin/sleep
          44 1 0 0.0 0 Z 01:00 (exited)
        bad data
        """
        let records = SystemService.parseProcesses(text)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].executable, "/Applications/My Editor.app/Contents/MacOS/My Editor")
        XCTAssertEqual(records[0].memoryBytes, 2_097_152)
        XCTAssertEqual(records[0].state, .sleeping)
        XCTAssertEqual(records[1].state, .stopped)
        XCTAssertEqual(records[2].state, .zombie)
    }

    func testSocketParsingIncludesIPv6AndDeduplicatesDescriptors() {
        let text = """
        p42
        cnode
        f20
        PTCP
        n127.0.0.1:3000
        TST=LISTEN
        f21
        PTCP
        n[::1]:3000
        TST=LISTEN
        f22
        PTCP
        n127.0.0.1:3000
        TST=LISTEN
        f23
        PTCP
        n127.0.0.1:4000->127.0.0.1:3000
        TST=ESTABLISHED
        p43
        cdiscovery
        f5
        PUDP
        n*:5353
        f6
        PUDP
        n*:*
        """
        let ports = SystemService.parsePorts(text)
        XCTAssertEqual(ports.count, 3)
        XCTAssertEqual(ports.filter { $0.port == 3000 && $0.isLoopback }.count, 2)
        XCTAssertEqual(ports.last?.transport, "UDP")
        XCTAssertEqual(ports.last?.pid, 43)
    }

    func testProtectionRejectsSystemOtherUserAndSelf() {
        let records = SystemService.parseProcesses("""
        1 0 0 0.0 100 S 01:00 /sbin/launchd
        100 1 502 0.0 100 S 01:00 /bin/sleep
        101 1 501 0.0 100 S 01:00 /bin/sleep
        """)
        for record in records {
            XCTAssertNotNil(SystemService.actionBlockReason(for: record, currentUID: 501, ownPID: 101))
        }
    }

    func testStaleIdentityCannotSignalLiveProcess() throws {
        let child = try makeChild()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let identity = try XCTUnwrap(SystemService.readIdentity(pid: child.processIdentifier))
        var record = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        record.identity = ProcessIdentity(pid: identity.pid, startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
        XCTAssertThrowsError(try SystemService.send(.forceKill, to: record))
        XCTAssertTrue(child.isRunning)
    }

    func testPauseResumeAndTerminateOnlyOwnedFixture() throws {
        let child = try makeChild()
        defer {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGCONT); child.terminate() }
            child.waitUntilExit()
        }
        let target = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        XCTAssertEqual(target.executable, "/bin/sleep")
        try SystemService.send(.pause, to: target)
        let paused = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        XCTAssertEqual(paused.state, .stopped)
        try SystemService.send(.resume, to: paused)
        let resumed = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        XCTAssertNotEqual(resumed.state, .stopped)
        try SystemService.send(.terminate, to: resumed)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
    }

    @MainActor
    func testRefreshKeepsLatestSelectionAndClearsReusedPID() {
        let store = AppStore()
        var first = SystemService.parseProcesses("42 1 501 0 100 S 00:01 /bin/first")[0]
        var second = SystemService.parseProcesses("43 1 501 0 100 S 00:01 /bin/second")[0]
        first.identity = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 0)
        second.identity = ProcessIdentity(pid: 43, startSeconds: 101, startMicroseconds: 0)
        store.processes = [first, second]
        store.selectedPID = 42
        // The user switches rows while the next snapshot is being collected.
        store.selectedPID = 43
        store.applyProcessSnapshot([first, second])
        XCTAssertEqual(store.selectedPID, 43)
        second.identity = ProcessIdentity(pid: 43, startSeconds: 200, startMicroseconds: 0)
        store.applyProcessSnapshot([first, second])
        XCTAssertNil(store.selectedPID)
    }

    @MainActor
    func testIndexedAggregationSearchAndSnapshotInvalidation() throws {
        let store = AppStore()
        let app = ApplicationInfo(pid: 42, name: "My Editor", bundlePath: "/Applications/My Editor.app", icon: nil, isActive: true, isHidden: false)
        let records = SystemService.parseProcesses("""
        42 1 501 2.0 100 S 01:00 /Applications/My Editor.app/Contents/MacOS/Editor
        43 42 501 8.0 200 S 00:10 /Applications/My Editor.app/Contents/Helpers/Worker
        44 1 501 50.0 500 T 00:10 /Applications/My Editor.app.backup/Worker
        """)
        store.applyProcessSnapshot(records, applications: [app])
        XCTAssertEqual(store.matchingProcesses.count, 1)
        XCTAssertEqual(store.matchingProcesses.first?.cpu, 10)
        XCTAssertEqual(store.matchingProcesses.first?.memoryBytes, 300 * 1024)
        XCTAssertEqual(store.app(for: 43)?.pid, 42)
        XCTAssertNil(store.app(for: 44))
        store.section = .processes
        store.search = "  my editor  "
        XCTAssertEqual(Set(store.matchingProcesses.map(\.pid)), [42, 43, 44])
        store.search = "Worker"
        store.sort = .memory
        XCTAssertEqual(store.matchingProcesses.map(\.pid), [44, 43])
        store.filter = .paused
        XCTAssertEqual(store.matchingProcesses.map(\.pid), [44])
        store.search = ""
        store.filter = .all
        store.applyProcessSnapshot(Array(records.prefix(2)), applications: [app])
        XCTAssertEqual(store.matchingProcesses.map(\.pid), [43, 42])
        XCTAssertNil(store.app(for: 44))
        XCTAssertEqual(store.totalCPU, 10)
        store.section = .applications
        XCTAssertEqual(store.matchingProcesses.first?.memoryBytes, 300 * 1024)
    }

    @MainActor
    func testPortsAndRelationshipsFollowLatestSnapshot() {
        let store = AppStore()
        store.processes = SystemService.parseProcesses("""
        42 1 501 0 100 S 00:01 /bin/parent
        43 42 501 0 100 S 00:01 /bin/child
        44 43 501 0 100 S 00:01 /bin/grandchild
        """)
        store.selectedPID = 43
        XCTAssertEqual(store.ancestry.map(\.pid), [42])
        XCTAssertEqual(store.childProcesses.map(\.pid), [44])
        store.ports = [PortRecord(pid: 43, processName: "child", transport: "TCP", address: "127.0.0.1:3000"),
                       PortRecord(pid: 44, processName: "grandchild", transport: "UDP", address: "*:5353")]
        store.section = .ports
        store.transportFilter = "TCP"
        XCTAssertEqual(store.matchingPorts.count, 1)
        XCTAssertEqual(store.selectedPorts.first?.port, 3000)
        store.search = "5353"
        XCTAssertTrue(store.matchingPorts.isEmpty)
        store.transportFilter = "UDP"
        XCTAssertEqual(store.matchingPorts.first?.pid, 44)
        store.ports = []
        XCTAssertTrue(store.selectedPorts.isEmpty)
        XCTAssertTrue(store.matchingPorts.isEmpty)
        store.applyProcessSnapshot(Array(store.processes.prefix(1)))
        XCTAssertNil(store.selectedPID)
        XCTAssertTrue(store.childProcesses.isEmpty)
    }

    @MainActor
    func testNestedApplicationsHaveDistinctResourceTotals() {
        let store = AppStore()
        let outer = ApplicationInfo(pid: 42, name: "Outer", bundlePath: "/Outer.app", icon: nil, isActive: false, isHidden: false)
        let inner = ApplicationInfo(pid: 43, name: "Inner", bundlePath: "/Outer.app/Helpers/Inner.app", icon: nil, isActive: false, isHidden: false)
        store.applyProcessSnapshot(SystemService.parseProcesses("""
        42 1 501 2 100 S 00:01 /Outer.app/Contents/MacOS/Outer
        43 42 501 3 100 S 00:01 /Outer.app/Helpers/Inner.app/Contents/MacOS/Inner
        44 43 501 4 100 S 00:01 /Outer.app/Helpers/Inner.app/Contents/Worker
        """), applications: [outer, inner])
        XCTAssertEqual(store.matchingProcesses.map(\.cpu), [7, 2])
        XCTAssertEqual(store.app(for: 44)?.pid, 43)
        XCTAssertEqual(store.associatedProcesses(outer).count, 1)
        XCTAssertEqual(store.associatedProcesses(inner).count, 2)
    }

    @MainActor
    func testCachedListReadsAgainstPreviousAggregation() {
        let store = AppStore()
        let apps: [ApplicationInfo] = (0..<80).map { (index: Int) in
            ApplicationInfo(pid: Int32(index * 10 + 100), name: "App \(index)", bundlePath: "/Applications/App\(index).app", icon: nil, isActive: false, isHidden: false)
        }
        let records: [ProcessRecord] = (0..<800).map { (index: Int) -> ProcessRecord in
            let pid = Int32(index + 100)
            let memory = UInt64(index + 1) * 1024
            let path = "/Applications/App\(index / 10).app/Contents/MacOS/worker"
            return ProcessRecord(pid: pid, parentPID: 1, uid: 501, cpu: Double(index % 20), memoryBytes: memory,
                          rawState: "S", elapsed: "00:01", executable: path, identity: nil)
        }
        store.applyProcessSnapshot(records, applications: apps)
        func previousAggregation() -> [ProcessRecord] {
            let aggregated: [ProcessRecord] = apps.compactMap { app -> ProcessRecord? in
                guard let main = records.first(where: { $0.pid == app.pid }) else { return nil }
                let group = records.filter { $0.pid == app.pid || $0.executable.hasPrefix(app.bundlePath + "/") }
                return ProcessRecord(pid: main.pid, parentPID: main.parentPID, uid: main.uid,
                                     cpu: group.reduce(0) { $0 + $1.cpu }, memoryBytes: group.reduce(0) { $0 + $1.memoryBytes },
                                     rawState: main.rawState, elapsed: main.elapsed, executable: main.executable, identity: nil)
            }
            return aggregated.sorted { $0.cpu == $1.cpu ? $0.pid < $1.pid : $0.cpu > $1.cpu }
        }
        XCTAssertEqual(store.matchingProcesses, previousAggregation())
        var oldCount = 0
        let oldStart = ContinuousClock.now
        for _ in 0..<100 { oldCount += previousAggregation().count }
        let oldElapsed = oldStart.duration(to: .now)
        var newCount = 0
        let newStart = ContinuousClock.now
        for _ in 0..<100 { newCount += store.matchingProcesses.count }
        let newElapsed = newStart.duration(to: .now)
        XCTAssertEqual(oldCount, newCount)
        print("BENCHMARK 800 processes / 80 apps / 100 list reads: previous=\(oldElapsed), cached=\(newElapsed)")
        let indexStart = ContinuousClock.now
        for _ in 0..<100 { store.applyProcessSnapshot(records, applications: apps) }
        print("BENCHMARK 100 indexed snapshots: \(indexStart.duration(to: .now))")
    }

    private func makeChild() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        return child
    }
}
