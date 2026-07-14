import CryptoKit
import Foundation

struct ProcessSample {
    let pid: Int32
    let ppid: Int32
    let rssKB: Int
    let cpu: Double
    let command: String
}

private struct DevCommandInfo {
    let family: String
    let tool: String
    let kind: String
    let heavy: Bool
}

private struct DevRule {
    let regex: NSRegularExpression
    let family: String
    let tool: String
    let kind: String
    let heavy: Bool

    init(_ pattern: String, _ family: String, _ tool: String, _ kind: String, _ heavy: Bool) {
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        self.family = family
        self.tool = tool
        self.kind = kind
        self.heavy = heavy
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }
}

final class WorkloadDetector {
    private struct CachedCWD {
        let date: Date
        let path: String?
    }

    private final class Group {
        let id: String
        let name: String
        let path: String
        let context: String
        var cpu = 0.0
        var memoryKB = 0
        var workers = 0
        var activeWorkers = 0
        var heavyWorkers = 0
        var servers = 0
        var families = Set<String>()
        var tools: [String: Int] = [:]
        var pids: [Int] = []
        var agents = Set<String>()
        var kindCPU: [String: Double] = [:]

        init(key: String, name: String, path: String, context: String) {
            id = WorkloadDetector.stableID(key)
            self.name = name
            self.path = path
            self.context = context
        }
    }

    private static let rules = [
        DevRule(#"(?:^|[/\s])gitleaks(?:$|[\s])"#, "Security", "gitleaks", "scan", true),
        DevRule(#"(?:^|[/\s])semgrep(?:$|[\s])"#, "Security", "Semgrep", "scan", true),
        DevRule(#"(?:^|[/\s])trivy(?:$|[\s])"#, "Security", "Trivy", "scan", true),
        DevRule(#"(?:^|[/\s])rustc(?:$|[\s])"#, "Rust", "rustc", "compiler", true),
        DevRule(#"(?:^|[/\s])cargo(?:$|[\s])"#, "Rust", "Cargo", "build", true),
        DevRule(#"(?:^|[/\s])sccache(?:$|[\s])"#, "Rust", "sccache", "compiler", true),
        DevRule(#"org\.jetbrains\.kotlin|kotlincompiledaemon|kotlinc"#, "Kotlin", "Kotlin", "compiler", true),
        DevRule(#"org\.gradle|gradlewrappermain|(?:^|[/\s])gradlew?(?:$|[\s])"#, "JVM", "Gradle", "build", true),
        DevRule(#"(?:^|[/\s])java(?:$|[\s])"#, "JVM", "Java", "worker", true),
        DevRule(#"(?:^|[/\s])xcodebuild(?:$|[\s])"#, "Apple", "Xcode", "build", true),
        DevRule(#"(?:^|[/\s])swiftc(?:$|[\s])"#, "Apple", "Swift", "compiler", true),
        DevRule(#"(?:^|[/\s])swift(?:$|[\s]).*(?:build|test|package)"#, "Apple", "SwiftPM", "build", true),
        DevRule(#"(?:^|[/\s])pod(?:$|[\s])|cocoapods|pod install"#, "Apple", "CocoaPods", "install", true),
        DevRule(#"(?:^|[/\s])go(?:$|[\s]+)(?:build|test|run|install)"#, "Go", "Go", "build", true),
        DevRule(#"(?:^|[/\s])pytest(?:$|[\s])|python[^\n]*-m\s+pytest"#, "Python", "pytest", "test", true),
        DevRule(#"(?:^|[/\s])(ruff|mypy|pyright)(?:$|[\s])"#, "Python", "Python checks", "test", true),
        DevRule(#"(?:^|[/\s])(jest|vitest|playwright|cypress)(?:$|[\s])"#, "Node", "JavaScript tests", "test", true),
        DevRule(#"(?:^|[/\s])(tsc|esbuild|webpack|rollup|turbo)(?:$|[\s])"#, "Node", "JavaScript build", "build", true),
        DevRule(#"(?:^|[/\s])(npm|pnpm|yarn|bun)(?:$|[\s]).*(?:install|ci|build|test)"#, "Node", "Node package task", "build", true),
        DevRule(#"next-server|next\s+dev|vite(?:$|[\s])|webpack-dev-server|react-scripts\s+start"#, "Node", "Dev server", "server", false),
        DevRule(#"(?:^|[/\s])(npm|pnpm|yarn|bun|npx)(?:$|[\s])"#, "Node", "Node task", "worker", true),
        DevRule(#"(?:^|[/\s])node(?:$|[\s])|\(node\)"#, "Node", "Node", "worker", true),
        DevRule(#"(?:^|[/\s])(make|cmake|ninja)(?:$|[\s])"#, "Native", "Native build", "build", true),
    ]

    private static let systemAssertionOwners: Set<String> = [
        "powerd", "runningboardd", "sharingd", "bluetoothd", "WindowServer",
        "mds", "mds_stores", "coreaudiod", "airportd", "apsd"
    ]

    private let cwdLock = NSLock()
    private var cwdCache: [Int32: CachedCWD] = [:]
    private let fileManager = FileManager.default

    static func agentOwner(_ command: String) -> String? {
        let low = command.lowercased()
        if low.contains("battery_hog") || low.contains("batteryhog") { return nil }
        if low.contains("claude") { return "Claude" }
        if low.contains("chatgpt.app") || matches(#"(?:^|[/\s])codex(?:$|[\s])"#, low) {
            return "Codex"
        }
        if low.contains("cursor.app") || matches(#"(?:^|[/\s])cursor(?:$|[\s])"#, low) {
            return "Cursor"
        }
        if low.contains("visual studio code.app") || low.contains("code helper") { return "VS Code" }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        regexFirst("(" + pattern + ")", in: text, options: [.caseInsensitive]) != nil
    }

    private static func classify(_ command: String) -> DevCommandInfo? {
        let low = command.lowercased()
        if low.isEmpty || low.contains("battery_hog") || low.contains("batteryhog_workloads") {
            return nil
        }
        if let owner = agentOwner(command) {
            return DevCommandInfo(family: "Agents", tool: owner, kind: "agent", heavy: false)
        }
        guard let rule = rules.first(where: { $0.matches(low) }) else { return nil }
        return DevCommandInfo(family: rule.family, tool: rule.tool,
                              kind: rule.kind, heavy: rule.heavy)
    }

    func discover(_ samples: [ProcessSample]) -> [String: Any] {
        let byPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        var wanted = Set<Int32>()
        for process in samples where Self.classify(process.command) != nil {
            var pid = process.pid
            for _ in 0..<7 {
                if pid <= 0 || wanted.contains(pid) { break }
                wanted.insert(pid)
                pid = byPID[pid]?.ppid ?? 0
            }
        }
        let cwdByPID = collectCWDs(Array(wanted))
        return aggregate(samples, byPID: byPID, cwdByPID: cwdByPID)
    }

    private func collectCWDs(_ pids: [Int32]) -> [Int32: String] {
        let now = Date()
        let wanted = Array(Set(pids.filter { $0 > 0 })).sorted()
        let missing: [Int32] = cwdLock.withLock {
            wanted.filter { pid in
                guard let cached = cwdCache[pid] else { return true }
                return now.timeIntervalSince(cached.date) > 20
            }
        }

        for start in stride(from: 0, to: missing.count, by: 70) {
            let chunk = Array(missing[start..<min(start + 70, missing.count)])
            guard !chunk.isEmpty else { continue }
            let output = SystemCommand.output(
                "/usr/sbin/lsof",
                ["-a", "-d", "cwd", "-p", chunk.map(String.init).joined(separator: "," )],
                timeout: 4
            )
            var found: [Int32: String] = [:]
            var current: Int32?
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let value = String(line)
                if value.hasPrefix("p"), let pid = Int32(value.dropFirst()) {
                    current = pid
                } else if value.hasPrefix("n"), let pid = current {
                    found[pid] = String(value.dropFirst())
                }
            }
            cwdLock.withLock {
                for pid in chunk { cwdCache[pid] = CachedCWD(date: now, path: found[pid]) }
            }
        }

        return cwdLock.withLock {
            cwdCache = cwdCache.filter { now.timeIntervalSince($0.value.date) <= 120 }
            return Dictionary(uniqueKeysWithValues: wanted.compactMap { pid in
                guard let path = cwdCache[pid]?.path else { return nil }
                return (pid, path)
            })
        }
    }

    private func resolvedCWD(_ pid: Int32,
                             byPID: [Int32: ProcessSample],
                             cwdByPID: [Int32: String]) -> String? {
        var current = pid
        var seen = Set<Int32>()
        while current > 0 && !seen.contains(current) {
            seen.insert(current)
            if let path = cwdByPID[current] { return path }
            guard let process = byPID[current] else { break }
            current = process.ppid
        }
        return nil
    }

    private func project(for cwd: String?) -> (key: String, name: String, path: String, context: String)? {
        guard let cwd, cwd.hasPrefix("/") else { return nil }
        if ["/System/", "/usr/", "/bin/", "/sbin/", "/Applications/"].contains(where: cwd.hasPrefix) {
            return nil
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        if cwd.hasPrefix(home + "/") {
            let relative = String(cwd.dropFirst(home.count + 1))
            let first = relative.split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix(".") || first == "Library" { return nil }
        }

        var current = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        var nearest: URL?
        var gitRoot: URL?
        let markers = ["Cargo.toml", "package.json", "pyproject.toml", "go.mod",
                       "Podfile", "Package.swift", "gradlew"]
        for _ in 0..<14 {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                gitRoot = current
                break
            }
            if nearest == nil,
               markers.contains(where: { fileManager.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                nearest = current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        let root = gitRoot ?? nearest ?? cwdURL
        var name = root.lastPathComponent.isEmpty ? "Development" : root.lastPathComponent
        if ["repo", "checkout", "worktree"].contains(name.lowercased()) {
            name = root.deletingLastPathComponent().lastPathComponent
        }
        name = name.replacingOccurrences(of: #"[._-][A-Za-z0-9]{6}$"#,
                                         with: "", options: .regularExpression)
        let rootPath = root.path
        var context = ""
        if cwdURL.path.hasPrefix(rootPath + "/") {
            context = String(cwdURL.path.dropFirst(rootPath.count + 1))
            let parts = context.split(separator: "/")
            if parts.count > 3 { context = parts.suffix(3).joined(separator: "/") }
        }
        let short = rootPath.hasPrefix(home) ? "~" + String(rootPath.dropFirst(home.count)) : rootPath
        return (rootPath, name, short, context)
    }

    private func ancestorAgent(_ pid: Int32, byPID: [Int32: ProcessSample]) -> String? {
        var current = pid
        var seen = Set<Int32>()
        while current > 0 && !seen.contains(current) {
            seen.insert(current)
            guard let process = byPID[current] else { break }
            if let owner = Self.agentOwner(process.command) { return owner }
            current = process.ppid
        }
        return nil
    }

    private func aggregate(_ samples: [ProcessSample],
                           byPID: [Int32: ProcessSample],
                           cwdByPID: [Int32: String]) -> [String: Any] {
        var groups: [String: Group] = [:]
        var allAgents = Set<String>()
        for process in samples {
            guard let info = Self.classify(process.command), info.kind != "agent" else { continue }
            let cpu = max(0, process.cpu)
            let rss = max(0, process.rssKB)
            let cwd = resolvedCWD(process.pid, byPID: byPID, cwdByPID: cwdByPID)
            let foundProject = project(for: cwd)
            if foundProject == nil && ["worker", "server"].contains(info.kind) && cpu < 1 { continue }

            let key: String
            let metadata: (name: String, path: String, context: String)
            if let project = foundProject {
                key = project.key
                metadata = (project.name, project.path, project.context)
            } else {
                key = "background:" + info.family
                metadata = (info.family + " tools", "Background", "")
            }
            let group: Group
            if let existing = groups[key] {
                group = existing
            } else {
                group = Group(key: key, name: metadata.name, path: metadata.path,
                              context: metadata.context)
                groups[key] = group
            }
            group.cpu += cpu
            group.memoryKB += rss
            group.workers += 1
            group.pids.append(Int(process.pid))
            group.families.insert(info.family)
            group.tools[info.tool, default: 0] += 1
            group.kindCPU[info.kind, default: 0] += cpu
            if info.kind == "server" { group.servers += 1 }
            if cpu >= 1 {
                group.activeWorkers += 1
                if info.heavy { group.heavyWorkers += 1 }
            }
            if let owner = ancestorAgent(process.pid, byPID: byPID) {
                group.agents.insert(owner)
                allAgents.insert(owner)
            }
        }

        var workloads: [[String: Any]] = groups.values.map { group in
            let cpu = rounded(group.cpu)
            let memoryMB = rounded(Double(group.memoryKB) / 1024)
            let level: String
            if cpu >= 180 || group.heavyWorkers >= 5 { level = "high" }
            else if cpu >= 35 || group.heavyWorkers >= 2 || group.servers >= 3 { level = "med" }
            else { level = "low" }

            let dominant = group.kindCPU.max { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value < rhs.value
            }?.key ?? (group.servers > 0 ? "server" : "worker")
            let labels = ["build": "Building", "compiler": "Compiling", "test": "Testing",
                          "install": "Installing", "scan": "Scanning", "server": "Serving",
                          "worker": "Active"]
            let status: String
            if group.activeWorkers == 0 && group.servers > 0 { status = "Serving" }
            else if group.activeWorkers == 0 { status = "Idle" }
            else { status = labels[dominant] ?? "Active" }

            let tools = group.tools.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(6).map { ["name": $0.key, "count": $0.value] as [String: Any] }
            let score = rounded(cpu + memoryMB / 75 + Double(group.heavyWorkers * 8))
            return [
                "id": group.id, "name": group.name, "path": group.path,
                "context": group.context, "cpu": cpu, "mem_mb": memoryMB,
                "workers": group.workers, "active_workers": group.activeWorkers,
                "heavy_workers": group.heavyWorkers, "servers": group.servers,
                "families": group.families.sorted(), "tools": tools,
                "pids": Array(group.pids.prefix(80)), "agents": group.agents.sorted(),
                "level": level, "status": status, "score": score
            ]
        }
        workloads.sort { ($0["score"] as? Double ?? 0) > ($1["score"] as? Double ?? 0) }

        let projects = workloads.count
        let workers = workloads.reduce(0) { $0 + ($1["workers"] as? Int ?? 0) }
        let active = workloads.reduce(0) { $0 + ($1["active_workers"] as? Int ?? 0) }
        let heavy = workloads.reduce(0) { $0 + ($1["heavy_workers"] as? Int ?? 0) }
        let servers = workloads.reduce(0) { $0 + ($1["servers"] as? Int ?? 0) }
        let cpu = rounded(workloads.reduce(0.0) { $0 + ($1["cpu"] as? Double ?? 0) })
        let memory = rounded(workloads.reduce(0.0) { $0 + ($1["mem_mb"] as? Double ?? 0) })
        let toolchains = Set(workloads.flatMap { $0["families"] as? [String] ?? [] }).sorted()
        let level = (cpu >= 250 || heavy >= 7) ? "high" : ((cpu >= 60 || heavy >= 2) ? "med" : "low")
        let summary: [String: Any] = [
            "projects": projects, "workers": workers, "active_workers": active,
            "heavy_workers": heavy, "servers": servers, "cpu": cpu, "mem_mb": memory,
            "agents": allAgents.sorted(), "toolchains": toolchains, "level": level
        ]
        return ["workloads": Array(workloads.prefix(24)), "summary": summary]
    }

    static func parseSleepAssertions(_ text: String) -> [[String: Any]] {
        let pattern = #"pid\s+(\d+)\(([^)]+)\):.*?(\d+:\d+:\d+)\s+(NoIdleSleepAssertion|PreventUserIdleSystemSleep|PreventSystemSleep|PreventUserIdleDisplaySleep)\s+named:\s+\"([^\"]*)\""#
        var blockers: [[String: Any]] = []
        for match in regexMatches(pattern, in: text) where match.count >= 6 {
            guard let pid = Int(match[1]) else { continue }
            let name = match[2]
            let duration = match[3]
            let parts = duration.split(separator: ":").compactMap { Int($0) }
            let seconds = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : 0
            let system = systemAssertionOwners.contains(name) || name.hasPrefix("com.apple.")
            blockers.append([
                "pid": pid, "name": name, "duration": duration, "duration_s": seconds,
                "assertion": match[4], "detail": match[5], "system": system,
                "stale": !system && seconds >= 15 * 60
            ])
        }
        blockers.sort {
            let lhsSystem = $0["system"] as? Bool ?? false
            let rhsSystem = $1["system"] as? Bool ?? false
            if lhsSystem != rhsSystem { return !lhsSystem }
            return ($0["duration_s"] as? Int ?? 0) > ($1["duration_s"] as? Int ?? 0)
        }
        return blockers
    }

    private static func stableID(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

#if BATTERY_HOG_TESTING
    static func classificationForTesting(_ command: String) -> [String: Any]? {
        guard let info = classify(command) else { return nil }
        return ["family": info.family, "tool": info.tool,
                "kind": info.kind, "heavy": info.heavy]
    }

    func aggregateForTesting(_ samples: [ProcessSample], cwdByPID: [Int32: String]) -> [String: Any] {
        let byPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        return aggregate(samples, byPID: byPID, cwdByPID: cwdByPID)
    }

    func projectForTesting(_ cwd: String?) -> [String: String]? {
        guard let result = project(for: cwd) else { return nil }
        return ["key": result.key, "name": result.name,
                "path": result.path, "context": result.context]
    }
#endif
}
