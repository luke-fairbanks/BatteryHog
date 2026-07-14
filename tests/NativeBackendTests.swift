import Darwin
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatteryHogNativeTests-\(label)-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func synchronousRequest(_ backend: BatteryHogBackend,
                                method: String,
                                path: String,
                                body: [String: Any] = [:]) throws -> BackendResponse {
    let semaphore = DispatchSemaphore(value: 0)
    var response: BackendResponse?
    backend.request(method: method, path: path, body: body) {
        response = $0
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 30) == .success, let response else {
        throw TestFailure.assertion("native request timed out: \(method) \(path)")
    }
    return response
}

@main
enum NativeBackendTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("command classification", testCommandClassification),
            ("workload aggregation", testWorkloadAggregation),
            ("workload edge cases", testWorkloadEdgeCases),
            ("sleep assertion parsing", testSleepAssertions),
            ("power log single-pass parsing", testPowerLogParsing),
            ("settings migration and persistence", testSettings),
            ("slow insights persistence and flags", testSlowInsightsPersistence),
            ("gate registry pruning", testGateRegistry),
            ("gate environment and cleanup integration", testGateEnvironmentAndCleanup),
            ("native router and stats schema", testBackendRouter),
            ("command timeout and inherited pipes", testCommandTimeout),
            ("shell quoting", testShellQuoting)
        ]
        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                failures += 1
                fputs("✗ \(name): \(error)\n", stderr)
            }
        }
        if failures > 0 {
            fputs("\n\(failures) native test\(failures == 1 ? "" : "s") failed.\n", stderr)
            exit(1)
        }
        print("\n\(tests.count) native tests passed.")
    }

    private static func testCommandClassification() throws {
        let rust = WorkloadDetector.classificationForTesting("/opt/homebrew/bin/rustc src/main.rs")
        try expect(rust?["family"] as? String == "Rust", "rustc family changed")
        try expect(rust?["kind"] as? String == "compiler", "rustc kind changed")
        try expect(rust?["heavy"] as? Bool == true, "rustc should be heavy")

        let server = WorkloadDetector.classificationForTesting("node /repo/node_modules/.bin/vite --host")
        try expect(server?["tool"] as? String == "Dev server", "Vite must match before generic Node")
        try expect(server?["kind"] as? String == "server", "Vite should be a server")

        let agent = WorkloadDetector.classificationForTesting("/Applications/ChatGPT.app/Contents/MacOS/codex")
        try expect(agent?["kind"] as? String == "agent", "Codex attribution changed")
        try expect(agent?["tool"] as? String == "Codex", "Codex owner changed")

        let scan = WorkloadDetector.classificationForTesting("/opt/homebrew/bin/gitleaks detect")
        try expect(scan?["kind"] as? String == "scan", "gitleaks should be a scan")
        try expect(scan?["heavy"] as? Bool == true, "gitleaks should be a heavy job")
        try expect(WorkloadDetector.classificationForTesting("/usr/bin/cargo check")?["family"] as? String == "Rust",
                   "Cargo family changed")
        try expect(WorkloadDetector.classificationForTesting("org.gradle.launcher.daemon.bootstrap.GradleDaemon")?["tool"] as? String == "Gradle",
                   "Gradle daemon classification changed")
        try expect(WorkloadDetector.classificationForTesting("next-server (v15.5.12)")?["kind"] as? String == "server",
                   "Next server classification changed")
        try expect(WorkloadDetector.classificationForTesting("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") == nil,
                   "ordinary applications must not become development workloads")
        try expect(WorkloadDetector.classificationForTesting("/Applications/Battery Hog.app/Contents/MacOS/BatteryHog") == nil,
                   "Battery Hog must exclude itself")
    }

    private static func testWorkloadAggregation() throws {
        let root = try temporaryDirectory("workload")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        let detector = WorkloadDetector()
        let samples = [
            ProcessSample(pid: 100, ppid: 1, rssKB: 20_000, cpu: 2,
                          command: "/Applications/ChatGPT.app/Contents/MacOS/codex"),
            ProcessSample(pid: 101, ppid: 100, rssKB: 300_000, cpu: 120,
                          command: "/usr/bin/xcodebuild -scheme BatteryHog"),
            ProcessSample(pid: 102, ppid: 101, rssKB: 180_000, cpu: 80,
                          command: "/usr/bin/swiftc main.swift"),
            ProcessSample(pid: 103, ppid: 100, rssKB: 90_000, cpu: 0.5,
                          command: "node /repo/node_modules/.bin/vite --host")
        ]
        let data = detector.aggregateForTesting(samples, cwdByPID: [100: root.path])
        let workloads = data["workloads"] as? [[String: Any]] ?? []
        try expect(workloads.count == 1, "expected one project workload")
        let workload = try unwrap(workloads.first, "missing workload")
        try expect(workload["name"] as? String == root.lastPathComponent, "project name changed")
        let workerCount = (workload["workers"] as? NSNumber)?.intValue ?? -1
        try expect(workerCount == 3, "agent must not count as worker (got \(workerCount), tools \(workload["tools"] ?? "nil"))")
        try expect((workload["active_workers"] as? NSNumber)?.intValue == 2,
                   "active worker threshold changed")
        try expect((workload["agents"] as? [String]) == ["Codex"], "agent ancestry changed")
        try expect(workload["level"] as? String == "high", "workload level changed")
        try expect((workload["servers"] as? NSNumber)?.intValue == 1,
                   "idle project dev servers must remain visible")
        try expect(workload["status"] as? String == "Building",
                   "the dominant active workload should determine status")
        try expect(Set(workload["families"] as? [String] ?? []) == Set(["Apple", "Node"]),
                   "workload toolchain families changed")
        try expect((workload["id"] as? String)?.count == 12, "workload ID must stay stable-sized")
    }

    private static func testWorkloadEdgeCases() throws {
        let detector = WorkloadDetector()
        let hiddenAgentDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/plugins/example", isDirectory: true).path
        let hidden = detector.aggregateForTesting([
            ProcessSample(pid: 200, ppid: 1, rssKB: 90_000, cpu: 0,
                          command: "/opt/homebrew/bin/node helper.js")
        ], cwdByPID: [200: hiddenAgentDirectory])
        let hiddenSummary = hidden["summary"] as? [String: Any] ?? [:]
        try expect((hiddenSummary["projects"] as? NSNumber)?.intValue == 0,
                   "idle Node helpers in hidden agent directories must be ignored")
        try expect((hiddenSummary["workers"] as? NSNumber)?.intValue == 0,
                   "ignored agent helpers must not inflate worker counts")

        let root = try temporaryDirectory("workload-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        let nested = root.appendingPathComponent("apps/web/src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let samples = [
            ProcessSample(pid: 300, ppid: 1, rssKB: 15_000, cpu: 1,
                          command: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            ProcessSample(pid: 301, ppid: 300, rssKB: 180_000, cpu: 42,
                          command: "/opt/homebrew/bin/pnpm build"),
            ProcessSample(pid: 302, ppid: 300, rssKB: 110_000, cpu: 0,
                          command: "next-server (v15.5.12)")
        ]
        let marked = detector.aggregateForTesting(samples, cwdByPID: [301: nested.path, 302: nested.path])
        let workloads = marked["workloads"] as? [[String: Any]] ?? []
        let workload = try unwrap(workloads.first, "package marker should establish a project")
        try expect(workload["name"] as? String == root.lastPathComponent,
                   "nearest project marker should name the workload")
        try expect(workload["context"] as? String == "apps/web/src",
                   "nested project context was lost")
        try expect(workload["agents"] as? [String] == ["Cursor"],
                   "Cursor ancestry should be attributed through parent PIDs")
        try expect((workload["workers"] as? NSNumber)?.intValue == 2,
                   "agent owners must not count as workers")
        try expect((workload["active_workers"] as? NSNumber)?.intValue == 1,
                   "idle servers should not count as active workers")
        try expect((workload["heavy_workers"] as? NSNumber)?.intValue == 1,
                   "active package builds should count as heavy workers")
        try expect(workload["status"] as? String == "Building",
                   "active build should outrank an idle server for status")

        var manySamples: [ProcessSample] = []
        var manyCWDs: [Int32: String] = [:]
        for index in 0..<25 {
            let project = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
            let pid = Int32(1_000 + index)
            manyCWDs[pid] = project.path
            manySamples.append(ProcessSample(
                pid: pid, ppid: 1, rssKB: 10_000, cpu: 2,
                command: "node \(project.path)/node_modules/.bin/vite --host"
            ))
        }
        let many = detector.aggregateForTesting(manySamples, cwdByPID: manyCWDs)
        let visible = many["workloads"] as? [[String: Any]] ?? []
        let completeSummary = many["summary"] as? [String: Any] ?? [:]
        try expect(visible.count == 24, "workload detail list must stay capped")
        try expect((completeSummary["projects"] as? NSNumber)?.intValue == 25,
                   "workload summary must include projects beyond the detail cap")
        try expect((completeSummary["workers"] as? NSNumber)?.intValue == 25,
                   "workload summary must include every worker")
    }

    private static func testSleepAssertions() throws {
        let fixture = """
          pid 1234(caffeinate): [0x000000] 00:16:12 NoIdleSleepAssertion named: "caffeinate command-line tool"
          pid 50(powerd): [0x000001] 01:10:00 PreventUserIdleSystemSleep named: "Powerd system assertion"
        """
        let blockers = WorkloadDetector.parseSleepAssertions(fixture)
        try expect(blockers.count == 2, "sleep assertion count changed")
        try expect(blockers[0]["name"] as? String == "caffeinate", "user blocker should sort first")
        try expect(blockers[0]["stale"] as? Bool == true, "16-minute user blocker should be stale")
        try expect(blockers[1]["system"] as? Bool == true, "powerd should be a system assertion")
    }

    private static func testPowerLogParsing() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let now = try unwrap(formatter.date(from: "2026-07-13 17:00:00 +0000"),
                             "could not build power-log test date")
        let fixture = """
        2026-07-13 10:00:00 +0000 Assertions            DarkWake from Normal Sleep
        2026-07-12 18:00:00 +0000 Assertions            DarkWake from Normal Sleep
        2026-07-12 16:00:00 +0000 Assertions            DarkWake from Normal Sleep
        2026-07-13 09:00:00 +0000 com.apple.powerd      Using Batt (Charge: 81)
        2026-07-13 10:00:00 +0000 com.apple.powerd      Using AC (Charge: 82)
        """
        let summary = BatteryHogBackend.powerLogSummaryForTesting(fixture, now: now)
        try expect((summary["rows"] as? NSNumber)?.intValue == 2,
                   "power log history rows changed")
        try expect((summary["wakes14"] as? NSNumber)?.intValue == 1,
                   "14-hour wake window changed")
        try expect((summary["wakes24"] as? NSNumber)?.intValue == 2,
                   "24-hour wake window changed")
    }

    private static func testSettings() throws {
        let root = try temporaryDirectory("settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BatteryHogSettingsStore(dataDirectory: root)
        let initial = store.snapshot()
        try expect(((initial["heat"] as? [String: Any])?["enabled"] as? Bool) == false,
                   "Heat alerts must default off")
        let updated = store.update([
            "heat": ["enabled": true],
            "dev": ["slots": 99, "workers": 0, "draw_threshold": 500],
            "low_threshold": 2
        ])
        let dev = updated["dev"] as? [String: Any] ?? [:]
        try expect((dev["slots"] as? NSNumber)?.intValue == 4, "slots must clamp to four")
        try expect((dev["workers"] as? NSNumber)?.intValue == 1, "workers must clamp to one")
        try expect((dev["draw_threshold"] as? NSNumber)?.intValue == 80,
                   "draw threshold must clamp to 80")
        try expect((updated["low_threshold"] as? NSNumber)?.intValue == 5,
                   "low threshold must clamp to five")

        let reloaded = BatteryHogSettingsStore(dataDirectory: root).snapshot()
        try expect(((reloaded["heat"] as? [String: Any])?["enabled"] as? Bool) == true,
                   "Heat setting did not persist")
        try expect(((reloaded["menubar"] as? [String: Any])?["percent"] as? Bool) == true,
                   "nested defaults were lost")
        let settingsMode = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("settings.json").path
        )[.posixPermissions] as? NSNumber
        try expect((settingsMode?.intValue ?? 0) & 0o777 == 0o600,
                   "settings must be readable only by the current user")

        let concurrentRoot = try temporaryDirectory("settings-concurrent")
        defer { try? FileManager.default.removeItem(at: concurrentRoot) }
        let concurrentStore = BatteryHogSettingsStore(dataDirectory: concurrentRoot)
        let writes = DispatchGroup()
        for index in 0..<80 {
            writes.enter()
            DispatchQueue.global().async {
                _ = concurrentStore.update(["low_threshold": 5 + (index % 90)])
                writes.leave()
            }
        }
        try expect(writes.wait(timeout: .now() + 10) == .success,
                   "concurrent settings writes timed out")
        let memorySettings = concurrentStore.snapshot()
        let diskSettings = try unwrap(
            JSONValue.readObject(at: concurrentRoot.appendingPathComponent("settings.json")),
            "concurrent settings did not persist"
        )
        let memoryData = try JSONSerialization.data(withJSONObject: memorySettings,
                                                     options: [.sortedKeys])
        let diskData = try JSONSerialization.data(withJSONObject: diskSettings,
                                                   options: [.sortedKeys])
        try expect(memoryData == diskData,
                   "a stale concurrent settings write reached disk after a newer value")

        let ignoredStore = IgnoredAppsStore(dataDirectory: concurrentRoot)
        let ignoredWrites = DispatchGroup()
        for index in 0..<40 {
            ignoredWrites.enter()
            DispatchQueue.global().async {
                _ = ignoredStore.update(name: "App \(index)", enabled: true, reset: false)
                ignoredWrites.leave()
            }
        }
        try expect(ignoredWrites.wait(timeout: .now() + 10) == .success,
                   "concurrent ignored-app writes timed out")
        let ignoredMemory = ignoredStore.snapshot()
        let ignoredDisk = (JSONValue.readArray(
            at: concurrentRoot.appendingPathComponent("ignored.json")
        ) ?? []).compactMap { $0 as? String }
        try expect(ignoredMemory.count == 40 && ignoredMemory == ignoredDisk,
                   "ignored-app disk state diverged from its latest in-memory state")

        let blockedParent = try temporaryDirectory("settings-failure")
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        let blockedPath = blockedParent.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedPath)
        let blockedSettings = BatteryHogSettingsStore(dataDirectory: blockedPath)
        let failedSettings = blockedSettings.updatePersisting(["alerts": true])
        try expect(!failedSettings.persisted,
                   "settings write unexpectedly succeeded through a regular file")
        try expect(blockedSettings.snapshot()["alerts"] as? Bool == false,
                   "failed settings persistence changed the active in-memory value")
        let blockedIgnored = IgnoredAppsStore(dataDirectory: blockedPath)
        let failedIgnored = blockedIgnored.updatePersisting(name: "Example", enabled: true,
                                                             reset: false)
        try expect(!failedIgnored.persisted && blockedIgnored.snapshot().isEmpty,
                   "failed ignored-app persistence changed the active in-memory value")

        let malformedRoot = try temporaryDirectory("settings-validation")
        defer { try? FileManager.default.removeItem(at: malformedRoot) }
        try JSONValue.write([
            "heat": ["enabled": "yes"],
            "menubar": ["watts": false],
            "dev": ["slots": 3]
        ], to: malformedRoot.appendingPathComponent("settings.json"))
        let validated = BatteryHogSettingsStore(dataDirectory: malformedRoot).snapshot()
        try expect(((validated["heat"] as? [String: Any])?["enabled"] as? Bool) == false,
                   "non-boolean persisted heat settings must be rejected")
        try expect(((validated["menubar"] as? [String: Any])?["watts"] as? Bool) == false,
                   "valid nested settings should survive migration")
        try expect(((validated["menubar"] as? [String: Any])?["percent"] as? Bool) == true,
                   "partial persisted settings must retain nested defaults")
        try expect(((validated["dev"] as? [String: Any])?["slots"] as? NSNumber)?.intValue == 3,
                   "valid development settings should survive migration")
    }

    private static func testSlowInsightsPersistence() throws {
        let root = try temporaryDirectory("slow-insights")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SlowInsightsStore(dataDirectory: root)

        let initial = store.statsSnapshot()
        try expect(initial["wakes"] as? NSNumber == 0, "new slow store should start at zero wakes")
        try expect(initial["insights_loading"] as? Bool == true,
                   "uncached insights should report loading")
        try expect(initial["insights_refreshing"] as? Bool == false,
                   "uncached insights must not claim a refresh has started yet")
        try expect(initial["insights_stale"] as? Bool == false,
                   "missing insights are loading, not stale")
        try expect(store.beginRefresh(), "first slow refresh should start")
        try expect(!store.beginRefresh(force: true), "refreshes must remain single-flight")

        let insights: [String: Any] = [
            "today": ["rate": 9.5, "runtime_h": 10.5,
                      "on_battery_h": 3.0, "charging_h": 0.5],
            "week": ["rate": 8.0, "runtime_h": 12.5,
                     "on_battery_h": 15.0, "charging_h": 4.0],
            "charges": 3, "wakes": 6, "ok": true
        ]
        let historyRows = [
            SlowHistoryRow(timestamp: Date().timeIntervalSince1970 - 3_600,
                           percent: 74, onAC: false),
            SlowHistoryRow(timestamp: Date().timeIntervalSince1970 - 1_800,
                           percent: 71, onAC: false)
        ]
        let wakeDates = [Date().timeIntervalSince1970 - 7_200]
        try expect(store.finish(wakes: 5, insights: insights,
                                historyRows: historyRows, wakeDates: wakeDates),
                   "slow refresh should publish only after persistence succeeds")

        let savedURL = root.appendingPathComponent("insights-cache.json")
        let saved = try unwrap(JSONValue.readObject(at: savedURL),
                               "slow refresh did not persist its cache")
        try expect((saved["schema"] as? NSNumber)?.intValue == 1,
                   "slow cache schema changed")
        try expect((saved["wakes"] as? NSNumber)?.intValue == 5,
                   "persisted wake count changed")
        try expect(((saved["insights"] as? [String: Any])?["charges"] as? NSNumber)?.intValue == 3,
                   "persisted insights payload changed")
        try expect((saved["history_rows"] as? [[String: Any]])?.count == 2,
                   "parsed charge history did not persist")
        try expect((saved["wake_dates"] as? [Any])?.count == 1,
                   "wake timestamps did not persist")

        let fresh = store.statsSnapshot()
        try expect(fresh["insights_loading"] as? Bool == false,
                   "finished insights should stop loading")
        try expect(fresh["insights_refreshing"] as? Bool == false,
                   "finished insights should stop refreshing")
        try expect(fresh["insights_stale"] as? Bool == false,
                   "fresh insights should not be stale")
        try expect(!store.beginRefresh(), "fresh insights should honor the refresh interval")
        try expect(!store.beginRefresh(force: true),
                   "a forced refresh must still honor the retry throttle")

        let reloadedStore = SlowInsightsStore(dataDirectory: root)
        let reloaded = reloadedStore.statsSnapshot()
        try expect((reloaded["wakes"] as? NSNumber)?.intValue == 1,
                   "a new process did not reload and age the wake history")
        try expect(((reloaded["insights"] as? [String: Any])?["today"] as? [String: Any])?["rate"] as? NSNumber == 9.5,
                   "a new process did not reload the insight cache")
        try expect(reloaded["insights_loading"] as? Bool == false,
                   "reloaded cached insights should be useful immediately")
        try expect(reloaded["insights_refreshing"] as? Bool == false,
                   "a recent persisted cache should avoid a launch-time refresh")
        try expect(reloaded["insights_stale"] as? Bool == false,
                   "a recent persisted cache should be fresh across launches")
        try expect(!reloadedStore.beginRefresh(),
                   "a recent persisted cache must suppress the automatic full-log scan")
        let reloadedHistory = reloadedStore.historySnapshot()
        try expect(reloadedHistory.available && reloadedHistory.rows.count == 2
            && reloadedHistory.wakeDates.count == 1,
                   "a new process did not reload parsed history")
        try expect(reloadedStore.beginRefresh(force: true),
                   "History should be able to request a single forced refresh")
        reloadedStore.failRefresh()
        let afterFailure = reloadedStore.statsSnapshot()
        try expect(afterFailure["insights_refreshing"] as? Bool == false,
                   "a failed refresh must clear its active flag")
        try expect(afterFailure["insights_stale"] as? Bool == false,
                   "a failed refresh must preserve the last good snapshot")

        let blockedParent = try temporaryDirectory("slow-insights-failure")
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        let blockedPath = blockedParent.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedPath)
        let blockedStore = SlowInsightsStore(dataDirectory: blockedPath)
        try expect(blockedStore.beginRefresh(), "failed-write test refresh did not start")
        try expect(!blockedStore.finish(wakes: 9, insights: insights,
                                        historyRows: historyRows, wakeDates: wakeDates),
                   "slow cache write unexpectedly succeeded through a regular file")
        let blockedStats = blockedStore.statsSnapshot()
        try expect(blockedStats["insights_loading"] as? Bool == true
            && blockedStats["insights_refreshing"] as? Bool == false,
                   "failed persistence published a fresh in-memory snapshot")
        try expect(blockedStore.historySnapshot().rows.isEmpty,
                   "failed persistence replaced canonical history")

        let legacyRoot = try temporaryDirectory("slow-insights-legacy")
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        try JSONValue.write([
            "schema": 1, "saved_at": Date().timeIntervalSince1970,
            "wakes": 2, "insights": insights
        ], to: legacyRoot.appendingPathComponent("insights-cache.json"))
        let legacyStore = SlowInsightsStore(dataDirectory: legacyRoot)
        try expect(legacyStore.statsSnapshot()["insights_stale"] as? Bool == false,
                   "recent legacy insights should remain useful after upgrade")
        try expect(!legacyStore.historySnapshot().available,
                   "an insights-only legacy cache masqueraded as parsed history")
        try expect(!legacyStore.beginRefresh(),
                   "legacy insights should not reintroduce a launch-time log scan")
        try expect(legacyStore.beginRefresh(force: true),
                   "opening History must be able to migrate an insights-only cache")
        legacyStore.failRefresh()
    }

    private static func testGateRegistry() throws {
        let root = try temporaryDirectory("gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let ownIdentity = try unwrap(AgentGateStore.processIdentity(getpid()),
                                     "could not read test-process identity")
        let registry: [String: Any] = [
            "version": 1,
            "entries": [
                ["id": "live", "pid": Int(getpid()), "state": "active",
                 "pid_identity": ownIdentity,
                 "requested_at": 1, "label": "test", "project": "Tests", "cwd": "~"],
                ["id": "dead", "pid": 2_000_000_000, "state": "queued",
                 "requested_at": 2, "label": "old", "project": "Tests", "cwd": "~"]
            ]
        ]
        try JSONValue.write(registry, to: root.appendingPathComponent("agent-gate.json"))
        let snapshot = AgentGateStore(dataDirectory: root).snapshot()
        try expect((snapshot["active"] as? [[String: Any]])?.count == 1,
                   "live gate entry was lost")
        try expect((snapshot["queued"] as? [[String: Any]])?.isEmpty == true,
                   "dead gate entry was not pruned")
        let pruned = try unwrap(JSONValue.readObject(at: root.appendingPathComponent("agent-gate.json")),
                                "gate registry disappeared after pruning")
        try expect((pruned["entries"] as? [[String: Any]])?.count == 1,
                   "dead gate entry was not pruned from disk")

        let readOnlyRoot = try temporaryDirectory("gate-read-only")
        defer { try? FileManager.default.removeItem(at: readOnlyRoot) }
        let readOnlyURL = readOnlyRoot.appendingPathComponent("agent-gate.json")
        try JSONValue.write([
            "version": 1,
            "entries": [["id": "live", "pid": Int(getpid()), "state": "active",
                         "requested_at": 1, "label": "test", "project": "Tests", "cwd": "~"]]
        ], to: readOnlyURL)
        let before = try Data(contentsOf: readOnlyURL)
        _ = AgentGateStore(dataDirectory: readOnlyRoot).snapshot()
        let after = try Data(contentsOf: readOnlyURL)
        try expect(before == after, "a read-only gate snapshot rewrote the registry")

        let childRoot = try temporaryDirectory("gate-child-liveness")
        defer { try? FileManager.default.removeItem(at: childRoot) }
        try JSONValue.write([
            "version": 1,
            "entries": [
                ["id": "orphaned-wrapper", "pid": 2_000_000_000,
                 "pid_identity": "gone", "child_pid": Int(getpid()),
                 "child_identity": ownIdentity, "state": "active", "requested_at": 1],
                ["id": "reused-pid", "pid": Int(getpid()),
                 "pid_identity": "wrong-start-time", "child_pid": NSNull(),
                 "child_identity": NSNull(), "state": "queued", "requested_at": 2]
            ]
        ], to: childRoot.appendingPathComponent("agent-gate.json"))
        let childSnapshot = AgentGateStore(dataDirectory: childRoot).snapshot()
        try expect((childSnapshot["active"] as? [[String: Any]])?.count == 1,
                   "a live heavy child stopped counting when its wrapper disappeared")
        try expect((childSnapshot["queued"] as? [[String: Any]])?.isEmpty == true,
                   "a reused PID kept a stale gate entry alive")

        let migrationRoot = try temporaryDirectory("gate-migration")
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        try JSONValue.write([
            "version": 1,
            "entries": [["id": "python-era", "pid": Int(getpid()), "state": "active",
                         "requested_at": 1, "label": "legacy"]]
        ], to: migrationRoot.appendingPathComponent("agent-gate.json"))
        let migrationStore = AgentGateStore(dataDirectory: migrationRoot)
        let held = try migrationStore.admission(for: [
            "id": "swift-era", "pid": Int(getpid()), "pid_identity": ownIdentity,
            "state": "queued", "requested_at": 2
        ], slots: 2)
        try expect(!held.admitted, "a Swift gate raced a still-running Python-era gate")
        let migrationRegistry = try unwrap(
            JSONValue.readObject(at: migrationRoot.appendingPathComponent("agent-gate.json")),
            "migration registry disappeared"
        )
        try expect((migrationRegistry["entries"] as? [[String: Any]])?.count == 1,
                   "a Swift gate wrote into the legacy locking window")

        let raceRoot = try temporaryDirectory("gate-legacy-race")
        defer { try? FileManager.default.removeItem(at: raceRoot) }
        let raceRegistry = raceRoot.appendingPathComponent("agent-gate.json")
        let raceMarker = raceRoot.appendingPathComponent("locked")
        let legacyScript = raceRoot.appendingPathComponent("batteryhog_gate.py")
        let script = """
        import fcntl, json, os, time
        path = os.environ["BATTERY_HOG_RACE_REGISTRY"]
        marker = os.environ["BATTERY_HOG_RACE_MARKER"]
        with open(path, "a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            handle.seek(0); handle.truncate(); handle.flush(); os.fsync(handle.fileno())
            open(marker, "w", encoding="utf-8").write("locked")
            time.sleep(1)
            handle.seek(0)
            json.dump({"version": 1, "entries": [{"id": "legacy-race", "pid": os.getpid(), "state": "active", "requested_at": 1}]}, handle)
            handle.truncate(); handle.flush(); os.fsync(handle.fileno())
        """
        try Data(script.utf8).write(to: legacyScript)
        let legacyWriter = Process()
        legacyWriter.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        legacyWriter.arguments = [legacyScript.path]
        var legacyEnvironment = ProcessInfo.processInfo.environment
        legacyEnvironment["BATTERY_HOG_RACE_REGISTRY"] = raceRegistry.path
        legacyEnvironment["BATTERY_HOG_RACE_MARKER"] = raceMarker.path
        legacyWriter.environment = legacyEnvironment
        try legacyWriter.run()
        let markerDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: raceMarker.path), Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try expect(FileManager.default.fileExists(atPath: raceMarker.path),
                   "legacy gate race fixture did not acquire its lock")
        let raceAdmission = try AgentGateStore(dataDirectory: raceRoot).admission(for: [
            "id": "swift-racer", "pid": Int(getpid()), "pid_identity": ownIdentity,
            "state": "queued", "requested_at": 2
        ], slots: 2)
        try expect(!raceAdmission.admitted,
                   "Swift gate admitted work during a legacy truncate/write window")
        try expect((try? Data(contentsOf: raceRegistry).isEmpty) == true,
                   "Swift gate replaced a legacy registry while its writer was active")
        legacyWriter.waitUntilExit()
        try expect(legacyWriter.terminationStatus == 0, "legacy gate race fixture failed")

        let busyRoot = try temporaryDirectory("gate-busy")
        defer { try? FileManager.default.removeItem(at: busyRoot) }
        let busyURL = busyRoot.appendingPathComponent("agent-gate.json")
        try JSONValue.write(["version": 1, "entries": [[String: Any]]()], to: busyURL)
        let busyLockURL = busyRoot.appendingPathComponent("agent-gate.lock")
        let descriptor = Darwin.open(busyLockURL.path,
                                     O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        try expect(descriptor >= 0, "could not open gate lock fixture")
        defer { Darwin.close(descriptor) }
        try expect(flock(descriptor, LOCK_EX) == 0, "could not hold gate lock fixture")
        defer { flock(descriptor, LOCK_UN) }
        let lockStarted = Date()
        let busySnapshot = AgentGateStore(dataDirectory: busyRoot).snapshot()
        try expect(Date().timeIntervalSince(lockStarted) < 1,
                   "a stopped gate lock holder blocked dashboard polling")
        try expect((busySnapshot["active"] as? [[String: Any]])?.isEmpty == true,
                   "busy gate fallback must remain JSON-safe")
    }

    private static func testGateEnvironmentAndCleanup() throws {
        guard let executable = ProcessInfo.processInfo.environment["BATTERY_HOG_TEST_GATE"],
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw TestFailure.assertion("compiled gate test executable is unavailable")
        }
        let root = try temporaryDirectory("gate-integration")
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONValue.write([
            "dev": ["enabled": true, "slots": 1, "workers": 3,
                    "draw_threshold": 44, "notify_draw": false]
        ], to: root.appendingPathComponent("settings.json"))

        let isolated = AgentGateEnvironment.dataDirectory(environment: [
            "BATTERY_HOG_DATA_DIR": root.path
        ])
        try expect(isolated.standardizedFileURL == root.standardizedFileURL,
                   "gate did not honor BATTERY_HOG_DATA_DIR")
        let settings = AgentGateSettings.load(from: isolated)
        try expect(settings.enabled, "gate did not load enabled state")
        try expect(settings.slots == 1 && settings.workers == 3,
                   "gate did not load isolated slot and worker limits")
        try expect(settings.drawThreshold == 44 && !settings.notifyDraw,
                   "gate did not load the remaining development settings")

        let captureURL = root.appendingPathComponent("gate-child.txt")
        let childURL = root.appendingPathComponent("gradlew")
        let child = """
        #!/bin/sh
        {
          printf 'gated=%s\\n' "${BATTERY_HOG_GATED:-}"
          printf 'cargo=%s\\n' "${CARGO_BUILD_JOBS:-}"
          printf 'rayon=%s\\n' "${RAYON_NUM_THREADS:-}"
          printf 'go=%s\\n' "${GOMAXPROCS:-}"
          printf 'internal=%s\\n' "${BATTERY_HOG_GATE_ENTRY_ID:-}"
          printf 'args=%s\\n' "$*"
        } > "$BATTERY_HOG_TEST_CAPTURE"
        exit "${BATTERY_HOG_TEST_EXIT:-0}"
        """
        try Data(child.utf8).write(to: childURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: childURL.path)

        var environment = ProcessInfo.processInfo.environment
        environment["BATTERY_HOG_DATA_DIR"] = root.path
        environment["BATTERY_HOG_TEST_CAPTURE"] = captureURL.path
        environment["BATTERY_HOG_TEST_EXIT"] = "7"
        for key in ["BATTERY_HOG_GATED", "CARGO_BUILD_JOBS", "RAYON_NUM_THREADS", "GOMAXPROCS"] {
            environment.removeValue(forKey: key)
        }
        let result = SystemCommand.run(
            executable,
            ["--force-battery", "--force-enabled", "--", childURL.path, "assemble"],
            timeout: 12,
            environment: environment,
            currentDirectory: root
        )
        try expect(!result.timedOut, "gate integration command timed out")
        try expect(result.status == 7, "gate did not propagate the child exit status")
        let capture = try String(contentsOf: captureURL, encoding: .utf8)
        for expected in ["gated=1", "cargo=3", "rayon=3", "go=3", "internal=\n",
                         "args=assemble --max-workers=3"] {
            try expect(capture.contains(expected), "gate child did not receive \(expected)")
        }
        let snapshot = AgentGateStore(dataDirectory: root).snapshot()
        try expect((snapshot["active"] as? [[String: Any]])?.isEmpty == true,
                   "finished gate remained active")
        try expect((snapshot["queued"] as? [[String: Any]])?.isEmpty == true,
                   "finished gate remained queued")
        let registry = try unwrap(JSONValue.readObject(at: root.appendingPathComponent("agent-gate.json")),
                                  "gate did not create its registry")
        try expect((registry["entries"] as? [[String: Any]])?.isEmpty == true,
                   "snapshot did not prune the finished command entry")

        let preserved = SystemCommand.run(
            executable,
            ["--force-enabled", "--", "/bin/echo", "--force-battery", "payload"],
            timeout: 12,
            environment: environment,
            currentDirectory: root
        )
        try expect(preserved.status == 0, "gate argument-preservation command failed")
        try expect(preserved.stdout == "--force-battery payload\n",
                   "gate wrapper flags consumed arguments after --")

        let misleadingLegacyArgument = SystemCommand.run(
            executable,
            ["--force-battery", "--force-enabled", "--", "/bin/echo",
             "batteryhog_gate.py"],
            timeout: 5,
            environment: environment,
            currentDirectory: root
        )
        try expect(misleadingLegacyArgument.status == 0
            && misleadingLegacyArgument.stdout == "batteryhog_gate.py\n",
                   "an ordinary command argument was mistaken for a legacy gate process")

        let blockedParent = try temporaryDirectory("gate-fail-open")
        defer { try? FileManager.default.removeItem(at: blockedParent) }
        let blockedDataDirectory = blockedParent.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedDataDirectory)
        var blockedEnvironment = environment
        blockedEnvironment["BATTERY_HOG_DATA_DIR"] = blockedDataDirectory.path
        let failOpen = SystemCommand.run(
            executable,
            ["--force-battery", "--force-enabled", "--", "/bin/echo", "still-runs"],
            timeout: 5,
            environment: blockedEnvironment,
            currentDirectory: root
        )
        try expect(failOpen.status == 0 && failOpen.stdout == "still-runs\n",
                   "registry failure did not honor the documented fail-open behavior")

        let backgroundStarted = Date()
        let background = SystemCommand.run(
            executable,
            ["--force-battery", "--force-enabled", "--", "/bin/sh", "-c", "sleep 1 &"],
            timeout: 8,
            environment: environment,
            currentDirectory: root
        )
        try expect(background.status == 0, "gate background-worker command failed")
        let backgroundDuration = Date().timeIntervalSince(backgroundStarted)
        try expect(backgroundDuration >= 0.7 && backgroundDuration < 5,
                   "gate stopped tracking the process group when its driver exited")
        _ = AgentGateStore(dataDirectory: root).snapshot()
        let afterBackground = try unwrap(
            JSONValue.readObject(at: root.appendingPathComponent("agent-gate.json")),
            "gate registry disappeared after background worker"
        )
        try expect((afterBackground["entries"] as? [[String: Any]])?.isEmpty == true,
                   "gate left a completed process group in the registry")
    }

    private static func testBackendRouter() throws {
        let root = try temporaryDirectory("backend")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = BatteryHogConfiguration(
            dataDirectory: root,
            gateExecutable: URL(fileURLWithPath: "/Applications/Battery Hog.app/Contents/Helpers/batteryhog-gate"),
            preview: true
        )
        let backend = BatteryHogBackend(configuration: configuration)
        defer { backend.stop() }

        let missing = try synchronousRequest(backend, method: "GET", path: "/api/nope")
        try expect(missing.status == 404, "unknown native route must be rejected")
        let update = try synchronousRequest(backend, method: "POST", path: "/api/settings",
                                            body: ["heat": ["enabled": true]])
        try expect(update.status == 200, "settings route failed")
        let orderedWrites = DispatchGroup()
        for value in 10...24 {
            orderedWrites.enter()
            backend.request(method: "POST", path: "/api/settings",
                            body: ["low_threshold": value]) { _ in orderedWrites.leave() }
        }
        try expect(orderedWrites.wait(timeout: .now() + 10) == .success,
                   "ordered settings routes timed out")
        let ordered = try synchronousRequest(backend, method: "GET", path: "/api/settings")
        let orderedSettings = ordered.body as? [String: Any] ?? [:]
        try expect((orderedSettings["low_threshold"] as? NSNumber)?.intValue == 24,
                   "concurrent routing reordered settings mutations")

        let started = Date()
        let response = try synchronousRequest(backend, method: "GET", path: "/api/stats")
        try expect(response.status == 200, "stats route failed")
        try expect(Date().timeIntervalSince(started) < 12, "initial native stats response is too slow")
        guard let stats = response.body as? [String: Any] else {
            throw TestFailure.assertion("stats response was not an object")
        }
        for key in ["battery", "memory", "processes", "workloads", "dev_summary",
                    "sleep_blockers", "power_policy", "gate", "lowpower", "health",
                    "power", "uptime", "wakes", "insights", "ignored", "settings",
                    "preview", "ncpu", "ts"] {
            try expect(stats[key] != nil, "stats schema is missing \(key)")
        }
        try expect(stats["preview"] as? Bool == true, "preview isolation flag was lost")
        try expect(JSONSerialization.isValidJSONObject(stats), "stats response is not JSON-safe")
        let processes = stats["processes"] as? [[String: Any]] ?? []
        for process in processes {
            let pids = process["pids"] as? [NSNumber] ?? []
            try expect(pids.allSatisfy { $0.intValue > 0 }, "stats exposed a non-positive PID")
        }
    }

    private static func testShellQuoting() throws {
        try expect(SystemCommand.shellQuote("Battery Hog") == "'Battery Hog'", "space quoting changed")
        try expect(SystemCommand.shellQuote("it's") == "'it'\"'\"'s'", "apostrophe quoting is unsafe")
    }

    private static func testCommandTimeout() throws {
        let started = Date()
        let inheritedPipe = SystemCommand.run(
            "/bin/sh", ["-c", "(sleep 3) & printf ready"], timeout: 2
        )
        try expect(inheritedPipe.status == 0, "short parent command should finish normally")
        try expect(inheritedPipe.stdout == "ready", "command output was lost before pipe closure")
        try expect(Date().timeIntervalSince(started) < 2.5,
                   "a descendant holding stdout open blocked the command runner")

        let timeoutStarted = Date()
        let timedOut = SystemCommand.run("/bin/sleep", ["5"], timeout: 0.1)
        try expect(timedOut.timedOut, "command timeout flag was not set")
        try expect(Date().timeIntervalSince(timeoutStarted) < 2,
                   "timed-out command did not return promptly")

        let filtered = SystemCommand.run(
            "/usr/bin/printf", ["keep one\nskip\nkeep two\n"], timeout: 2,
            stdoutLineFilter: { $0.hasPrefix("keep") }
        )
        try expect(filtered.stdout == "keep one\nkeep two\n",
                   "streaming line filter retained the wrong command output")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure.assertion(message) }
        return value
    }
}
