import Darwin
import AppKit
import Foundation

struct BackendResponse {
    let status: Int
    let body: Any
}

private struct RawProcess {
    let pid: Int32
    let ppid: Int32
    let rssKB: Int
    let cpuTime: Double
    let command: String
}

private struct ProcessDataCache {
    var date: Date?
    var processes: [[String: Any]] = []
    var workloads: [[String: Any]] = []
    var summary: [String: Any] = [:]
}

private struct HistoryRow {
    let date: Date
    let percent: Int
    let onAC: Bool
}

private struct ParsedPowerLog {
    let rows: [HistoryRow]
    let wakeDates: [Date]
}

private struct ValidatedProcessTarget {
    let pid: Int32
    let identity: String
}

final class BatteryHogBackend {
    private static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind",
        "powerd", "watchdogd", "systemstats", "UserEventAgent", "distnoted",
        "cfprefsd", "coreaudiod", "Dock", "Finder", "SystemUIServer",
        "Terminal", "iTerm2", "iTerm", "Spotlight", "controlcenter",
        "Control Center", "NotificationCenter", "secd", "trustd",
        "pmset", "ioreg", "system_profiler", "vm_stat", "sysctl", "ps",
        "lsof", "powermetrics", "osascript", "BatteryHog", "Battery Hog",
        "batteryhog-gate"
    ]

    private let configuration: BatteryHogConfiguration
    private let settingsStore: BatteryHogSettingsStore
    private let ignoredStore: IgnoredAppsStore
    private let slowStore: SlowInsightsStore
    private let gateStore: AgentGateStore
    private let workloadDetector = WorkloadDetector()
    private let workQueue = DispatchQueue(label: "com.lukefairbanks.batteryhog.backend",
                                          qos: .userInitiated, attributes: .concurrent)
    private let mutationQueue = DispatchQueue(label: "com.lukefairbanks.batteryhog.mutations",
                                              qos: .userInitiated)
    private let slowQueue = DispatchQueue(label: "com.lukefairbanks.batteryhog.history",
                                          qos: .utility)

    private let pageSize: Int
    private let totalMemory: UInt64
    private let cpuCount: Int

    private let processLock = NSLock()
    private var processCache = ProcessDataCache()
    private let statsBuildLock = NSLock()
    private var statsCacheDate: Date?
    private var statsCache: [String: Any]?

    private let healthLock = NSLock()
    private var healthDate: Date?
    private var healthCache: [String: Any]?
    private var healthRefreshRunning = false

    private let batteryIOLock = NSLock()
    private var batteryIODate: Date?
    private var batteryIOCache: String?

    private let sleepLock = NSLock()
    private var sleepDate: Date?
    private var sleepCache: [String: Any]?

    private let alertLock = NSLock()
    private var lowAlerted = false
    private var fullAlerted = false
    private var hotProcesses = Set<String>()
    private var highDrawAlerted = false
    private var highDrawHits = 0
    private var alertTimer: DispatchSourceTimer?

    init(configuration: BatteryHogConfiguration) {
        self.configuration = configuration
        settingsStore = BatteryHogSettingsStore(dataDirectory: configuration.dataDirectory)
        ignoredStore = IgnoredAppsStore(dataDirectory: configuration.dataDirectory)
        slowStore = SlowInsightsStore(dataDirectory: configuration.dataDirectory)
        gateStore = AgentGateStore(dataDirectory: configuration.dataDirectory)
        pageSize = Self.sysctlInt("hw.pagesize", fallback: 16_384)
        let memory = Self.sysctlUInt64("hw.memsize", fallback: ProcessInfo.processInfo.physicalMemory)
        totalMemory = memory
        cpuCount = Self.sysctlInt("hw.ncpu", fallback: ProcessInfo.processInfo.processorCount)
        startAlertTimer()
    }

    deinit { alertTimer?.cancel() }

    func stop() {
        alertTimer?.cancel()
        alertTimer = nil
    }

    func request(method: String,
                 path: String,
                 body: [String: Any],
                 completion: @escaping (BackendResponse) -> Void) {
        let normalizedMethod = method.uppercased()
        let components = URLComponents(string: "batteryhog://native" + path)
        let route = components?.path ?? path
        let query = components?.queryItems ?? []
        let queue = normalizedMethod == "POST"
            && ["/api/settings", "/api/ignore"].contains(route) ? mutationQueue : workQueue
        queue.async { [weak self] in
            guard let self else {
                completion(BackendResponse(status: 503, body: ["error": "backend unavailable"]))
                return
            }
            let response: BackendResponse
            var shouldRefreshSlowData = false
            switch (normalizedMethod, route) {
            case ("GET", "/api/stats"):
                response = BackendResponse(status: 200, body: self.buildStats())
                shouldRefreshSlowData = true
            case ("GET", "/api/history"):
                let range = query.first(where: { $0.name == "range" })?.value
                let cached = self.slowStore.historySnapshot()
                let age = Date().timeIntervalSince1970 - cached.savedAt
                let needsHistoryRefresh = !cached.available || cached.savedAt <= 0
                    || age > 30 * 60 || age < -300
                self.startSlowRefresh(force: needsHistoryRefresh)
                response = BackendResponse(status: 200,
                                           body: self.history(days: range == "10d" ? 10 : 1))
            case ("GET", "/api/settings"):
                response = BackendResponse(status: 200, body: self.settingsStore.snapshot())
            case ("POST", "/api/settings"):
                let result = self.settingsStore.updatePersisting(body)
                response = BackendResponse(status: result.persisted ? 200 : 500,
                    body: ["ok": result.persisted, "settings": result.value,
                           "message": result.persisted ? "Saved." : "Couldn't save settings."])
                self.invalidateStatsCache()
            case ("POST", "/api/ignore"):
                let reset = body["reset"] as? Bool ?? false
                let name = body["name"] as? String
                let enabled = body["on"] as? Bool
                let result = self.ignoredStore.updatePersisting(name: name, enabled: enabled,
                                                                 reset: reset)
                response = BackendResponse(status: result.persisted ? 200 : 500,
                    body: ["ok": result.persisted, "ignored": result.value,
                           "message": result.persisted ? "Saved." : "Couldn't save ignored apps."])
                self.invalidateStatsCache()
            case ("POST", "/api/kill"):
                response = BackendResponse(status: 200, body: self.quitAction(body))
                self.invalidateProcessCache()
            case ("POST", "/api/lowpower"):
                guard let enabled = body["on"] as? Bool else {
                    response = BackendResponse(status: 400,
                                               body: ["ok": false, "message": "Invalid setting."])
                    break
                }
                response = BackendResponse(status: 200, body: self.setLowPower(enabled))
                self.invalidateStatsCache()
            case ("POST", "/api/energy"):
                response = BackendResponse(status: 200, body: self.energySample())
            default:
                response = BackendResponse(status: 404, body: ["error": "not found"])
            }
            completion(response)
            if shouldRefreshSlowData { self.startSlowRefresh() }
        }
    }

    func stats(completion: @escaping ([String: Any]) -> Void) {
        workQueue.async { [weak self] in
            guard let self else { return }
            completion(self.buildStats())
            self.startSlowRefresh()
        }
    }

    func post(path: String, body: [String: Any], completion: (() -> Void)? = nil) {
        request(method: "POST", path: path, body: body) { _ in completion?() }
    }

    private func buildStats() -> [String: Any] {
        statsBuildLock.withLock {
            if let date = statsCacheDate, let cache = statsCache,
               Date().timeIntervalSince(date) < 4.5 {
                return JSONValue.bridgeSafe(cache) as? [String: Any] ?? cache
            }

            let valuesLock = NSLock()
            var values: [String: Any] = [:]
            let group = DispatchGroup()
            func collect(_ key: String, _ operation: @escaping () -> Any) {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let value = operation()
                    valuesLock.withLock { values[key] = value }
                    group.leave()
                }
            }

            collect("process", getProcessData)
            collect("battery", battery)
            collect("memory", memory)
            collect("sleep", sleepData)
            collect("lowpower", lowPowerMode)
            collect("health", batteryHealth)
            collect("power", power)
            collect("uptime", uptime)
            collect("gate", gateSnapshot)
            group.wait()

            let process = values["process"] as? [String: Any] ?? [:]
            let sleep = values["sleep"] as? [String: Any] ?? [:]
            let slow = slowStore.statsSnapshot()
            let result: [String: Any] = [
                "battery": values["battery"] ?? [:],
                "memory": values["memory"] ?? [:],
                "processes": process["processes"] ?? [[String: Any]](),
                "workloads": process["workloads"] ?? [[String: Any]](),
                "dev_summary": process["summary"] ?? [String: Any](),
                "sleep_blockers": sleep["blockers"] ?? [[String: Any]](),
                "power_policy": sleep["policy"] ?? [String: Any](),
                "gate": values["gate"] ?? [String: Any](),
                "lowpower": values["lowpower"] ?? NSNull(),
                "health": values["health"] ?? [String: Any](),
                "power": values["power"] ?? [String: Any](),
                "uptime": values["uptime"] ?? NSNull(),
                "wakes": slow["wakes"] ?? 0,
                "insights": slow["insights"] ?? SlowInsightsStore.emptyInsights,
                "insights_loading": slow["insights_loading"] ?? true,
                "insights_refreshing": slow["insights_refreshing"] ?? true,
                "insights_stale": slow["insights_stale"] ?? false,
                "ignored": ignoredStore.snapshot(),
                "settings": settingsStore.snapshot(),
                "preview": configuration.preview,
                "ncpu": cpuCount,
                "ts": Int(Date().timeIntervalSince1970)
            ]
            statsCache = result
            statsCacheDate = Date()
            return JSONValue.bridgeSafe(result) as? [String: Any] ?? result
        }
    }

    private func invalidateStatsCache() {
        statsBuildLock.withLock { statsCacheDate = nil; statsCache = nil }
    }

    private func invalidateProcessCache() {
        processLock.withLock { processCache.date = nil }
        invalidateStatsCache()
    }

    // MARK: Process sampling and estimated impact

    private func getProcessData() -> [String: Any] {
        processLock.withLock {
            if let date = processCache.date, Date().timeIntervalSince(date) < 6 {
                return ["processes": processCache.processes,
                        "workloads": processCache.workloads,
                        "summary": processCache.summary]
            }
            let first = rawProcessSnapshot()
            let started = Date()
            Thread.sleep(forTimeInterval: 0.8)
            let second = rawProcessSnapshot()
            let elapsed = max(0.2, Date().timeIntervalSince(started))
            var groups: [String: [String: Any]] = [:]
            var samples: [ProcessSample] = []

            for (pid, current) in second {
                let earlier = first[pid]?.cpuTime ?? current.cpuTime
                let cpu = max(0, current.cpuTime - earlier) / elapsed * 100
                samples.append(ProcessSample(pid: pid, ppid: current.ppid, rssKB: current.rssKB,
                                             cpu: cpu, command: current.command))
                let identity = classifyProcess(current.command)
                let groupKey = identity.name + "\u{0}" + identity.path
                if groups[groupKey] == nil {
                    groups[groupKey] = [
                        "name": identity.name, "bundle": identity.bundle,
                        "path": identity.path, "cpu": 0.0, "mem_kb": 0,
                        "pids": [Int](),
                        "protected": isProtected(name: identity.name, path: identity.path,
                                                   command: current.command)
                    ]
                }
                groups[groupKey]!["cpu"] = (groups[groupKey]!["cpu"] as? Double ?? 0) + cpu
                groups[groupKey]!["mem_kb"] = (groups[groupKey]!["mem_kb"] as? Int ?? 0) + current.rssKB
                var pids = groups[groupKey]!["pids"] as? [Int] ?? []
                pids.append(Int(pid))
                groups[groupKey]!["pids"] = pids
            }

            var processes: [[String: Any]] = groups.values.map { group in
                let cpu = rounded(group["cpu"] as? Double ?? 0)
                let memoryMB = rounded(Double(group["mem_kb"] as? Int ?? 0) / 1024)
                let score = rounded(cpu + memoryMB / 50)
                let level = (cpu >= 50 || score >= 80) ? "high"
                    : ((cpu >= 12 || score >= 25) ? "med" : "low")
                let pids = group["pids"] as? [Int] ?? []
                return [
                    "name": group["name"] ?? "?", "cpu": cpu, "mem_mb": memoryMB,
                    "procs": pids.count, "pids": Array(pids.prefix(50)),
                    "bundle": group["bundle"] ?? false,
                    "protected": group["protected"] ?? true,
                    "path": group["path"] ?? "", "level": level, "score": score
                ]
            }
            processes.sort { ($0["score"] as? Double ?? 0) > ($1["score"] as? Double ?? 0) }
            processes = Array(processes.prefix(40))
            let dev = workloadDetector.discover(samples)
            let workloads = dev["workloads"] as? [[String: Any]] ?? []
            let summary = dev["summary"] as? [String: Any] ?? [:]
            processCache = ProcessDataCache(date: Date(), processes: processes,
                                            workloads: workloads, summary: summary)
            return ["processes": processes, "workloads": workloads, "summary": summary]
        }
    }

    private func rawProcessSnapshot() -> [Int32: RawProcess] {
        let output = SystemCommand.output("/bin/ps",
            ["-axo", "pid=,ppid=,rss=,time=,command="], timeout: 8)
        var result: [Int32: RawProcess] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(maxSplits: 4, omittingEmptySubsequences: true,
                                   whereSeparator: { $0.isWhitespace })
            guard parts.count >= 4,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let rss = Int(parts[2]) else { continue }
            let command = parts.count >= 5 ? String(parts[4]) : ""
            result[pid] = RawProcess(pid: pid, ppid: ppid, rssKB: rss,
                                     cpuTime: parseCPUTime(String(parts[3])), command: command)
        }
        return result
    }

    private func parseCPUTime(_ raw: String) -> Double {
        var text = raw
        var days = 0
        if let dash = text.firstIndex(of: "-") {
            days = Int(text[..<dash]) ?? 0
            text = String(text[text.index(after: dash)...])
        }
        var seconds = 0.0
        for part in text.split(separator: ":") {
            guard let value = Double(part) else { return 0 }
            seconds = seconds * 60 + value
        }
        return Double(days * 86_400) + seconds
    }

    private func classifyProcess(_ command: String) -> (name: String, bundle: Bool, path: String) {
        if let match = regexMatches(#"/([^/]+)\.app/"#, in: command).first, match.count >= 2,
           let marker = command.range(of: ".app/") {
            return (match[1], true, String(command[..<marker.lowerBound]) + ".app")
        }
        let first = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        let name = first.contains("/") ? URL(fileURLWithPath: first).lastPathComponent : first
        return (name.isEmpty ? "?" : name, false, first)
    }

    private func isProtected(name: String, path: String, command: String) -> Bool {
        let lowCommand = command.lowercased()
        if lowCommand.contains("batteryhog") || lowCommand.contains("battery_hog") {
            return true
        }
        if Self.criticalNames.contains(name) { return true }
        let low = path.lowercased()
        if low.contains("sentinel") || name.lowercased().contains("sentinel") { return true }
        if path.hasPrefix("/System/Applications/") { return false }
        if path.hasPrefix("/System/") { return true }
        if path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") { return true }
        if path.hasPrefix("/Library/") || path.hasPrefix("/private/") { return true }
        return false
    }

    // MARK: Battery, memory, health, power and sleep providers

    private func battery() -> [String: Any] {
        let output = SystemCommand.output("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
        let percent = regexFirst(#"(\d+)%"#, in: output).flatMap(Int.init)
        let remaining = regexFirst(#"(\d+:\d+)\s+remaining"#, in: output)
        let onAC = output.contains("AC Power")
        let low = output.lowercased()
        let status = regexFirst(#"\d+%;\s*([^;]+)"#, in: low)?.trimmingCharacters(in: .whitespaces)
            ?? ""
        let state: String
        if !onAC { state = "discharging" }
        else if status.contains("discharging") { state = "discharging" }
        else if status.contains("charged") || low.contains("finishing charge") { state = "charged" }
        else if low.contains("not charging") { state = "ac" }
        else if status.contains("charging") { state = "charging" }
        else { state = "ac" }
        return ["percent": jsonOptional(percent), "state": state, "on_ac": onAC,
                "time": jsonOptional(remaining)]
    }

    private func memory() -> [String: Any] {
        let vm = SystemCommand.output("/usr/bin/vm_stat", timeout: 5)
        func pages(_ label: String) -> UInt64 {
            UInt64(regexFirst(NSRegularExpression.escapedPattern(for: label) + #":\s+(\d+)\."#,
                              in: vm) ?? "") ?? 0
        }
        let freePages = pages("Pages free") + pages("Pages speculative")
        let compressedPages = pages("Pages occupied by compressor")
        let wiredPages = pages("Pages wired down")
        let freeBytes = freePages * UInt64(pageSize)
        let compressedBytes = compressedPages * UInt64(pageSize)
        let wiredBytes = wiredPages * UInt64(pageSize)
        let usedBytes = totalMemory > freeBytes ? totalMemory - freeBytes : 0
        let swapOutput = SystemCommand.output("/usr/sbin/sysctl", ["vm.swapusage"], timeout: 4)
        let swap = Double(regexFirst(#"used = ([\d.]+)M"#, in: swapOutput) ?? "") ?? 0
        let freeMB = Double(freeBytes) / 1_048_576
        let pressure = (freeMB < 1500 || swap > 1024) ? "high"
            : ((freeMB < 4000 || swap > 256) ? "elevated" : "normal")
        let gb = 1_073_741_824.0
        return [
            "total_gb": rounded(Double(totalMemory) / gb),
            "used_gb": rounded(Double(usedBytes) / gb),
            "free_gb": rounded(Double(freeBytes) / gb, places: 2),
            "compressed_gb": rounded(Double(compressedBytes) / gb),
            "wired_gb": rounded(Double(wiredBytes) / gb),
            "swap_used_mb": Int(swap.rounded()), "pressure": pressure
        ]
    }

    private func lowPowerMode() -> Any {
        let output = SystemCommand.output("/usr/bin/pmset", ["-g"], timeout: 5)
        guard let raw = regexFirst(#"lowpowermode\s+(\d+)"#, in: output) else { return NSNull() }
        return raw == "1"
    }

    private func batteryIORegistry() -> String {
        batteryIOLock.withLock {
            if let date = batteryIODate, let cache = batteryIOCache,
               Date().timeIntervalSince(date) < 4 { return cache }
            let output = SystemCommand.output("/usr/sbin/ioreg",
                                               ["-rn", "AppleSmartBattery"], timeout: 6)
            batteryIODate = Date()
            batteryIOCache = output
            return output
        }
    }

    private func ioInteger(_ key: String, in text: String) -> Int64? {
        guard let raw = regexFirst(#"\""# + NSRegularExpression.escapedPattern(for: key)
            + #"\"\s*=\s*(-?\d+)"#, in: text) else { return nil }
        if let signed = Int64(raw) { return signed }
        if let unsigned = UInt64(raw) { return Int64(bitPattern: unsigned) }
        return nil
    }

    private func ioBoolean(_ key: String, in text: String) -> Bool? {
        guard let raw = regexFirst(#"\""# + NSRegularExpression.escapedPattern(for: key)
            + #"\"\s*=\s*(Yes|No|true|false)"#, in: text, options: [.caseInsensitive]) else {
            return nil
        }
        return ["yes", "true"].contains(raw.lowercased())
    }

    private func batteryHealth() -> [String: Any] {
        if let cache = healthLock.withLock({ () -> [String: Any]? in
            guard let date = healthDate, let cache = healthCache,
                  Date().timeIntervalSince(date) < 45 else { return nil }
            return cache
        }) { return cache }

        let io = batteryIORegistry()
        let design = ioInteger("DesignCapacity", in: io)
        let full = ioInteger("NominalChargeCapacity", in: io)
            ?? ioInteger("AppleRawMaxCapacity", in: io)
        let temperature = ioInteger("Temperature", in: io).map { rounded(Double($0) / 100) }
        let cycles = ioInteger("CycleCount", in: io)
        let health: Int?
        if let full, let design, design > 0 { health = Int((Double(full) / Double(design) * 100).rounded()) }
        else { health = nil }
        let provisional: [String: Any] = [
            "health": jsonOptional(health), "cycles": jsonOptional(cycles.map(Int.init)),
            "condition": NSNull(), "temp_c": jsonOptional(temperature),
            "design_mah": jsonOptional(design.map(Int.init)),
            "full_mah": jsonOptional(full.map(Int.init))
        ]
        let shouldRefresh = healthLock.withLock { () -> Bool in
            healthCache = provisional
            healthDate = Date()
            if healthRefreshRunning { return false }
            healthRefreshRunning = true
            return true
        }
        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.enrichBatteryHealth(io: io) }
        }
        return provisional
    }

    private func enrichBatteryHealth(io: String) {
        let profiler = SystemCommand.output("/usr/sbin/system_profiler", ["SPPowerDataType"], timeout: 20)
        let maxCapacity = regexFirst(#"Maximum Capacity:\s*(\d+)%"#, in: profiler).flatMap(Int.init)
        let condition = regexFirst(#"Condition:\s*([^\n]+)"#, in: profiler)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profileCycles = regexFirst(#"Cycle Count:\s*(\d+)"#, in: profiler).flatMap(Int.init)
        healthLock.withLock {
            var cache = healthCache ?? [:]
            if let maxCapacity { cache["health"] = maxCapacity }
            if let condition { cache["condition"] = condition }
            if let profileCycles { cache["cycles"] = profileCycles }
            healthCache = cache
            healthDate = Date()
            healthRefreshRunning = false
        }
        invalidateStatsCache()
    }

    private func power() -> [String: Any] {
        let io = batteryIORegistry()
        let amperage = ioInteger("InstantAmperage", in: io) ?? ioInteger("Amperage", in: io)
        let voltage = ioInteger("Voltage", in: io)
        let charging = ioBoolean("IsCharging", in: io) ?? false
        let onAC = ioBoolean("ExternalConnected", in: io) ?? false
        let watts: Double?
        if let amperage, let voltage {
            watts = rounded(abs(Double(amperage)) * Double(voltage) / 1_000_000)
        } else { watts = nil }
        let direction = charging ? "charging" : (onAC ? "ac" : "discharging")
        return ["watts": jsonOptional(watts), "direction": direction,
                "charging": charging, "on_ac": onAC]
    }

    private func uptime() -> Any {
        let output = SystemCommand.output("/usr/sbin/sysctl", ["-n", "kern.boottime"], timeout: 4)
        guard let raw = regexFirst(#"sec\s*=\s*(\d+)"#, in: output), let boot = Int(raw) else {
            return NSNull()
        }
        let seconds = max(0, Int(Date().timeIntervalSince1970) - boot)
        return ["secs": seconds, "days": rounded(Double(seconds) / 86_400)] as [String: Any]
    }

    private func sleepData() -> [String: Any] {
        sleepLock.withLock {
            if let date = sleepDate, let cache = sleepCache,
               Date().timeIntervalSince(date) < 12 { return cache }
            let blockers = WorkloadDetector.parseSleepAssertions(
                SystemCommand.output("/usr/bin/pmset", ["-g", "assertions"], timeout: 6)
            )
            let custom = SystemCommand.output("/usr/bin/pmset", ["-g", "custom"], timeout: 6)
            var batterySection = custom
            if let range = batterySection.range(of: "Battery Power:") {
                batterySection = String(batterySection[range.upperBound...])
            }
            if let range = batterySection.range(of: "AC Power:") {
                batterySection = String(batterySection[..<range.lowerBound])
            }
            func setting(_ name: String) -> Any {
                let pattern = #"(?m)^\s*"# + NSRegularExpression.escapedPattern(for: name)
                    + #"\s+(\d+)\s*$"#
                return jsonOptional(regexFirst(pattern, in: batterySection).flatMap(Int.init))
            }
            let policy: [String: Any] = [
                "display_sleep": setting("displaysleep"),
                "system_sleep": setting("sleep"),
                "powernap": setting("powernap"),
                "tcpkeepalive": setting("tcpkeepalive")
            ]
            let value: [String: Any] = ["blockers": blockers, "policy": policy]
            sleepCache = value
            sleepDate = Date()
            return value
        }
    }

    private func gateSnapshot() -> [String: Any] {
        var result = gateStore.snapshot()
        let settings = settingsStore.snapshot()["dev"] as? [String: Any] ?? [:]
        let command = "BATTERY_HOG_DATA_DIR="
            + SystemCommand.shellQuote(configuration.dataDirectory.path) + " "
            + SystemCommand.shellQuote(configuration.gateExecutable.path) + " --"
        result["command"] = command
        result["enabled"] = settings["enabled"] as? Bool ?? false
        result["slots"] = (settings["slots"] as? NSNumber)?.intValue ?? 2
        result["workers"] = (settings["workers"] as? NSNumber)?.intValue ?? 2
        return result
    }

    private static func sysctlInt(_ name: String, fallback: Int) -> Int {
        Int(SystemCommand.output("/usr/sbin/sysctl", ["-n", name], timeout: 4)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }

    private static func sysctlUInt64(_ name: String, fallback: UInt64) -> UInt64 {
        UInt64(SystemCommand.output("/usr/sbin/sysctl", ["-n", name], timeout: 4)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }

    // MARK: Power-log history and deferred insights

    private static func powerLogDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }

    private static func powerLogDate(_ date: String, zone: String,
                                     formatter: DateFormatter) -> Date? {
        formatter.date(from: date + " " + zone)
    }

    private static func parsePowerLog(_ text: String, now: Date = Date()) -> ParsedPowerLog {
        let datePattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([+-]\d{4})"#
        let rowPattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+([+-]\d{4}).*?Using\s+(AC|Batt|BATT)\s*\(Charge:\s*(\d+)"#
        guard let dateRegex = try? NSRegularExpression(pattern: datePattern),
              let rowRegex = try? NSRegularExpression(pattern: rowPattern) else {
            return ParsedPowerLog(rows: [], wakeDates: [])
        }
        let retentionCutoff = now.addingTimeInterval(-11 * 86_400)
        let futureLimit = now.addingTimeInterval(300)
        var wakeDates: [Date] = []
        var rows: [HistoryRow] = []
        let formatter = Self.powerLogDateFormatter()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.contains("DarkWake"),
               let match = regexMatches(dateRegex, in: line).first, match.count >= 3,
               let date = Self.powerLogDate(match[1], zone: match[2], formatter: formatter),
               date >= retentionCutoff, date <= futureLimit {
                wakeDates.append(date)
            }
            if line.contains("Using"), line.contains("Charge:"),
               let match = regexMatches(rowRegex, in: line).first, match.count >= 5,
               let date = Self.powerLogDate(match[1], zone: match[2], formatter: formatter),
               date >= retentionCutoff, date <= futureLimit,
               let percent = Int(match[4]), (0...100).contains(percent) {
                rows.append(HistoryRow(date: date, percent: percent,
                                       onAC: match[3].uppercased() == "AC"))
            }
        }
        rows.sort { $0.date < $1.date }
        wakeDates.sort()
        return ParsedPowerLog(rows: rows, wakeDates: wakeDates)
    }

    private func history(days: Int) -> [String: Any] {
        let now = Date()
        let binSeconds = days <= 1 ? 900 : 10_800
        let start = now.addingTimeInterval(-Double(days * 86_400))
        let count = Int((Double(days * 86_400) / Double(binSeconds)).rounded())
        let snapshot = slowStore.historySnapshot()
        var rows = snapshot.rows.map {
            HistoryRow(date: Date(timeIntervalSince1970: $0.timestamp),
                       percent: $0.percent, onAC: $0.onAC)
        }
        if snapshot.available {
            let battery = battery()
            if let percent = battery["percent"] as? NSNumber {
                rows.append(HistoryRow(date: now, percent: percent.intValue,
                                       onAC: battery["on_ac"] as? Bool ?? false))
            }
        }

        struct Cell {
            var low: Int
            var high: Int
            var onAC: Bool
            var last: Date
            var value: Int
        }
        var rawBins = Array<Cell?>(repeating: nil, count: count)
        for row in rows where row.date >= start && row.date <= now {
            var index = Int(row.date.timeIntervalSince(start) / Double(binSeconds))
            if index < 0 { continue }
            if index >= count { index = count - 1 }
            if let existing = rawBins[index] {
                var cell = existing
                cell.low = min(cell.low, row.percent)
                cell.high = max(cell.high, row.percent)
                if row.date >= cell.last {
                    cell.last = row.date
                    cell.onAC = row.onAC
                    cell.value = row.percent
                }
                rawBins[index] = cell
            } else {
                rawBins[index] = Cell(low: row.percent, high: row.percent, onAC: row.onAC,
                                      last: row.date, value: row.percent)
            }
        }

        var output: [Any] = []
        var previous: [String: Any]?
        for cell in rawBins {
            if let cell {
                let value: [String: Any] = ["lo": cell.low, "hi": cell.high,
                                            "ac": cell.onAC, "v": cell.value]
                output.append(value)
                previous = value
            } else if let previous {
                output.append(previous)
            } else {
                output.append(NSNull())
            }
        }
        let full = rows.filter { $0.percent >= 100 }.last?.date
        let spanDays = rows.count >= 2
            ? rounded(rows.last!.date.timeIntervalSince(rows.first!.date) / 86_400) : 0
        let cacheAge = now.timeIntervalSince1970 - snapshot.savedAt
        return [
            "range": days <= 1 ? "24h" : "10d", "bins": output,
            "bin_sec": binSeconds, "start": Int(start.timeIntervalSince1970),
            "end": Int(now.timeIntervalSince1970), "last_full": jsonOptional(full.map {
                Int($0.timeIntervalSince1970)
            }), "span_days": spanDays,
            "loading": !snapshot.available,
            "refreshing": snapshot.refreshing,
            "stale": snapshot.available && (cacheAge > 30 * 60 || cacheAge < -300)
        ]
    }

    private static func insights(rows: [HistoryRow], wakes: Int, now: Date = Date())
        -> [String: Any] {
        func analyze(since: Date) -> [String: Any] {
            let segment = rows.filter { $0.date >= since }
            var onBattery = 0.0
            var charging = 0.0
            var discharging = 0.0
            var drop = 0.0
            if segment.count >= 2 {
                for index in 0..<(segment.count - 1) {
                    let first = segment[index]
                    let second = segment[index + 1]
                    let duration = second.date.timeIntervalSince(first.date)
                    if duration <= 0 || duration > 7200 { continue }
                    if !first.onAC {
                        onBattery += duration
                        if second.percent < first.percent {
                            drop += Double(first.percent - second.percent)
                            discharging += duration
                        }
                    } else { charging += duration }
                }
            }
            let rate = discharging >= 600 ? drop / (discharging / 3600) : nil
            return [
                "rate": jsonOptional(rate.map { rounded($0) }),
                "runtime_h": jsonOptional(rate.flatMap { $0 > 0 ? rounded(100 / $0) : nil }),
                "on_battery_h": rounded(onBattery / 3600),
                "charging_h": rounded(charging / 3600)
            ]
        }
        let today = analyze(since: now.addingTimeInterval(-86_400))
        let week = analyze(since: now.addingTimeInterval(-7 * 86_400))
        var charges = 0
        var previousAC: Bool?
        for row in rows where row.date >= now.addingTimeInterval(-86_400) {
            if row.onAC && previousAC == false { charges += 1 }
            previousAC = row.onAC
        }
        let result: [String: Any] = [
            "today": today, "week": week, "charges": charges,
            "wakes": wakes, "ok": !(today["rate"] is NSNull)
        ]
        return result
    }

    private func startSlowRefresh(force: Bool = false) {
        guard slowStore.beginRefresh(force: force) else { return }
        slowQueue.async { [weak self] in
            guard let self else { return }
            // This is the only full power-log scan in the app. It is single-flight,
            // runs off the request path, and its parsed result is reused on later launches.
            let result = SystemCommand.run(
                "/usr/bin/pmset", ["-g", "log"], timeout: 20,
                stdoutLineFilter: { line in
                    line.contains("DarkWake")
                        || (line.contains("Using") && line.contains("Charge:"))
                }
            )
            guard result.succeeded && !result.stdout.isEmpty else {
                self.slowStore.failRefresh()
                self.invalidateStatsCache()
                return
            }
            let now = Date()
            let parsed = Self.parsePowerLog(result.stdout, now: now)
            let rows = Array(parsed.rows.suffix(20_000))
            let wakeDates = Array(parsed.wakeDates.suffix(50_000))
            let wakes14 = wakeDates.filter { $0 >= now.addingTimeInterval(-14 * 3600) }.count
            let wakes24 = wakeDates.filter { $0 >= now.addingTimeInterval(-24 * 3600) }.count
            let insights = Self.insights(rows: rows, wakes: wakes24, now: now)
            _ = self.slowStore.finish(
                wakes: wakes14,
                insights: insights,
                historyRows: rows.map {
                    SlowHistoryRow(timestamp: $0.date.timeIntervalSince1970,
                                   percent: $0.percent, onAC: $0.onAC)
                },
                wakeDates: wakeDates.map(\.timeIntervalSince1970)
            )
            self.invalidateStatsCache()
        }
    }

#if BATTERY_HOG_TESTING
    static func powerLogSummaryForTesting(_ text: String, now: Date) -> [String: Any] {
        let parsed = parsePowerLog(text, now: now)
        let wakes14 = parsed.wakeDates.filter { $0 >= now.addingTimeInterval(-14 * 3600) }.count
        let wakes24 = parsed.wakeDates.filter { $0 >= now.addingTimeInterval(-24 * 3600) }.count
        return ["rows": parsed.rows.count, "wakes14": wakes14, "wakes24": wakes24]
    }
#endif

    // MARK: Privileged and process actions

    private func quitAction(_ body: [String: Any]) -> [String: Any] {
        guard let name = body["name"] as? String,
              !name.isEmpty, name.count <= 160,
              let requestedPath = body["path"] as? String,
              !requestedPath.isEmpty, requestedPath.count <= 1_024,
              !Self.criticalNames.contains(name),
              !name.lowercased().contains("batteryhog"),
              let requested = body["pids"] as? [Any] else {
            return ["ok": false, "message": "That process is protected."]
        }
        let requestedPIDs = Set(requested.compactMap { value -> Int32? in
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let pid = number.int64Value
            guard pid > 1, pid <= Int64(Int32.max), pid != Int64(getpid()) else { return nil }
            return Int32(pid)
        }.prefix(50))
        guard !requestedPIDs.isEmpty else {
            return ["ok": false, "message": "Nothing to quit."]
        }

        // The dashboard is a view, not an authority. Only accept positive PIDs
        // that Battery Hog itself published for this exact process group.
        let processData = getProcessData()
        guard let advertised = (processData["processes"] as? [[String: Any]])?
            .first(where: {
                $0["name"] as? String == name && $0["path"] as? String == requestedPath
            }),
              advertised["protected"] as? Bool != true else {
            return ["ok": false, "message": "That process is protected."]
        }
        let advertisedPIDs = Set((advertised["pids"] as? [Int] ?? []).compactMap(Int32.init))
        let candidates = requestedPIDs.intersection(advertisedPIDs)
        guard !candidates.isEmpty else {
            return ["ok": false, "message": "That process sample is no longer current."]
        }
        let advertisedPath = advertised["path"] as? String ?? ""
        let validated = validateCurrentPIDs(candidates, expectedName: name,
                                            expectedPath: advertisedPath)
        guard !validated.isEmpty else {
            return ["ok": false, "message": "That process is no longer running."]
        }
        let isBundle = advertised["bundle"] as? Bool ?? false
        let result = quitTarget(name: name, path: advertisedPath,
                                bundle: isBundle, targets: validated)
        return ["ok": result.0, "message": result.1]
    }

    private func validateCurrentPIDs(_ pids: Set<Int32>, expectedName: String,
                                     expectedPath: String) -> [ValidatedProcessTarget] {
        guard !pids.isEmpty else { return [] }
        let list = pids.sorted().map(String.init).joined(separator: ",")
        let output = SystemCommand.output("/bin/ps",
            ["-o", "pid=,uid=,lstart=,command=", "-p", list], timeout: 6)
        let ownUID = Int(getuid())
        var result: [ValidatedProcessTarget] = []
        for raw in output.split(separator: "\n") {
            let parts = raw.split(maxSplits: 7, omittingEmptySubsequences: true,
                                  whereSeparator: { $0.isWhitespace })
            guard parts.count >= 8, let pid = Int32(parts[0]), let uid = Int(parts[1]),
                  pids.contains(pid), pid > 1, uid == ownUID else { continue }
            let command = String(parts[7])
            let identity = classifyProcess(command)
            if identity.name == expectedName,
               identity.path == expectedPath,
               !isProtected(name: identity.name, path: identity.path, command: command) {
                let started = parts[2...6].map(String.init).joined(separator: " ")
                result.append(ValidatedProcessTarget(pid: pid,
                                                      identity: started + "|" + command))
            }
        }
        return result
    }

    private func revalidate(_ targets: [ValidatedProcessTarget], expectedName: String,
                            expectedPath: String) -> [ValidatedProcessTarget] {
        let fresh = validateCurrentPIDs(Set(targets.map(\.pid)), expectedName: expectedName,
                                        expectedPath: expectedPath)
        let identities = Dictionary(uniqueKeysWithValues: fresh.map { ($0.pid, $0.identity) })
        return targets.filter { identities[$0.pid] == $0.identity }
    }

    private func alivePIDs(_ pids: [Int32]) -> [Int32] {
        pids.filter { pid in
            guard pid > 1 else { return false }
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }
    }

    private func quitTarget(name: String, path: String, bundle: Bool,
                            targets: [ValidatedProcessTarget]) -> (Bool, String) {
        if bundle {
            let current = revalidate(targets, expectedName: name, expectedPath: path)
            for target in current {
                guard let application = NSRunningApplication(processIdentifier: target.pid),
                      application.bundleURL?.standardizedFileURL.path == path else { continue }
                application.terminate()
            }
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline && !alivePIDs(targets.map(\.pid)).isEmpty {
                Thread.sleep(forTimeInterval: 0.15)
            }
            if revalidate(targets, expectedName: name, expectedPath: path).isEmpty {
                return (true, "Quit \(name).")
            }
        }
        let termTargets = revalidate(targets, expectedName: name, expectedPath: path)
        for target in termTargets { Darwin.kill(target.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(1.8)
        while Date() < deadline && !alivePIDs(termTargets.map(\.pid)).isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
        }
        let survivors = revalidate(termTargets, expectedName: name, expectedPath: path)
        for target in survivors { Darwin.kill(target.pid, SIGKILL) }
        if !survivors.isEmpty { Thread.sleep(forTimeInterval: 0.25) }
        let stillRunning = revalidate(survivors, expectedName: name, expectedPath: path)
        if !stillRunning.isEmpty {
            return (false, "Couldn't fully quit \(name) (\(stillRunning.count) still running).")
        }
        return (true, "Quit \(name).")
    }

    private func setLowPower(_ enabled: Bool) -> [String: Any] {
        let value = enabled ? "1" : "0"
        let result = SystemCommand.runPrivileged("/usr/bin/pmset",
                                                  ["-a", "lowpowermode", value])
        if result.0 {
            return ["ok": true, "message": "Low Power Mode turned \(enabled ? "on" : "off").",
                    "on": enabled]
        }
        return ["ok": false, "message": result.2, "on": NSNull()]
    }

    private func energySample() -> [String: Any] {
        let result = SystemCommand.runPrivileged(
            "/usr/bin/powermetrics", ["--samplers", "tasks,cpu_power", "-n1", "-i500"],
            timeout: 45
        )
        guard result.0 else { return ["ok": false, "message": result.2] }
        return parsePowerMetrics(result.1)
    }

    private func parsePowerMetrics(_ text: String) -> [String: Any] {
        let patterns = [
            ("CPU Power", "cpu"), ("GPU Power", "gpu"), ("ANE Power", "ane"),
            (#"Combined Power \(CPU \+ GPU \+ ANE\)"#, "combined"),
            ("Package Power", "package")
        ]
        var system: [String: Any] = [:]
        for (pattern, key) in patterns {
            if let raw = regexFirst(pattern + #":\s*([\d.]+)\s*mW"#, in: text),
               let value = Double(raw) { system[key] = rounded(value / 1000, places: 2) }
        }
        var tasks: [[String: Any]] = []
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains("Energy Impact") && line.contains("ID") {
                inTable = true
                continue
            }
            if !inTable { continue }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let pidIndex = tokens.firstIndex(where: { Int($0) != nil }), pidIndex >= 1,
                  let pid = Int(tokens[pidIndex]), let energy = tokens.last.flatMap(Double.init) else { continue }
            let name = tokens[..<pidIndex].joined(separator: " ")
            if name.uppercased().hasPrefix("ALL_TASKS") { continue }
            tasks.append(["name": name, "pid": pid, "energy": rounded(energy)])
        }
        tasks.sort { ($0["energy"] as? Double ?? 0) > ($1["energy"] as? Double ?? 0) }
        tasks = Array(tasks.prefix(20))
        if tasks.isEmpty && system.isEmpty {
            return ["ok": false, "message": "Could not parse powermetrics output."]
        }
        return ["ok": true, "system": system, "tasks": tasks]
    }

    // MARK: Opt-in usage alerts (Heat Watch remains in AppDelegate)

    private func startAlertTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.evaluateUsageAlerts() }
        timer.resume()
        alertTimer = timer
    }

    private func evaluateUsageAlerts() {
        let settings = settingsStore.snapshot()
        guard settings["alerts"] as? Bool == true else { return }
        let battery = battery()
        let percent = (battery["percent"] as? NSNumber)?.intValue
        let state = battery["state"] as? String ?? ""
        let threshold = (settings["low_threshold"] as? NSNumber)?.intValue ?? 20
        let onAC = battery["on_ac"] as? Bool ?? false
        let processData = getProcessData()
        let processes = processData["processes"] as? [[String: Any]] ?? []
        let dev = settings["dev"] as? [String: Any] ?? [:]
        let drawThreshold = (dev["draw_threshold"] as? NSNumber)?.intValue ?? 30
        let notifyDraw = dev["notify_draw"] as? Bool ?? true
        let power = power()
        let watts = (power["watts"] as? NSNumber)?.doubleValue ?? 0

        var notifications: [(String, String)] = []
        alertLock.withLock {
            if state == "discharging", let percent, percent <= threshold {
                if !lowAlerted {
                    notifications.append(("Battery low", "\(percent)% left — plug in soon."))
                    lowAlerted = true
                }
            } else if percent == nil || state != "discharging" || percent! > threshold + 5 {
                lowAlerted = false
            }

            if onAC, let percent, percent >= 100 {
                if !fullAlerted {
                    notifications.append(("Fully charged", "Unplug when you can to ease battery wear."))
                    fullAlerted = true
                }
            } else if !onAC || (percent != nil && percent! < 98) { fullAlerted = false }

            var hot = Set<String>()
            for process in processes.prefix(8) {
                guard process["protected"] as? Bool != true,
                      let name = process["name"] as? String,
                      let cpu = (process["cpu"] as? NSNumber)?.doubleValue, cpu >= 95 else { continue }
                hot.insert(name)
                if !hotProcesses.contains(name) {
                    notifications.append(("High CPU", "\(name) is using \(Int(cpu.rounded()))% CPU."))
                }
            }
            hotProcesses = hot

            if notifyDraw && !onAC && watts >= Double(drawThreshold) {
                highDrawHits += 1
                if highDrawHits >= 2 && !highDrawAlerted {
                    let summary = processData["summary"] as? [String: Any] ?? [:]
                    let active = (summary["active_workers"] as? NSNumber)?.intValue ?? 0
                    let projects = (summary["projects"] as? NSNumber)?.intValue ?? 0
                    notifications.append(("Heavy battery draw",
                        "\(Int(watts.rounded())) W with \(active) active dev workers across \(projects) projects."))
                    highDrawAlerted = true
                }
            } else {
                highDrawHits = 0
                highDrawAlerted = false
            }
        }
        for (title, message) in notifications { postNotification(title: title, message: message) }
    }

    private func postNotification(title: String, message: String) {
        let script = [
            "on run argv",
            "display notification (item 2 of argv) with title (item 1 of argv)",
            "end run"
        ]
        var arguments: [String] = []
        for line in script { arguments += ["-e", line] }
        arguments += [title, message]
        workQueue.async { _ = SystemCommand.run("/usr/bin/osascript", arguments, timeout: 5) }
    }
}
