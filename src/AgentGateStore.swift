import Darwin
import Foundation

struct AgentGateSettings {
    let enabled: Bool
    let slots: Int
    let workers: Int
    let drawThreshold: Int
    let notifyDraw: Bool

    static func load(from dataDirectory: URL) -> AgentGateSettings {
        let object = JSONValue.readObject(at: dataDirectory.appendingPathComponent("settings.json"))
        let dev = object?["dev"] as? [String: Any] ?? [:]
        return AgentGateSettings(
            enabled: dev["enabled"] as? Bool ?? false,
            slots: min(4, max(1, number(dev["slots"]) ?? 2)),
            workers: min(8, max(1, number(dev["workers"]) ?? 2)),
            drawThreshold: min(80, max(10, number(dev["draw_threshold"]) ?? 30)),
            notifyDraw: dev["notify_draw"] as? Bool ?? true
        )
    }

    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }
}

struct GateAdmission {
    let admitted: Bool
    let position: Int
    let active: Int
}

final class AgentGateStore {
    let dataDirectory: URL
    private let registryURL: URL
    private let lockURL: URL

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        registryURL = dataDirectory.appendingPathComponent("agent-gate.json")
        lockURL = dataDirectory.appendingPathComponent("agent-gate.lock")
    }

    func snapshot() -> [String: Any] {
        guard let value = try? readRegistry() else {
            return ["active": [[String: Any]](), "queued": [[String: Any]]()]
        }
        let entries = value["entries"] as? [[String: Any]] ?? []
        let liveEntries = entries.filter(Self.entryIsAlive)
        if liveEntries.count != entries.count && !Self.legacyGateProcessIsRunning() {
            // Upgrade to the exclusive mutation path only when stale wrappers
            // actually need pruning. A normal dashboard poll stays read-only.
            try? withRegistry { _ in () }
        }
        return [
            "active": liveEntries.filter { $0["state"] as? String == "active" },
            "queued": liveEntries.filter { $0["state"] as? String == "queued" }
        ]
    }

    func admission(for entry: [String: Any], slots: Int) throws -> GateAdmission {
        if Self.legacyGateProcessIsRunning() {
            return GateAdmission(admitted: false, position: 1, active: slots)
        }
        return try withRegistry { value in
            var entries = value["entries"] as? [[String: Any]] ?? []
            if Self.legacyGateProcessIsRunning() {
                let active = entries.filter { $0["state"] as? String == "active" }.count
                return GateAdmission(admitted: false, position: entries.count + 1,
                                     active: max(active, slots))
            }
            // Python-era helpers lock the registry inode rather than the Swift
            // sidecar. While one is still alive, stay read-only and wait for it
            // to finish so the two generations cannot overwrite each other.
            if entries.contains(where: { !($0["pid_identity"] is String) }) {
                let active = entries.filter { $0["state"] as? String == "active" }.count
                return GateAdmission(admitted: false, position: entries.count + 1,
                                     active: active)
            }
            let entryID = entry["id"] as? String ?? ""
            var index = entries.firstIndex { $0["id"] as? String == entryID }
            if index == nil {
                entries.append(entry)
                index = entries.count - 1
            }
            let activeCount = entries.filter { $0["state"] as? String == "active" }.count
            let queuedIndices = entries.indices.filter { entries[$0]["state"] as? String == "queued" }
                .sorted { lhs, rhs in
                    let leftTime = (entries[lhs]["requested_at"] as? NSNumber)?.int64Value ?? 0
                    let rightTime = (entries[rhs]["requested_at"] as? NSNumber)?.int64Value ?? 0
                    if leftTime != rightTime { return leftTime < rightTime }
                    return (entries[lhs]["id"] as? String ?? "") < (entries[rhs]["id"] as? String ?? "")
                }
            let available = max(0, slots - activeCount)
            let admittedIndices = Set(queuedIndices.prefix(available))
            let admitted = index.map(admittedIndices.contains) ?? false
            if admitted, let index {
                entries[index]["state"] = "active"
                entries[index]["started_at"] = Int(Date().timeIntervalSince1970)
            }
            let position = index.flatMap { queuedIndices.firstIndex(of: $0) }.map { $0 + 1 } ?? 1
            value["entries"] = entries
            return GateAdmission(admitted: admitted, position: position, active: activeCount)
        }
    }

    @discardableResult
    func registerChild(entryID: String, childPID: Int32, childProcessGroup: Int32? = nil,
                       workerLimit: Int, slotLimit: Int) -> Bool {
        (try? withRegistry { value in
            var entries = value["entries"] as? [[String: Any]] ?? []
            guard let index = entries.firstIndex(where: { $0["id"] as? String == entryID }) else {
                return false
            }
            entries[index]["child_pid"] = Int(childPID)
            entries[index]["child_identity"] = Self.processIdentity(childPID) as Any? ?? NSNull()
            if let childProcessGroup { entries[index]["child_pgid"] = Int(childProcessGroup) }
            entries[index]["worker_limit"] = workerLimit
            entries[index]["slot_limit"] = slotLimit
            value["entries"] = entries
            return true
        }) ?? false
    }

    func remove(wrapperPID: Int32) {
        try? withRegistry { value in
            let entries = value["entries"] as? [[String: Any]] ?? []
            value["entries"] = entries.filter {
                ($0["pid"] as? NSNumber)?.int32Value != wrapperPID
            }
        }
    }

    private func withRegistry<T>(_ body: (inout [String: Any]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: dataDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: dataDirectory.path)
        let descriptor = Darwin.open(lockURL.path,
                                     O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try validateRegistryDescriptor(descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try acquireLock(descriptor, operation: LOCK_EX, timeout: 1.5)
        defer {
            flock(descriptor, LOCK_UN)
            try? handle.close()
        }

        // Also lock the registry inode for compatibility with Python-era gate
        // processes that may still be winding down across an app update.
        let registryDescriptor = Darwin.open(registryURL.path,
                                             O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard registryDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let registryHandle = FileHandle(fileDescriptor: registryDescriptor, closeOnDealloc: true)
        try validateRegistryDescriptor(registryDescriptor)
        guard Darwin.fchmod(registryDescriptor, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try acquireLock(registryDescriptor, operation: LOCK_EX, timeout: 1.5)
        defer {
            flock(registryDescriptor, LOCK_UN)
            try? registryHandle.close()
        }

        var value = readRegistryValue(registryHandle)
        let entries = value["entries"] as? [[String: Any]] ?? []
        let liveEntries = entries.filter(Self.entryIsAlive)
        value["entries"] = liveEntries
        let hasLiveLegacyEntry = liveEntries.contains { !($0["pid_identity"] is String) }
        let before = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let result = try body(&value)
        let after = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if hasLiveLegacyEntry {
            guard before == after else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
            }
            return result
        }
        guard liveEntries.count != entries.count || before != after else { return result }
        // Close the remaining check-to-write window as far as possible. A gate
        // that is racing the update waits and retries instead of writing across
        // the legacy inode/Swift sidecar locking boundary.
        if Self.legacyGateProcessIsRunning() {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
        }
        value["lock_version"] = 2
        value["updated_at"] = Int(Date().timeIntervalSince1970)

        // Lock a stable sidecar and atomically replace the data file. Locking the
        // registry inode itself would stop protecting readers after a rename.
        try JSONValue.write(value, to: registryURL)
        return result
    }

    private func readRegistry() throws -> [String: Any] {
        if Darwin.access(registryURL.path, F_OK) != 0, errno == ENOENT {
            return ["version": 1, "entries": [[String: Any]]()]
        }
        let descriptor = Darwin.open(lockURL.path,
                                     O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try validateRegistryDescriptor(descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try acquireLock(descriptor, operation: LOCK_SH, timeout: 0.2)
        defer {
            flock(descriptor, LOCK_UN)
            try? handle.close()
        }
        return try readRegistryUnlocked()
    }

    private func readRegistryUnlocked() throws -> [String: Any] {
        let descriptor = Darwin.open(registryURL.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT {
                return ["version": 1, "entries": [[String: Any]]()]
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try validateRegistryDescriptor(descriptor)
        try acquireLock(descriptor, operation: LOCK_SH, timeout: 0.5)
        defer {
            flock(descriptor, LOCK_UN)
            try? handle.close()
        }
        return readRegistryValue(handle)
    }

    private func readRegistryValue(_ handle: FileHandle) -> [String: Any] {
        handle.seek(toFileOffset: 0)
        let data = handle.readDataToEndOfFile()
        return (data.isEmpty ? nil : JSONValue.object(from: data) as? [String: Any])
            ?? ["version": 1, "entries": [[String: Any]]()]
    }

    private func validateRegistryDescriptor(_ descriptor: Int32) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard info.st_uid == getuid() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
    }

    private func acquireLock(_ descriptor: Int32, operation: Int32,
                             timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, operation | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard Date() < deadline else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
            }
            usleep(20_000)
        }
    }

    static func processIdentity(_ pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private static func processIsAlive(_ pid: Int32, identity: Any?) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid, 0) != 0, errno != EPERM { return false }
        guard let expected = identity as? String, !expected.isEmpty else { return true }
        return processIdentity(pid) == expected
    }

    static func processGroupIsAlive(_ processGroup: Int32) -> Bool {
        guard processGroup > 1 else { return false }
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func legacyGateProcessIsRunning() -> Bool {
        let estimated = max(Int(proc_listallpids(nil, 0)) + 32, 64)
        var pids = [Int32](repeating: 0, count: estimated)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return false }
        for pid in pids.prefix(Int(count)) where pid > 1 && pid != getpid() {
            var path = [CChar](repeating: 0, count: 4_096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = URL(fileURLWithPath: String(cString: path))
                .lastPathComponent.lowercased()
            guard executable.hasPrefix("python") else { continue }
            guard let argument = pythonScriptArgument(processArguments(pid)),
                  URL(fileURLWithPath: argument).lastPathComponent == "batteryhog_gate.py" else {
                continue
            }
            return true
        }
        return false
    }

    private static func pythonScriptArgument(_ arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return arguments.dropFirst(index + 1).first }
            if !argument.hasPrefix("-") || argument == "-" { return argument }
            if argument == "-c" || argument == "-m" { return nil }
            if argument == "-W" || argument == "-X" { index += 2 }
            else { index += 1 }
        }
        return nil
    }

    private static func processArguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size, size <= 1_048_576 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard bytes.withUnsafeMutableBytes({
            sysctl(&mib, 3, $0.baseAddress, &size, nil, 0)
        }) == 0, size >= MemoryLayout<Int32>.size else { return [] }
        let argumentCount = bytes.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argumentCount > 0 && argumentCount <= 4_096 else { return [] }
        var index = MemoryLayout<Int32>.size
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while index < size && result.count < Int(argumentCount) {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            while index < size && bytes[index] == 0 { index += 1 }
        }
        return result
    }

    private static func entryIsAlive(_ entry: [String: Any]) -> Bool {
        if let pid = (entry["pid"] as? NSNumber)?.int32Value,
           processIsAlive(pid, identity: entry["pid_identity"]) {
            return true
        }
        // If the wrapper is killed after launching its child, the heavy job is
        // still consuming a lane and must remain counted until that child exits.
        if entry["state"] as? String == "active",
           let childPID = (entry["child_pid"] as? NSNumber)?.int32Value,
           processIsAlive(childPID, identity: entry["child_identity"]) {
            return true
        }
        if entry["state"] as? String == "active",
           let childPID = (entry["child_pid"] as? NSNumber)?.int32Value,
           Darwin.kill(childPID, 0) != 0, errno != EPERM,
           let childGroup = (entry["child_pgid"] as? NSNumber)?.int32Value,
           processGroupIsAlive(childGroup) {
            return true
        }
        return false
    }
}

enum AgentGateEnvironment {
    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["BATTERY_HOG_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BatteryHog", isDirectory: true)
    }

    static func onBattery() -> Bool {
        SystemCommand.output("/usr/bin/pmset", ["-g", "batt"], timeout: 3)
            .contains("Battery Power")
    }
}
