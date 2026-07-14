import Foundation

struct BatteryHogConfiguration {
    let dataDirectory: URL
    let gateExecutable: URL
    let preview: Bool

    static func live(bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> BatteryHogConfiguration {
        let preview = bundle.bundleIdentifier?.hasSuffix(".preview") == true
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let defaultDirectory = support.appendingPathComponent(preview ? "BatteryHogPreview" : "BatteryHog",
                                                               isDirectory: true)
        let dataDirectory: URL
        if let custom = environment["BATTERY_HOG_DATA_DIR"], !custom.isEmpty {
            dataDirectory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            dataDirectory = defaultDirectory
        }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/batteryhog-gate")
        return BatteryHogConfiguration(dataDirectory: dataDirectory,
                                       gateExecutable: helper,
                                       preview: preview)
    }
}

final class BatteryHogSettingsStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var settings: [String: Any]

    static var defaults: [String: Any] {
        [
            "alerts": false,
            "low_threshold": 20,
            "menubar": ["percent": true, "watts": true, "time": false,
                        "hog": false, "dev": false],
            "dev": ["enabled": false, "slots": 2, "workers": 2,
                    "draw_threshold": 30, "notify_draw": true],
            "heat": ["enabled": false]
        ]
    }

    init(dataDirectory: URL) {
        fileURL = dataDirectory.appendingPathComponent("settings.json")
        settings = Self.validated(JSONValue.readObject(at: fileURL))
    }

    func snapshot() -> [String: Any] {
        lock.withLock { JSONValue.bridgeSafe(settings) as? [String: Any] ?? Self.defaults }
    }

    @discardableResult
    func update(_ patch: [String: Any]) -> [String: Any] {
        updatePersisting(patch).value
    }

    func updatePersisting(_ patch: [String: Any]) -> (value: [String: Any], persisted: Bool) {
        lock.withLock { () -> (value: [String: Any], persisted: Bool) in
            var candidate = settings
            if let alerts = patch["alerts"] as? Bool { candidate["alerts"] = alerts }
            if let threshold = Self.integer(patch["low_threshold"]) {
                candidate["low_threshold"] = min(95, max(5, threshold))
            }
            if let incoming = patch["menubar"] as? [String: Any] {
                var menu = candidate["menubar"] as? [String: Any] ?? [:]
                for key in ["percent", "watts", "time", "hog", "dev"] {
                    if let value = incoming[key] as? Bool { menu[key] = value }
                }
                candidate["menubar"] = menu
            }
            if let incoming = patch["dev"] as? [String: Any] {
                var dev = candidate["dev"] as? [String: Any] ?? [:]
                for key in ["enabled", "notify_draw"] {
                    if let value = incoming[key] as? Bool { dev[key] = value }
                }
                if let value = Self.integer(incoming["slots"]) {
                    dev["slots"] = min(4, max(1, value))
                }
                if let value = Self.integer(incoming["workers"]) {
                    dev["workers"] = min(8, max(1, value))
                }
                if let value = Self.integer(incoming["draw_threshold"]) {
                    dev["draw_threshold"] = min(80, max(10, value))
                }
                candidate["dev"] = dev
            }
            if let incoming = patch["heat"] as? [String: Any],
               let enabled = incoming["enabled"] as? Bool {
                var heat = candidate["heat"] as? [String: Any] ?? [:]
                heat["enabled"] = enabled
                candidate["heat"] = heat
            }
            let value = JSONValue.bridgeSafe(candidate) as? [String: Any] ?? Self.defaults
            do {
                try JSONValue.write(value, to: fileURL)
                settings = candidate
                return (value, true)
            } catch {
                let current = JSONValue.bridgeSafe(settings) as? [String: Any] ?? Self.defaults
                return (current, false)
            }
        }
    }

    private static func validated(_ raw: [String: Any]?) -> [String: Any] {
        var result = defaults
        guard let raw else { return result }
        if let value = raw["alerts"] as? Bool { result["alerts"] = value }
        if let value = integer(raw["low_threshold"]) {
            result["low_threshold"] = min(95, max(5, value))
        }
        if let rawMenu = raw["menubar"] as? [String: Any] {
            var menu = result["menubar"] as! [String: Any]
            for key in ["percent", "watts", "time", "hog", "dev"] {
                if let value = rawMenu[key] as? Bool { menu[key] = value }
            }
            result["menubar"] = menu
        }
        if let rawDev = raw["dev"] as? [String: Any] {
            var dev = result["dev"] as! [String: Any]
            for key in ["enabled", "notify_draw"] {
                if let value = rawDev[key] as? Bool { dev[key] = value }
            }
            if let value = integer(rawDev["slots"]) { dev["slots"] = min(4, max(1, value)) }
            if let value = integer(rawDev["workers"]) { dev["workers"] = min(8, max(1, value)) }
            if let value = integer(rawDev["draw_threshold"]) {
                dev["draw_threshold"] = min(80, max(10, value))
            }
            result["dev"] = dev
        }
        if let rawHeat = raw["heat"] as? [String: Any],
           let enabled = rawHeat["enabled"] as? Bool {
            result["heat"] = ["enabled": enabled]
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

final class IgnoredAppsStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var names: Set<String>

    init(dataDirectory: URL) {
        fileURL = dataDirectory.appendingPathComponent("ignored.json")
        names = Set((JSONValue.readArray(at: fileURL) ?? []).compactMap { $0 as? String })
    }

    func snapshot() -> [String] { lock.withLock { names.sorted() } }

    func update(name: String?, enabled: Bool?, reset: Bool) -> [String] {
        updatePersisting(name: name, enabled: enabled, reset: reset).value
    }

    func updatePersisting(name: String?, enabled: Bool?, reset: Bool)
        -> (value: [String], persisted: Bool) {
        lock.withLock { () -> (value: [String], persisted: Bool) in
            var candidate = names
            if reset {
                candidate.removeAll()
            } else if let name {
                let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
                if !clean.isEmpty {
                    if enabled == true { candidate.insert(clean) }
                    else { candidate.remove(clean) }
                }
            }
            let result = candidate.sorted()
            do {
                try JSONValue.write(result, to: fileURL)
                names = candidate
                return (result, true)
            } catch {
                return (names.sorted(), false)
            }
        }
    }
}

struct SlowHistoryRow {
    let timestamp: TimeInterval
    let percent: Int
    let onAC: Bool
}

struct SlowHistorySnapshot {
    let rows: [SlowHistoryRow]
    let wakeDates: [TimeInterval]
    let savedAt: TimeInterval
    let refreshing: Bool
    let available: Bool
}

final class SlowInsightsStore {
    private let lock = NSLock()
    private let fileURL: URL
    private var wakes = 0
    private var insights: [String: Any] = SlowInsightsStore.emptyInsights
    private var historyRows: [SlowHistoryRow] = []
    private var wakeDates: [TimeInterval] = []
    private var hasHistoryCache = false
    private var hasWakeHistory = false
    private var savedAt: TimeInterval = 0
    private var lastAttempt: TimeInterval = 0
    private var refreshing = false

    private static let automaticRefreshInterval: TimeInterval = 6 * 3600
    private static let retryInterval: TimeInterval = 5 * 60

    static var emptyInsights: [String: Any] {
        [
            "today": ["rate": NSNull(), "runtime_h": NSNull(),
                      "on_battery_h": 0.0, "charging_h": 0.0],
            "week": ["rate": NSNull(), "runtime_h": NSNull(),
                     "on_battery_h": 0.0, "charging_h": 0.0],
            "charges": 0, "wakes": 0, "ok": false
        ]
    }

    init(dataDirectory: URL) {
        fileURL = dataDirectory.appendingPathComponent("insights-cache.json")
        guard let cached = JSONValue.readObject(at: fileURL),
              (cached["schema"] as? NSNumber)?.intValue == 1,
              let saved = cached["saved_at"] as? NSNumber,
              let cachedWakes = cached["wakes"] as? NSNumber,
              cachedWakes.intValue >= 0,
              let cachedInsights = cached["insights"] as? [String: Any],
              cachedInsights["today"] is [String: Any],
              cachedInsights["week"] is [String: Any] else { return }
        wakes = cachedWakes.intValue
        insights = cachedInsights
        savedAt = saved.doubleValue
        if let cachedRows = cached["history_rows"] as? [[String: Any]] {
            hasHistoryCache = true
            historyRows = cachedRows.compactMap { value in
                guard let timestamp = Self.number(value["ts"]), timestamp > 0,
                      let percentValue = Self.number(value["percent"]),
                      percentValue >= 0, percentValue <= 100,
                      let onAC = value["on_ac"] as? Bool else { return nil }
                return SlowHistoryRow(timestamp: timestamp,
                                      percent: Int(percentValue.rounded()),
                                      onAC: onAC)
            }.sorted { $0.timestamp < $1.timestamp }
        }
        if let cachedWakeDates = cached["wake_dates"] as? [Any] {
            hasWakeHistory = true
            wakeDates = cachedWakeDates.compactMap(Self.number)
                .filter { $0 > 0 }.sorted()
        }
    }

    func statsSnapshot() -> [String: Any] {
        lock.withLock {
            let now = Date().timeIntervalSince1970
            let hasSaved = savedAt > 0
            let currentWakes = !hasWakeHistory
                ? wakes : wakeDates.filter { $0 >= now - 14 * 3600 }.count
            var currentInsights = insights
            if hasWakeHistory {
                currentInsights["wakes"] = wakeDates.filter { $0 >= now - 24 * 3600 }.count
            }
            return [
                "wakes": currentWakes,
                "insights": JSONValue.bridgeSafe(currentInsights),
                "insights_loading": !hasSaved,
                "insights_refreshing": refreshing,
                "insights_stale": hasSaved && !Self.cacheIsFresh(savedAt: savedAt, now: now)
            ]
        }
    }

    func historySnapshot() -> SlowHistorySnapshot {
        lock.withLock {
            SlowHistorySnapshot(rows: historyRows, wakeDates: wakeDates,
                                savedAt: savedAt, refreshing: refreshing,
                                available: hasHistoryCache)
        }
    }

    func beginRefresh(force: Bool = false) -> Bool {
        lock.withLock {
            let now = Date().timeIntervalSince1970
            if refreshing { return false }
            if lastAttempt > 0 && now - lastAttempt < Self.retryInterval { return false }
            if !force && Self.cacheIsFresh(savedAt: savedAt, now: now) { return false }
            refreshing = true
            lastAttempt = now
            return true
        }
    }

    @discardableResult
    func finish(wakes: Int, insights: [String: Any],
                historyRows: [SlowHistoryRow] = [],
                wakeDates: [TimeInterval] = []) -> Bool {
        lock.withLock {
            let now = Date().timeIntervalSince1970
            let cleanRows = Array(historyRows
                .filter { $0.timestamp > 0 && $0.timestamp.isFinite
                    && (0...100).contains($0.percent) }
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(20_000))
            let cleanWakeDates = Array(wakeDates.filter { $0 > 0 && $0.isFinite }
                .sorted().suffix(50_000))
            let payload: [String: Any] = [
                "schema": 1,
                "saved_at": now,
                "wakes": max(0, wakes),
                "insights": JSONValue.bridgeSafe(insights),
                "history_rows": cleanRows.map {
                    ["ts": $0.timestamp, "percent": $0.percent, "on_ac": $0.onAC]
                },
                "wake_dates": cleanWakeDates
            ]
            do {
                // Publish the snapshot in memory only after its atomic disk write
                // succeeds. A failed write must not suppress the next refresh.
                try JSONValue.write(payload, to: fileURL)
                self.wakes = max(0, wakes)
                self.insights = insights
                self.historyRows = cleanRows
                self.wakeDates = cleanWakeDates
                hasHistoryCache = true
                hasWakeHistory = true
                savedAt = now
                refreshing = false
                return true
            } catch {
                refreshing = false
                return false
            }
        }
    }

    func failRefresh() { lock.withLock { refreshing = false } }

    private static func cacheIsFresh(savedAt: TimeInterval, now: TimeInterval) -> Bool {
        let age = now - savedAt
        return savedAt > 0 && age >= -300 && age < automaticRefreshInterval
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }
}
