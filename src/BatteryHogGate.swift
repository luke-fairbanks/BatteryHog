import Darwin
import Foundation

@main
enum BatteryHogGateMain {
    static func main() {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        guard let parsed = parseWrapperArguments(rawArguments) else {
            fputs("usage: batteryhog-gate [--force-battery] [--force-enabled] [--] command [arguments...]\n", stderr)
            exit(2)
        }
        let forceBattery = parsed.forceBattery
        let forceEnabled = parsed.forceEnabled
        let arguments = parsed.command
        guard !arguments.isEmpty else {
            fputs("usage: batteryhog-gate [--] command [arguments...]\n", stderr)
            exit(2)
        }

        let dataDirectory = AgentGateEnvironment.dataDirectory()
        let settings = AgentGateSettings.load(from: dataDirectory)
        if !(settings.enabled || forceEnabled) || !(AgentGateEnvironment.onBattery() || forceBattery) {
            executeReplacingSelf(arguments)
        }

        let trackedProcessGroup = establishTrackedProcessGroup()

        let store = AgentGateStore(dataDirectory: dataDirectory)
        let wrapperPID = getpid()
        let now = Int(Date().timeIntervalSince1970)
        let entryID = "\(wrapperPID)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let cwd = FileManager.default.currentDirectoryPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let displayCWD = cwd.hasPrefix(home) ? "~" + String(cwd.dropFirst(home.count)) : cwd
        let entry: [String: Any] = [
            "id": entryID, "pid": Int(wrapperPID), "child_pid": NSNull(),
            "pid_identity": AgentGateStore.processIdentity(wrapperPID) as Any? ?? NSNull(),
            "child_identity": NSNull(),
            "state": "queued", "label": commandLabel(arguments),
            "project": URL(fileURLWithPath: cwd).lastPathComponent.isEmpty
                ? "Development" : URL(fileURLWithPath: cwd).lastPathComponent,
            "cwd": displayCWD, "requested_at": now, "started_at": NSNull()
        ]
        var announced = false
        var trackingAvailable = true
        while true {
            do {
                let admission = try store.admission(for: entry, slots: settings.slots)
                if admission.admitted { break }
                if !announced {
                    fputs("Battery Hog: queued \(commandLabel(arguments)) (position \(admission.position), \(admission.active)/\(settings.slots) active)\n", stderr)
                    fflush(stderr)
                    announced = true
                }
            } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain && error.code == Int(EBUSY) {
                if !announced {
                    fputs("Battery Hog: waiting for an earlier gate process to finish updating.\n",
                          stderr)
                    fflush(stderr)
                    announced = true
                }
            } catch {
                fputs("Battery Hog: gate registry unavailable; running command without queueing.\n", stderr)
                trackingAvailable = false
                break
            }
            Thread.sleep(forTimeInterval: 0.75)
        }

        let prepared = prepare(arguments, workerLimit: settings.workers)
        fputs("Battery Hog: running \(commandLabel(arguments)) with \(settings.workers) worker\(settings.workers == 1 ? "" : "s")\n", stderr)
        fflush(stderr)

        // Replace the gate process with the command after registering its exact
        // PID/start identity. Keeping one process avoids terminal job-control and
        // signal-forwarding bugs: stdin, Ctrl-C, Ctrl-Z, and SIGTERM reach the
        // real command directly and exactly once.
        if trackingAvailable {
            guard store.registerChild(entryID: entryID, childPID: wrapperPID,
                                      childProcessGroup: trackedProcessGroup,
                                      workerLimit: settings.workers,
                                      slotLimit: settings.slots) else {
                store.remove(wrapperPID: wrapperPID)
                fputs("Battery Hog: could not register the tracked command; refusing to run untracked.\n",
                      stderr)
                exit(75)
            }
        }
        executeReplacingSelf(prepared.command, environment: prepared.environment) {
            if trackingAvailable { store.remove(wrapperPID: wrapperPID) }
        }
    }

    private static func establishTrackedProcessGroup() -> Int32? {
        let pid = getpid()
        if isatty(STDIN_FILENO) != 0 {
            let group = getpgrp()
            return group == pid && tcgetpgrp(STDIN_FILENO) == group ? group : nil
        }
        if getpgrp() == pid || setpgid(0, 0) == 0 { return getpgrp() }
        return nil
    }

    private static func parseWrapperArguments(_ raw: [String])
        -> (forceBattery: Bool, forceEnabled: Bool, command: [String])? {
        var forceBattery = false
        var forceEnabled = false
        var index = 0
        while index < raw.count {
            let value = raw[index]
            if value == "--" {
                return (forceBattery, forceEnabled, Array(raw.dropFirst(index + 1)))
            }
            if value == "--force-battery" { forceBattery = true; index += 1; continue }
            if value == "--force-enabled" { forceEnabled = true; index += 1; continue }
            if value.hasPrefix("--") { return nil }
            return (forceBattery, forceEnabled, Array(raw.dropFirst(index)))
        }
        return (forceBattery, forceEnabled, [])
    }

    private static func executeReplacingSelf(_ command: [String],
                                             environment: [String: String]? = nil,
                                             onFailure: (() -> Void)? = nil) -> Never {
        if let environment {
            for (name, value) in environment where setenv(name, value, 1) != 0 {
                onFailure?()
                fputs("Battery Hog: could not prepare the command environment: \(String(cString: strerror(errno)))\n",
                      stderr)
                exit(127)
            }
        }
        var pointers = command.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        pointers.withUnsafeMutableBufferPointer { buffer in
            guard let executable = buffer[0], let base = buffer.baseAddress else { return }
            execvp(executable, base)
        }
        onFailure?()
        fputs("Battery Hog: could not launch \(command.first ?? "command"): \(String(cString: strerror(errno)))\n", stderr)
        exit(127)
    }

    private static func commandLabel(_ command: [String]) -> String {
        guard let first = command.first else { return "command" }
        let base = URL(fileURLWithPath: first).lastPathComponent.isEmpty ? first
            : URL(fileURLWithPath: first).lastPathComponent
        let second = command.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? ""
        return String((base + (second.isEmpty ? "" : " " + second)).prefix(80))
    }

    private static func prepare(_ command: [String], workerLimit: Int)
        -> (command: [String], environment: [String: String]) {
        var command = command
        var environment = ProcessInfo.processInfo.environment
        let workers = String(max(1, workerLimit))
        if environment["BATTERY_HOG_GATED"] == nil { environment["BATTERY_HOG_GATED"] = "1" }
        if environment["CARGO_BUILD_JOBS"] == nil { environment["CARGO_BUILD_JOBS"] = workers }
        if environment["RAYON_NUM_THREADS"] == nil { environment["RAYON_NUM_THREADS"] = workers }
        if environment["GOMAXPROCS"] == nil { environment["GOMAXPROCS"] = workers }
        if let first = command.first {
            let base = URL(fileURLWithPath: first).lastPathComponent
            if ["gradle", "gradlew"].contains(base),
               !command.contains(where: { $0.hasPrefix("--max-workers") }) {
                command.append("--max-workers=\(workers)")
            }
        }
        return (command, environment)
    }
}
