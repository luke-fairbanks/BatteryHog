import Darwin
import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}

private final class CommandPipeCollector {
    private let handle: FileHandle
    private let lineFilter: ((String) -> Bool)?
    private let lock = NSLock()
    private var data = Data()
    private var pendingLine = Data()

    init(handle: FileHandle, completion: DispatchGroup,
         lineFilter: ((String) -> Bool)? = nil) {
        self.handle = handle
        self.lineFilter = lineFilter
        completion.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                flushPendingLine()
                completion.leave()
            }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 64 * 1024),
                          !chunk.isEmpty else { return }
                    append(chunk)
                } catch {
                    return
                }
            }
        }
    }

    func close() {
        try? handle.close()
    }

    func string() -> String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    private func append(_ chunk: Data) {
        lock.withLock {
            guard let lineFilter else {
                data.append(chunk)
                return
            }
            pendingLine.append(chunk)
            while let newline = pendingLine.firstIndex(of: 0x0A) {
                let end = pendingLine.index(after: newline)
                let lineData = pendingLine[..<end]
                if let line = String(data: lineData, encoding: .utf8), lineFilter(line) {
                    data.append(lineData)
                }
                pendingLine.removeSubrange(..<end)
            }
        }
    }

    private func flushPendingLine() {
        lock.withLock {
            guard !pendingLine.isEmpty, let lineFilter else { return }
            if let line = String(data: pendingLine, encoding: .utf8), lineFilter(line) {
                data.append(pendingLine)
            }
            pendingLine.removeAll(keepingCapacity: false)
        }
    }
}

enum SystemCommand {
    static func run(_ executable: String,
                    _ arguments: [String] = [],
                    timeout: TimeInterval = 12,
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil,
                    stdoutLineFilter: ((String) -> Bool)? = nil) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = environment
        process.currentDirectoryURL = currentDirectory

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription,
                                 timedOut: false)
        }

        let reads = DispatchGroup()
        let stdout = CommandPipeCollector(handle: stdoutPipe.fileHandleForReading,
                                          completion: reads,
                                          lineFilter: stdoutLineFilter)
        let stderr = CommandPipeCollector(handle: stderrPipe.fileHandleForReading,
                                          completion: reads)

        // A private process group lets a timeout stop descendants that inherited
        // our output pipes. If the child has already exec'd, setpgid can race and
        // fail; in that case we safely fall back to signaling only the child.
        let pid = process.processIdentifier
        let ownsProcessGroup = Darwin.setpgid(pid, pid) == 0

        let waitResult = finished.wait(timeout: .now() + timeout)
        let timedOut = waitResult == .timedOut
        var terminated = !timedOut
        if timedOut {
            let target = ownsProcessGroup ? -pid : pid
            if process.isRunning { Darwin.kill(target, SIGTERM) }
            terminated = finished.wait(timeout: .now() + 0.6) == .success
            if !terminated {
                Darwin.kill(target, SIGKILL)
                terminated = finished.wait(timeout: .now() + 1) == .success
            }
        }

        // Never let a descendant holding stdout/stderr open turn a timeout (or
        // even a normal parent exit) into an unbounded wait. Readers accumulate
        // incrementally, so a forced close still returns everything seen so far.
        let drainWindow: TimeInterval = timedOut ? 0.1 : 1.5
        if reads.wait(timeout: .now() + drainWindow) == .timedOut {
            stdout.close()
            stderr.close()
            _ = reads.wait(timeout: .now() + 0.4)
        }

        return CommandResult(
            status: terminated ? process.terminationStatus : -1,
            stdout: stdout.string(),
            stderr: stderr.string(),
            timedOut: timedOut
        )
    }

    static func output(_ executable: String,
                       _ arguments: [String] = [],
                       timeout: TimeInterval = 12) -> String {
        run(executable, arguments, timeout: timeout).stdout
    }

    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func runPrivileged(_ executable: String,
                              _ arguments: [String],
                              timeout: TimeInterval = 45) -> (Bool, String, String) {
        let argv = [executable] + arguments
        let sudo = run("/usr/bin/sudo", ["-n"] + argv, timeout: timeout)
        if sudo.succeeded { return (true, sudo.stdout, "") }

        let shellCommand = argv.map(shellQuote).joined(separator: " ")
        let script = [
            "on run argv",
            "do shell script (item 1 of argv) with administrator privileges",
            "end run"
        ]
        var osaArguments: [String] = []
        for line in script { osaArguments += ["-e", line] }
        osaArguments.append(shellCommand)
        let result = run("/usr/bin/osascript", osaArguments, timeout: timeout)
        if result.succeeded { return (true, result.stdout, "") }
        if result.timedOut {
            return (false, "", "Timed out waiting for the password prompt.")
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.lowercased().contains("cancel") { return (false, "", "Cancelled.") }
        return (false, "", detail.isEmpty ? "Command failed." : detail)
    }
}

enum JSONValue {
    static func object(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    static func readObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return object(from: data) as? [String: Any]
    }

    static func readArray(at url: URL) -> [Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return object(from: data) as? [Any]
    }

    static func write(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    static func bridgeSafe(_ value: Any) -> Any {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONSerialization.jsonObject(with: data) else {
            return ["error": "invalid native response"]
        }
        return decoded
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension NSRecursiveLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

func regexFirst(_ pattern: String,
                in text: String,
                options: NSRegularExpression.Options = [],
                group: Int = 1) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          group < match.numberOfRanges,
          let resultRange = Range(match.range(at: group), in: text) else { return nil }
    return String(text[resultRange])
}

func regexMatches(_ pattern: String,
                  in text: String,
                  options: NSRegularExpression.Options = []) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    return regexMatches(regex, in: text)
}

func regexMatches(_ regex: NSRegularExpression, in text: String) -> [[String]] {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, options: [], range: range).map { match in
        (0..<match.numberOfRanges).map { index in
            guard let r = Range(match.range(at: index), in: text) else { return "" }
            return String(text[r])
        }
    }
}

func rounded(_ value: Double, places: Int = 1) -> Double {
    let scale = pow(10.0, Double(places))
    return (value * scale).rounded() / scale
}

func jsonOptional<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}
