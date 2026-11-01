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
        let store = AppStore(defaults: nil)
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
        let store = AppStore(defaults: nil)
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
        let store = AppStore(defaults: nil)
        store.processes = SystemService.parseProcesses("""
        42 1 501 0 100 S 00:01 /bin/parent
        43 42 501 0 100 S 00:01 /bin/child
        44 43 501 0 100 S 00:01 /bin/grandchild
        """)
        store.processes = store.processes.map { record in
            var value = record; value.identity = ProcessIdentity(pid: record.pid, startSeconds: 100, startMicroseconds: 0); return value
        }
        store.selectedPID = 43
        XCTAssertEqual(store.ancestry.map(\.pid), [42])
        XCTAssertEqual(store.childProcesses.map(\.pid), [44])
        store.ports = [PortRecord(pid: 43, processName: "child", transport: "TCP", address: "127.0.0.1:3000", identity: store.processes[1].identity),
                       PortRecord(pid: 44, processName: "grandchild", transport: "UDP", address: "*:5353", identity: store.processes[2].identity)]
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
        let store = AppStore(defaults: nil)
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
        let store = AppStore(defaults: nil)
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

    func testCommandTimeoutEscalatesIgnoredTermination() {
        let start = Date()
        XCTAssertThrowsError(try CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.15)) { error in
            guard case CommandError.timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCommandCancellationStopsOwnedSubprocess() async throws {
        let worker = Task { try await CommandRunner.background { try CommandRunner.run("/bin/sleep", ["30"]) } }
        try await Task.sleep(for: .milliseconds(100))
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCommandDrainsLargeOutput() throws {
        let result = try CommandRunner.run("/usr/bin/awk", ["BEGIN { for (i=0; i<20000; i++) print \"sample\" }"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 140_000)
    }

    func testNativeDetailsAndArgumentBoundaries() throws {
        let child = try makeChild()
        defer { child.terminate(); child.waitUntilExit() }
        let target = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        let detail = try SystemService.fetchDetail(for: target)
        XCTAssertTrue(detail.command?.contains("sleep 30") == true)
        XCTAssertNotNil(detail.workingDirectory)
        var count: Int32 = 3
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/bin/tool\0\0tool\0hello world\0\0SECRET=not-an-argument\0".utf8)
        XCTAssertEqual(SystemService.parseArguments(bytes), "tool 'hello world' ''")
        XCTAssertNil(SystemService.parseArguments([0, 1]))
    }

    func testLivePortScanBindsSocketToProcessIdentity() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let socket = try XCTUnwrap(SystemService.fetchPorts().first { $0.pid == getpid() && $0.port == port && $0.transport == "TCP" })
        XCTAssertNotNil(socket.identity)
        XCTAssertEqual(socket.identity, SystemService.readIdentity(pid: getpid()))
    }

    @MainActor
    func testForcedRefreshDuringScanIsCoalescedAndAwaited() async throws {
        let probe = ScanProbe()
        let source = SnapshotSource(processes: { await probe.processes() }, ports: { await probe.ports() })
        let store = AppStore(defaults: nil, source: source)
        store.portsUpdatedAt = Date()
        let first = Task { await store.refresh() }
        for _ in 0..<100 { if await probe.isBlocked { break }; try await Task.sleep(for: .milliseconds(10)) }
        let second = Task { await store.refresh(forcePorts: true) }
        await Task.yield()
        await probe.release()
        await first.value
        await second.value
        let counts = await probe.counts
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 1)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testManualRefreshReloadsSelectedDetailDespiteCache() async throws {
        let child = try makeChild()
        defer { child.terminate(); child.waitUntilExit() }
        let target = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        let counter = ReadCounter()
        let loader = DetailLoader { record in
            ProcessDetail(identity: record.identity!, command: "read-\(counter.next())", workingDirectory: nil, warnings: [])
        }
        let source = SnapshotSource(processes: { [target] }, ports: { [] })
        let store = AppStore(defaults: nil, source: source, detailLoader: loader)
        store.processes = [target]
        store.select(target.pid)
        for _ in 0..<100 { if !store.detailLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.detail?.command, "read-1")
        await store.refresh(forcePorts: true)
        for _ in 0..<100 { if !store.detailLoading { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.detail?.command, "read-2")
    }

    @MainActor
    func testPortCannotBindToReusedPID() {
        let store = AppStore(defaults: nil)
        var process = SystemService.parseProcesses("42 1 501 0 100 S 00:01 /bin/fixture")[0]
        process.identity = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 0)
        let port = PortRecord(pid: 42, processName: "fixture", transport: "TCP", address: "127.0.0.1:3000", identity: process.identity)
        store.processes = [process]; store.ports = [port]; store.selectedPID = 42
        XCTAssertNotNil(store.target(for: port))
        process.identity = ProcessIdentity(pid: 42, startSeconds: 200, startMicroseconds: 0)
        store.applyProcessSnapshot([process])
        XCTAssertNil(store.target(for: port))
        XCTAssertTrue(store.selectedPorts.isEmpty)
        XCTAssertNil(store.selectedPID)
    }

    @MainActor
    func testFavoritesPersistAcrossRestartAndKeepOfflineServices() throws {
        let suite = "ProcScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppStore(defaults: defaults)
        store.saveFavorite(PortFavorite(port: 3000, transport: "TCP", name: " 网站前端 "))
        store.saveFavorite(PortFavorite(port: 3000, transport: "UDP", name: "发现服务"))
        store.saveFavorite(PortFavorite(port: 70000, transport: "TCP", name: "invalid"))
        let restored = AppStore(defaults: defaults)
        XCTAssertEqual(restored.favorites.count, 2)
        XCTAssertEqual(restored.offlineFavorites.count, 2)
        restored.ports = [PortRecord(pid: 42, processName: "node", transport: "TCP", address: "*:3000")]
        restored.search = "网站"
        XCTAssertEqual(restored.matchingPorts.count, 1)
        restored.search = ""
        XCTAssertEqual(restored.offlineFavorites.map(\.transport), ["UDP"])
        restored.toggleFavorite(restored.ports[0])
        XCTAssertEqual(AppStore(defaults: defaults).favorites.count, 1)
    }

    func testBrowserAddressesRespectProtocolAndBindAddress() {
        func socket(_ address: String, _ transport: String = "TCP") -> PortRecord {
            PortRecord(pid: 42, processName: "fixture", transport: transport, address: address)
        }
        XCTAssertEqual(socket("*:3000").browserURL?.absoluteString, "http://127.0.0.1:3000")
        XCTAssertEqual(socket("[::]:3000").browserURL?.absoluteString, "http://[::1]:3000")
        XCTAssertEqual(socket("192.168.1.8:3000").browserURL?.host, "192.168.1.8")
        XCTAssertNil(socket("*:5353", "UDP").browserURL)
    }

    @MainActor
    func testOperationWaitsForActualExitOfOwnedFixture() async throws {
        let child = try makeChild()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let target = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        let store = AppStore(defaults: nil, source: SnapshotSource(processes: { [] }, ports: { [] }))
        store.perform(PendingAction(action: .terminate, target: target, displayName: "测试子进程"))
        XCTAssertTrue(store.operation?.isPending == true)
        for _ in 0..<100 { if store.operation?.isPending == false { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.operation?.isPending ?? true)
        XCTAssertFalse(store.operation?.isWarning ?? true)
        XCTAssertTrue(store.operation?.message.contains("已退出") == true)
        XCTAssertFalse(child.isRunning)
        XCTAssertFalse(AppStore.actionCompleted(.terminate, state: .running))
        XCTAssertFalse(AppStore.actionCompleted(.resume, state: .exited))
        XCTAssertFalse(AppStore.actionCompleted(.pause, state: .unknown))
    }

    @MainActor
    func testPortActionRefusesSocketNoLongerOwnedByTarget() async throws {
        let child = try makeChild()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let target = try XCTUnwrap(SystemService.fetchProcesses().first { $0.pid == child.processIdentifier })
        let stale = PortRecord(pid: target.pid, processName: "sleep", transport: "TCP", address: "127.0.0.1:65530", identity: target.identity)
        let store = AppStore(defaults: nil)
        store.perform(PendingAction(action: .terminate, target: target, displayName: "测试子进程", port: stale))
        for _ in 0..<100 { if store.operation?.isPending == false { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(store.operation?.isPending ?? true)
        XCTAssertTrue(store.operation?.isWarning == true)
        XCTAssertTrue(child.isRunning)
    }

    func testSystemCPUUsesIntervalTicksIncludingNiceTime() throws {
        let before = CPUTicks(user: 100, system: 100, idle: 800, nice: 10)
        let after = CPUTicks(user: 140, system: 125, idle: 925, nice: 20)
        let usage = try XCTUnwrap(after.usage(since: before))
        XCTAssertEqual(usage.user, 25, accuracy: 0.0001)
        XCTAssertEqual(usage.system, 12.5, accuracy: 0.0001)
        XCTAssertEqual(usage.busy, 37.5, accuracy: 0.0001)
    }

    func testSystemCPUHandlesIdleFullLoadAndCounterRollover() throws {
        let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        XCTAssertNil(zero.usage(since: zero))
        XCTAssertEqual(CPUTicks(user: 0, system: 0, idle: 100, nice: 0).usage(since: zero)?.busy, 0)
        XCTAssertEqual(CPUTicks(user: 75, system: 25, idle: 0, nice: 0).usage(since: zero)?.busy, 100)
        let old = CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)
        let wrapped = try XCTUnwrap(CPUTicks(user: 10, system: 0, idle: 80, nice: 0).usage(since: old))
        XCTAssertEqual(wrapped.busy, 20, accuracy: 0.0001)
    }

    func testSystemCPUSamplerWaitsForBaselineAndResetsLongGaps() async throws {
        let inputs = CPUInputs()
        let sampler = SystemCPUSampler(read: { try inputs.read() }, clock: { inputs.time })
        let initial = try await sampler.sample()
        XCTAssertNil(initial)
        inputs.set(time: 0.1, ticks: CPUTicks(user: 20, system: 10, idle: 70, nice: 0))
        let rapid = try await sampler.sample()
        XCTAssertNil(rapid)
        inputs.set(time: 1, ticks: CPUTicks(user: 20, system: 10, idle: 70, nice: 0))
        let sampled = try await sampler.sample()
        XCTAssertEqual(sampled?.busy, 30)
        inputs.set(time: 32, ticks: CPUTicks(user: 220, system: 110, idle: 770, nice: 0))
        let resumed = try await sampler.sample()
        XCTAssertNil(resumed)
        inputs.set(time: 33, ticks: CPUTicks(user: 240, system: 120, idle: 840, nice: 0))
        let fresh = try await sampler.sample()
        XCTAssertEqual(fresh?.busy, 30)
    }

    func testSystemCPUSamplerReestablishesBaselineAfterFailure() async throws {
        let inputs = CPUInputs()
        let sampler = SystemCPUSampler(read: { try inputs.read() }, clock: { inputs.time })
        _ = try await sampler.sample()
        inputs.set(time: 1, ticks: CPUTicks(user: 20, system: 10, idle: 70, nice: 0), fails: true)
        do { _ = try await sampler.sample(); XCTFail("Expected read failure") } catch { }
        inputs.set(time: 2, ticks: CPUTicks(user: 40, system: 20, idle: 140, nice: 0))
        let recovered = try await sampler.sample()
        XCTAssertNil(recovered)
    }

    @MainActor
    func testSystemCPUIsIndependentOfProcessScanFailure() async {
        let source = SnapshotSource(processes: { throw SystemServiceError.failed("fixture") }, ports: { [] }, cpu: { CPUUsage(user: 20, system: 5) })
        let store = AppStore(defaults: nil, source: source)
        store.processes = SystemService.parseProcesses("42 1 501 180 100 S 00:01 /bin/fixture")
        await store.refresh()
        XCTAssertNotNil(store.scanError)
        XCTAssertEqual(store.totalCPU, 180)
        XCTAssertEqual(store.systemCPU?.busy, 25)
        XCTAssertEqual(store.systemCPUHistory, [25])
    }

    @MainActor
    func testFailedCPUSampleDoesNotDisplayZeroOrStaleReading() async {
        let source = SnapshotSource(processes: { [] }, ports: { [] }, cpu: { throw SystemServiceError.failed("fixture") })
        let store = AppStore(defaults: nil, source: source)
        store.applySystemCPU(CPUUsage(user: 20, system: 5))
        await store.refresh()
        XCTAssertNil(store.systemCPU)
        XCTAssertNotNil(store.systemCPUError)
        XCTAssertTrue(store.systemCPUHistory.isEmpty)
    }

    func testNativeSystemCPUIntervalIsWithinTotalCapacity() async throws {
        let before = try CPUTicks.read()
        try await Task.sleep(for: .milliseconds(250))
        let usage = try XCTUnwrap(CPUTicks.read().usage(since: before))
        XCTAssertTrue((0...100).contains(usage.busy))
        XCTAssertGreaterThanOrEqual(usage.user, 0)
        XCTAssertGreaterThanOrEqual(usage.system, 0)
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

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private actor ScanProbe {
    private var processCount = 0
    private var portCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    var isBlocked: Bool { gate != nil }
    var counts: (Int, Int) { (processCount, portCount) }
    func processes() async -> [ProcessRecord] {
        processCount += 1
        if processCount == 1 { await withCheckedContinuation { gate = $0 } }
        return []
    }
    func ports() -> [PortRecord] { portCount += 1; return [] }
    func release() { gate?.resume(); gate = nil }
}

private final class CPUInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: TimeInterval = 0
    private var ticks = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    private var fails = false
    var time: TimeInterval { lock.lock(); defer { lock.unlock() }; return timestamp }
    func read() throws -> CPUTicks {
        lock.lock(); defer { lock.unlock() }
        if fails { throw SystemServiceError.failed("fixture") }
        return ticks
    }
    func set(time: TimeInterval, ticks: CPUTicks, fails: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        timestamp = time; self.ticks = ticks; self.fails = fails
    }
}
