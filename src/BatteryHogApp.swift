import Cocoa
import Sparkle
import UserNotifications
import WebKit

// Native shell for Battery Hog:
//  • a window with a WKWebView showing the dashboard,
//  • a menu-bar (status) item with the current top battery user + quick actions,
//  • runs the bundled Python backend (battery_hog.py) as a child process.

func findFreePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return 8765 }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bound != 0 { return 8765 }
    var info = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    if got != 0 { return 8765 }
    return Int(UInt16(bigEndian: info.sin_port))
}

// Serves real macOS app icons to the web layer via  appicon://i?p=<bundle-path>
// NSWorkspace resolves icons for both .icns and asset-catalog apps.
final class IconSchemeHandler: NSObject, WKURLSchemeHandler {
    private var cache = [String: Data]()
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(NSError(domain: "icon", code: 1)); return }
        var path = ""
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let p = c.queryItems?.first(where: { $0.name == "p" })?.value { path = p }
        let data = png(for: path)
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "image/png",
                                                  "Cache-Control": "max-age=3600"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func png(for path: String) -> Data {
        if let c = cache[path] { return c }
        let icon = NSWorkspace.shared.icon(forFile: path)   // returns a generic icon if path is missing
        let side: CGFloat = 64
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .copy, fraction: 1.0)
        out.unlockFocus()
        let data = (out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:])) ?? Data()
        cache[path] = data
        return data
    }
}

// Sparkle is intentionally isolated from the monitoring backend. It owns its
// automatic-check preference in UserDefaults, while the dashboard talks to it
// through a small native bridge. Homebrew-installed copies never start Sparkle.
final class UpdateCoordinator: NSObject, SPUUpdaterDelegate {
    static let homebrewCommand = "brew upgrade --cask luke-fairbanks/tap/battery-hog"

    private weak var webView: WKWebView?
    private let installMethod: String
    private var updaterController: SPUStandardUpdaterController?
    private var status = "idle"
    private var latestVersion: String?
    private var lastChecked: Date?
    private var message: String?
    private var errorMessage: String?

    override init() {
        installMethod = Self.detectInstallMethod(bundleURL: Bundle.main.bundleURL)
        super.init()
        if installMethod == "direct" {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        } else {
            status = "homebrew"
        }
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        pushState()
    }

    static func detectInstallMethod(bundleURL: URL,
                                    fileManager: FileManager = .default) -> String {
        // Preview-only override makes both states visually testable without
        // weakening production detection.
        let isPreview = Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true
        if isPreview,
           let override = ProcessInfo.processInfo.environment["BATTERY_HOG_DEBUG_INSTALL_METHOD"],
           ["direct", "homebrew"].contains(override) {
            return override
        }

        let installedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let caskRoots = [
            URL(fileURLWithPath: "/opt/homebrew/Caskroom/battery-hog", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/Caskroom/battery-hog", isDirectory: true)
        ]
        for caskRoot in caskRoots {
            guard let versions = try? fileManager.contentsOfDirectory(
                at: caskRoot, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for version in versions {
                let caskApp = version.appendingPathComponent(bundleURL.lastPathComponent,
                                                              isDirectory: true)
                guard fileManager.fileExists(atPath: caskApp.path) else { continue }
                if caskApp.resolvingSymlinksInPath().standardizedFileURL == installedBundle {
                    return "homebrew"
                }
            }
        }
        return "direct"
    }

    func checkForUpdates() {
        guard installMethod == "direct", let controller = updaterController else {
            showHomebrewInstructions()
            return
        }
        if latestVersion == nil {
            status = "checking"
            message = nil
            errorMessage = nil
            pushState()
        }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard installMethod == "direct", let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        message = enabled ? "Automatic update checks are on." : "Automatic update checks are off."
        errorMessage = nil
        pushState()
    }

    func copyHomebrewCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.homebrewCommand, forType: .string)
        message = "Homebrew upgrade command copied."
        errorMessage = nil
        pushState()
    }

    func showHomebrewInstructions() {
        let alert = NSAlert()
        alert.messageText = "Updates are managed by Homebrew"
        alert.informativeText = "Run this command in Terminal to update Battery Hog:\n\n\(Self.homebrewCommand)"
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn { copyHomebrewCommand() }
    }

    func pushState() {
        guard let webView else { return }
        let updater = updaterController?.updater
        var payload: [String: Any] = [
            "available": true,
            "installMethod": installMethod,
            "currentVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "Unknown",
            "automaticChecks": installMethod == "direct"
                ? (updater?.automaticallyChecksForUpdates ?? false) : false,
            "canCheck": installMethod == "direct" ? (updater?.canCheckForUpdates ?? false) : false,
            "status": status,
            "checking": status == "checking",
            "updateAvailable": latestVersion != nil,
            "homebrewCommand": Self.homebrewCommand,
            // This payload is authoritative. Explicit nulls prevent the web
            // view from retaining details from an earlier updater state.
            "latestVersion": NSNull(),
            "lastChecked": NSNull(),
            "message": NSNull(),
            "error": NSNull()
        ]
        if let latestVersion { payload["latestVersion"] = latestVersion }
        if let lastChecked {
            payload["lastChecked"] = ISO8601DateFormatter().string(from: lastChecked)
        }
        if let message { payload["message"] = message }
        if let errorMessage { payload["error"] = errorMessage }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.batteryHogUpdatesDidChange && window.batteryHogUpdatesDidChange(\(json));",
            completionHandler: nil
        )
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "updateAvailable"
        latestVersion = item.displayVersionString
        lastChecked = Date()
        message = "Version \(item.displayVersionString) is available."
        errorMessage = nil
        pushState()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = "noUpdate"
        latestVersion = nil
        lastChecked = Date()
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        message = detail.isEmpty ? "No update is available for this Mac." : detail
        errorMessage = nil
        pushState()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "no update" through the method above; this callback
        // is reserved for a real feed, network, signature, or install failure.
        let sparkleError = error as NSError
        if sparkleError.domain == SUSparkleErrorDomain,
           sparkleError.code == SUError.noUpdateError.rawValue {
            return
        }
        status = "error"
        latestVersion = nil
        lastChecked = Date()
        message = nil
        errorMessage = error.localizedDescription
        pushState()
    }
}

private struct HeatWorkloadObservation {
    let key: String
    let label: String
    let cpu: Double
    let workers: Int
    let workerNoun: String
}

private struct HeatStatsSample {
    let date: Date
    let processCPU: [String: Double]
    let workloads: [HeatWorkloadObservation]
}

private struct HeatCandidate {
    let key: String
    let label: String
    let averageCPU: Double
    let workers: Int
    let workerNoun: String?
    let isWorkload: Bool
}

private struct HeatAggregate {
    var label: String
    var totalCPU: Double
    var maxWorkers: Int
    var workerNoun: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate,
                         UNUserNotificationCenterDelegate {
    private let heatNotificationCategory = "BATTERY_HOG_HEAT"
    private let heatOpenAction = "BATTERY_HOG_HEAT_OPEN_WORKLOADS"
    private let heatSnoozeAction = "BATTERY_HOG_HEAT_SNOOZE"
    private let heatPermissionRequestedKey = "HeatWatchNotificationPermissionRequested"
    private let heatLastAlertKey = "HeatWatchLastAlertAt"
    private let heatSnoozeUntilKey = "HeatWatchSnoozeUntil"
    private let heatHistoryWindow: TimeInterval = 90
    private let heatCooldown: TimeInterval = 15 * 60

    let iconHandler = IconSchemeHandler()
    var window: NSWindow!
    var webView: WKWebView!
    var py: Process?
    var port = 8765
    var statusItem: NSStatusItem!
    var pollTimer: Timer?
    var lastLowPower: Bool? = nil
    private var statsPollInFlight = false
    private var heatHistory: [HeatStatsSample] = []
    private var currentThermalState: ProcessInfo.ThermalState = .nominal
    private var heatElevatedAt: Date?
    private var heatEpisodeArmed = true
    private var heatEvaluationWorkItem: DispatchWorkItem?
    private var heatAlertsEnabled = false
    private lazy var updateCoordinator = UpdateCoordinator()

    func applicationDidFinishLaunching(_ note: Notification) {
        // Read the initial value before subscribing, as recommended for
        // ProcessInfo state-change notifications: the notification is only a
        // signal to fetch the new value, not a container for the state itself.
        let initialThermalState = ProcessInfo.processInfo.thermalState
        currentThermalState = debugThermalStateOverride() ?? initialThermalState
        configureHeatNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateDidChange(_:)),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        applyThermalState(currentThermalState, at: Date())

        port = findFreePort()
        startServer()
        buildStatusItem()
        buildWindow()
        updateCoordinator.attach(to: webView)
        waitForServer(attempt: 0)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: backend process

    func pythonExecutable() -> String {
        let paths = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/python3"
    }

    func startServer() {
        guard let res = Bundle.main.resourcePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonExecutable())
        p.arguments = [res + "/battery_hog.py", "--port", String(port), "--no-open"]
        p.currentDirectoryURL = URL(fileURLWithPath: res)
        var env = ProcessInfo.processInfo.environment
        let base = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = base + ":" + (env["PATH"] ?? "")
        // Preview builds use a separate bundle identifier and isolated settings,
        // so reviewing a candidate cannot alter the installed release's state.
        if Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true {
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first
            let previewData = support?.appendingPathComponent("BatteryHogPreview").path
                ?? NSTemporaryDirectory() + "BatteryHogPreview"
            env["BATTERY_HOG_DATA_DIR"] = previewData
            env["BATTERY_HOG_PREVIEW"] = "1"
        }
        p.environment = env
        do { try p.run(); py = p } catch { NSLog("Battery Hog: backend failed: \(error)") }
    }

    // MARK: window

    func buildWindow() {
        // Give the dashboard enough room to keep its information hierarchy calm,
        // while still collapsing cleanly on smaller MacBook displays. A new
        // autosave key below prevents a cramped frame saved by the previous shell
        // from being restored over this layout on first launch.
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

        // JS→native bridge so empty areas of the web UI can drag the window.
        // (WKWebView swallows mouse events, so isMovableByWindowBackground and the
        //  CSS -webkit-app-region:drag both do nothing on their own.)
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "drag")
        ucc.add(self, name: "updates")
        let dragJS = """
        document.documentElement.classList.add('native-shell');
        document.addEventListener('mousedown', function(e){
          if (e.button !== 0) return;
          if (!e.target.closest('.page-head,.drag-strip,.brand')) return;   // top title-bar area only
          if (e.target.closest('button,a,input,textarea,select,[role=tab],.switch,.seg,.btn,.link-btn,[data-no-drag]')) return;
          window.webkit.messageHandlers.drag.postMessage(1);
        }, true);
        """
        ucc.addUserScript(WKUserScript(source: dragJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController = ucc
        cfg.setURLSchemeHandler(iconHandler, forURLScheme: "appicon")

        webView = WKWebView(frame: frame, configuration: cfg)
        // The web canvas stays transparent so the native material is visible only
        // where the HTML sidebar is transparent. The HTML content pane paints its
        // own opaque, appearance-aware surface over the rest of the window.
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self                            // so JS confirm()/alert() show native panels

        // Native translucent backdrop. The HTML keeps its sidebar transparent so this
        // vibrancy shows there (the hallmark of a native macOS sidebar); the content
        // pane paints a solid background over the rest.
        let vibrancy = NSVisualEffectView(frame: frame)
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        vibrancy.appearance = nil                           // resolve graphite correctly in light and dark mode
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.addSubview(webView)

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Battery Hog"
        window.appearance = nil                              // inherit the user's Aqua appearance
        window.titlebarAppearsTransparent = true            // content extends under the titlebar
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // WKWebView owns pointer handling. Keep dragging limited to the explicit
        // page-head / drag-strip / brand bridge above so controls never become
        // accidental titlebar drag targets.
        window.isMovableByWindowBackground = false
        window.isOpaque = false                              // let the vibrancy show the real desktop
        window.backgroundColor = .clear
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 920, height: 620)
        window.contentView = vibrancy
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BatteryHogCurrentWindow1")
        window.makeKeyAndOrderFront(nil)
    }

    func waitForServer(attempt: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                if let h = resp as? HTTPURLResponse, h.statusCode == 200 {
                    self.webView.load(URLRequest(url: url))
                    self.startStatsPolling()
                } else if attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.waitForServer(attempt: attempt + 1)
                    }
                } else {
                    self.webView.loadHTMLString(
                        """
                        <meta name='color-scheme' content='light dark'>
                        <style>
                          :root { color-scheme: light dark; }
                          body { margin:0; padding:40px; font-family:-apple-system;
                                 background:Canvas; color:CanvasText; }
                          p { color:color-mix(in srgb, CanvasText 65%, transparent); }
                        </style>
                        <h2>Couldn't start the battery monitor.</h2>
                        <p>Make sure python3 is available, then reopen Battery Hog.</p>
                        """,
                        baseURL: nil)
                }
            }
        }.resume()
    }

    // MARK: menu-bar status item

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Battery Hog")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func startStatsPolling() {
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: true) { [weak self] _ in
                self?.pollStats()
            }
        }
        pollStats()
    }

    func pollStats() {
        guard !statsPollInFlight else { return }
        statsPollInFlight = true
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/stats") else {
            statsPollInFlight = false
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let obj = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            DispatchQueue.main.async {
                self.statsPollInFlight = false
                if let obj = obj { self.applyStats(obj) }
            }
        }.resume()
    }

    func applyStats(_ obj: [String: Any]) {
        let procs = obj["processes"] as? [[String: Any]] ?? []
        let workloads = obj["workloads"] as? [[String: Any]] ?? []
        lastLowPower = obj["lowpower"] as? Bool
        let battery = obj["battery"] as? [String: Any] ?? [:]
        let power = obj["power"] as? [String: Any] ?? [:]
        let dev = obj["dev_summary"] as? [String: Any] ?? [:]
        let pct = battery["percent"] as? Int
        let watts = power["watts"] as? Double
        let direction = power["direction"] as? String ?? ""
        let onAC = (battery["on_ac"] as? Bool) ?? false
        let timeStr = battery["time"] as? String

        // status-bar title: user-configurable via Settings ▸ Menu bar
        let settings = obj["settings"] as? [String: Any] ?? [:]
        let heat = settings["heat"] as? [String: Any] ?? [:]
        recordHeatStats(processes: procs, workloads: workloads, at: Date())
        updateHeatAlertsEnabled((heat["enabled"] as? Bool) ?? false)
        evaluateHeatEpisode(at: Date())
        let mb = settings["menubar"] as? [String: Any] ?? [:]
        func mbOn(_ k: String, _ def: Bool) -> Bool { (mb[k] as? Bool) ?? def }
        var titleParts: [String] = []
        if mbOn("percent", true), let pct = pct { titleParts.append("\(pct)%") }
        if mbOn("watts", true), let w = watts, direction != "ac" {
            titleParts.append("\(Int(w.rounded()))W")
        }
        if mbOn("time", false), let t = timeStr, direction == "charging" || direction == "discharging" {
            titleParts.append(t)
        }
        if mbOn("hog", false), let top = procs.first, let name = top["name"] as? String {
            var short = name
            if short.count > 12 { short = String(short.prefix(11)) + "…" }
            let cpu = Int((top["cpu"] as? Double) ?? 0)
            titleParts.append("\(short) \(cpu)%")
        }
        if mbOn("dev", false) {
            let projects = dev["projects"] as? Int ?? 0
            let heavy = dev["heavy_workers"] as? Int ?? 0
            if projects > 0 { titleParts.append("\(heavy) jobs · \(projects) dev") }
        }
        statusItem.button?.title = titleParts.isEmpty ? "" : " " + titleParts.joined(separator: " · ")

        // rebuild the menu
        let menu = NSMenu()

        // battery summary line
        var parts: [String] = []
        if let pct = pct { parts.append("\(pct)%") }
        parts.append(onAC ? (direction == "charging" ? "Charging" : "Plugged in") : "On battery")
        if let w = watts { parts.append(String(format: "%.1f W", w)) }
        if let t = timeStr, direction == "charging" || direction == "discharging" {
            parts.append(t + (direction == "charging" ? " to full" : " left"))
        }
        let summary = NSMenuItem(title: parts.joined(separator: "  ·  "), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let hdr = NSMenuItem(title: "Top battery users", action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        menu.addItem(hdr)

        for p in procs.prefix(6) {
            guard let name = p["name"] as? String else { continue }
            let cpu = Int((p["cpu"] as? Double) ?? 0)
            let memMB = (p["mem_mb"] as? Double) ?? 0
            let memStr = memMB >= 1024 ? String(format: "%.1f GB", memMB / 1024) : "\(Int(memMB)) MB"
            let protectedFlag = (p["protected"] as? Bool) ?? false
            let item = NSMenuItem(title: "\(name)   \(cpu)% · \(memStr)", action: nil, keyEquivalent: "")
            if protectedFlag {
                item.isEnabled = false
            } else {
                let sub = NSMenu()
                let q = NSMenuItem(title: "Quit \(name)", action: #selector(quitProcess(_:)), keyEquivalent: "")
                q.target = self
                q.representedObject = ["name": name,
                                       "bundle": (p["bundle"] as? Bool) ?? false,
                                       "pids": p["pids"] ?? []]
                sub.addItem(q)
                item.submenu = sub
            }
            menu.addItem(item)
        }

        let projects = dev["projects"] as? Int ?? 0
        if projects > 0 {
            menu.addItem(.separator())
            let workers = dev["active_workers"] as? Int ?? 0
            let heavy = dev["heavy_workers"] as? Int ?? 0
            let item = NSMenuItem(title: "Development   \(projects) projects · \(workers) active · \(heavy) heavy",
                                  action: #selector(showWorkloads(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let lpm = NSMenuItem(title: "Low Power Mode", action: #selector(toggleLPM(_:)), keyEquivalent: "")
        lpm.target = self
        lpm.state = (lastLowPower == true) ? .on : .off
        if lastLowPower == nil { lpm.isEnabled = false }
        menu.addItem(lpm)

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Open Dashboard", action: #selector(showDashboard(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(NSMenuItem(title: "Quit Battery Hog",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func quitProcess(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: Any],
              let name = d["name"] as? String else { return }
        let a = NSAlert()
        a.messageText = "Quit \(name)?"
        a.informativeText = "It will be asked to close — save your work first."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            backendPOST("/api/kill", ["name": name,
                                      "bundle": d["bundle"] ?? false,
                                      "pids": d["pids"] ?? []])
        }
    }

    @objc func toggleLPM(_ sender: NSMenuItem) {
        let turnOn = !(lastLowPower ?? false)
        backendPOST("/api/lowpower", ["on": turnOn])
    }

    @objc func showDashboard(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showWorkloads(_ sender: Any?) {
        showDashboard(sender)
        webView.evaluateJavaScript("go('workloads')", completionHandler: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateCoordinator.checkForUpdates()
    }

    // MARK: Heat Watch

    private func configureHeatNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: heatOpenAction,
                                        title: "Open Workloads", options: [.foreground])
        let snooze = UNNotificationAction(identifier: heatSnoozeAction,
                                          title: "Snooze 1 hour", options: [])
        let category = UNNotificationCategory(identifier: heatNotificationCategory,
                                              actions: [open, snooze],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    private var isPreviewBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true
    }

    /// Preview-only deterministic hooks for testing without heating a Mac:
    ///   BATTERY_HOG_DEBUG_THERMAL_STATE=fair|serious|critical
    ///   BATTERY_HOG_DEBUG_HEAT_ENABLED=1
    ///   BATTERY_HOG_DEBUG_HEAT_DELAY_SECONDS=0
    ///   BATTERY_HOG_DEBUG_HEAT_DRY_RUN=1 (logs the notification, does not post it)
    /// They are deliberately ignored by release-bundle identifiers.
    private func debugEnvironment(_ key: String) -> String? {
        guard isPreviewBuild else { return nil }
        return ProcessInfo.processInfo.environment[key]
    }

    private func debugThermalStateOverride() -> ProcessInfo.ThermalState? {
        switch debugEnvironment("BATTERY_HOG_DEBUG_THERMAL_STATE")?.lowercased() {
        case "nominal": return .nominal
        case "fair": return .fair
        case "serious": return .serious
        case "critical": return .critical
        default: return nil
        }
    }

    private var heatSustainDelay: TimeInterval {
        guard let raw = debugEnvironment("BATTERY_HOG_DEBUG_HEAT_DELAY_SECONDS"),
              let delay = Double(raw) else { return 10 }
        return max(0, delay)
    }

    private var heatDebugDryRun: Bool {
        debugEnvironment("BATTERY_HOG_DEBUG_HEAT_DRY_RUN") == "1"
    }

    private func updateHeatAlertsEnabled(_ settingEnabled: Bool) {
        let enabled = settingEnabled || debugEnvironment("BATTERY_HOG_DEBUG_HEAT_ENABLED") == "1"
        let becameEnabled = enabled && !heatAlertsEnabled
        heatAlertsEnabled = enabled
        if becameEnabled {
            requestHeatNotificationPermissionIfNeeded()
            scheduleHeatEvaluationIfNeeded(at: Date())
            evaluateHeatEpisode(at: Date())
        }
    }

    private func requestHeatNotificationPermissionIfNeeded() {
        // A dry run intentionally avoids a system prompt; all normal enabled
        // Heat Watch sessions request permission exactly once per bundle.
        if heatDebugDryRun { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: heatPermissionRequestedKey) else { return }
        defaults.set(true, forKey: heatPermissionRequestedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, error in
            if let error = error {
                NSLog("Battery Hog Heat Watch: notification permission failed: \(error)")
            } else if !granted {
                NSLog("Battery Hog Heat Watch: notification permission was not granted")
            }
        }
    }

    @objc private func thermalStateDidChange(_ notification: Notification) {
        let state = debugThermalStateOverride() ?? ProcessInfo.processInfo.thermalState
        DispatchQueue.main.async { [weak self] in
            self?.applyThermalState(state, at: Date())
        }
    }

    private func applyThermalState(_ state: ProcessInfo.ThermalState, at now: Date) {
        currentThermalState = state
        if state == .nominal {
            heatElevatedAt = nil
            heatEpisodeArmed = true
            heatEvaluationWorkItem?.cancel()
            heatEvaluationWorkItem = nil
            return
        }
        if heatElevatedAt == nil {
            heatElevatedAt = now
        }
        scheduleHeatEvaluationIfNeeded(at: now)
    }

    private func scheduleHeatEvaluationIfNeeded(at now: Date) {
        guard currentThermalState != .nominal,
              heatEpisodeArmed,
              let elevatedAt = heatElevatedAt else { return }
        heatEvaluationWorkItem?.cancel()
        let remaining = max(0, heatSustainDelay - now.timeIntervalSince(elevatedAt))
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateHeatEpisode(at: Date())
        }
        heatEvaluationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
    }

    private func evaluateHeatEpisode(at now: Date) {
        guard heatAlertsEnabled,
              currentThermalState != .nominal,
              heatEpisodeArmed,
              let elevatedAt = heatElevatedAt else { return }
        let elapsed = now.timeIntervalSince(elevatedAt)
        guard elapsed >= heatSustainDelay else {
            scheduleHeatEvaluationIfNeeded(at: now)
            return
        }

        // One evaluation per elevated-temperature episode. Cool/nominal is the
        // only condition that re-arms it, including when cooldown or snooze wins.
        heatEpisodeArmed = false
        heatEvaluationWorkItem?.cancel()
        heatEvaluationWorkItem = nil

        let defaults = UserDefaults.standard
        let snoozeUntil = defaults.double(forKey: heatSnoozeUntilKey)
        if snoozeUntil > now.timeIntervalSince1970 { return }
        let lastAlert = defaults.double(forKey: heatLastAlertKey)
        if lastAlert > 0 && now.timeIntervalSince1970 - lastAlert < heatCooldown { return }

        let body = heatNotificationBody(at: now)
        defaults.set(now.timeIntervalSince1970, forKey: heatLastAlertKey)
        postHeatNotification(body: body, at: now)
    }

    private func recordHeatStats(processes: [[String: Any]], workloads: [[String: Any]], at now: Date) {
        var processCPU: [String: Double] = [:]
        for process in processes {
            // System/protected helpers are not actionable explanations and can
            // include Battery Hog's own short-lived sampling commands.
            if (process["protected"] as? Bool) == true { continue }
            guard let name = process["name"] as? String, !name.isEmpty else { continue }
            let cpu = (process["cpu"] as? NSNumber)?.doubleValue ?? 0
            if cpu > 0 { processCPU[name, default: 0] += cpu }
        }

        var workloadObservations: [HeatWorkloadObservation] = []
        for (index, workload) in workloads.enumerated() {
            let cpu = (workload["cpu"] as? NSNumber)?.doubleValue ?? 0
            guard cpu > 0 else { continue }
            let project = (workload["name"] as? String) ?? "Development"
            let key = (workload["id"] as? String) ?? "workload-\(index)-\(project)"
            let tools = workload["tools"] as? [[String: Any]] ?? []
            let families = workload["families"] as? [String] ?? []
            let agents = workload["agents"] as? [String] ?? []
            let tool = tools.first?["name"] as? String
            let label = heatWorkloadLabel(project: project, agent: agents.first,
                                          tool: tool, families: families)
            let activeWorkers = (workload["active_workers"] as? NSNumber)?.intValue ?? 0
            let workers = activeWorkers > 0
                ? activeWorkers
                : ((workload["workers"] as? NSNumber)?.intValue ?? 0)
            let status = (workload["status"] as? String) ?? "Active"
            workloadObservations.append(HeatWorkloadObservation(
                key: key, label: label, cpu: cpu, workers: workers,
                workerNoun: heatWorkerNoun(for: status)
            ))
        }

        heatHistory.append(HeatStatsSample(date: now, processCPU: processCPU,
                                           workloads: workloadObservations))
        let cutoff = now.addingTimeInterval(-heatHistoryWindow)
        heatHistory.removeAll { $0.date < cutoff }
    }

    private func heatWorkloadLabel(project: String, agent: String?, tool: String?,
                                   families: [String]) -> String {
        // When an agent/editor is the ancestor of the workers, it is the most
        // recognizable and actionable attribution for the person using the Mac.
        if let agent = agent, !agent.isEmpty { return agent }
        if let tool = tool, !tool.isEmpty {
            let genericTools = ["Node", "Node task", "Java", "Native build", "Development"]
            if !genericTools.contains(tool) { return tool }
        }
        if let family = families.first, !family.isEmpty {
            return "\(project) \(family) workload"
        }
        return "\(project) development workload"
    }

    private func normalizedHeatContributorName(_ label: String) -> String {
        let compact = label.lowercased().filter { $0.isLetter || $0.isNumber }
        if compact.contains("visualstudiocode") || compact.contains("vscode") ||
            compact.contains("codehelper") { return "vscode" }
        if compact.contains("codex") { return "codex" }
        if compact.contains("cursor") { return "cursor" }
        if compact.contains("claude") { return "claude" }
        if compact.contains("xcode") { return "xcode" }
        return compact
    }

    private func heatWorkerNoun(for status: String) -> String {
        switch status.lowercased() {
        case "compiling": return "compiler workers"
        case "building": return "build workers"
        case "testing": return "test workers"
        case "serving": return "dev-server workers"
        case "scanning": return "scan workers"
        case "installing": return "install workers"
        default: return "development workers"
        }
    }

    private func heatCandidates(at now: Date) -> [HeatCandidate] {
        let cutoff = now.addingTimeInterval(-heatHistoryWindow)
        let samples = heatHistory.filter { $0.date >= cutoff }
        guard !samples.isEmpty else { return [] }

        var processTotals: [String: Double] = [:]
        var workloadTotals: [String: HeatAggregate] = [:]
        for sample in samples {
            for (name, cpu) in sample.processCPU {
                processTotals[name, default: 0] += cpu
            }
            for workload in sample.workloads {
                var aggregate = workloadTotals[workload.key] ?? HeatAggregate(
                    label: workload.label, totalCPU: 0, maxWorkers: 0,
                    workerNoun: workload.workerNoun
                )
                aggregate.label = workload.label
                aggregate.totalCPU += workload.cpu
                aggregate.maxWorkers = max(aggregate.maxWorkers, workload.workers)
                aggregate.workerNoun = workload.workerNoun
                workloadTotals[workload.key] = aggregate
            }
        }

        let divisor = Double(samples.count)
        var candidates = workloadTotals.map { key, value in
            HeatCandidate(key: "workload:\(key)", label: value.label,
                          averageCPU: value.totalCPU / divisor,
                          workers: value.maxWorkers, workerNoun: value.workerNoun,
                          isWorkload: true)
        }

        // Workload discovery already includes these executables. Avoid counting
        // a compiler once as a project workload and again as a raw process.
        let devExecutables = Set([
            "swift", "swiftc", "swift-frontend", "xcodebuild", "rustc", "cargo",
            "sccache", "gradle", "gradlew", "java", "kotlinc", "go", "pytest",
            "jest", "vitest", "playwright", "cypress", "tsc", "esbuild", "webpack",
            "rollup", "turbo", "npm", "pnpm", "yarn", "bun", "npx", "node",
            "make", "cmake", "ninja"
        ])
        let hasWorkloads = !workloadTotals.isEmpty
        for (name, total) in processTotals {
            let normalized = name.lowercased()
            if normalized.contains("battery_hog") || normalized == "battery hog" { continue }
            if hasWorkloads && devExecutables.contains(normalized) { continue }
            candidates.append(HeatCandidate(key: "process:\(name)", label: name,
                                            averageCPU: total / divisor, workers: 0,
                                            workerNoun: nil, isWorkload: false))
        }
        return candidates.filter { $0.averageCPU >= 1 }
            .sorted { left, right in
                if left.averageCPU == right.averageCPU { return left.isWorkload && !right.isWorkload }
                return left.averageCPU > right.averageCPU
            }
    }

    private func heatNotificationBody(at now: Date) -> String {
        let candidates = heatCandidates(at: now)
        guard let top = candidates.first else {
            return "Thermal pressure has stayed elevated. Open Workloads to see what is active."
        }

        let topCPU = Int(top.averageCPU.rounded())
        var body = "Likely \(top.label)"
        if let workerNoun = top.workerNoun, top.workers > 0 {
            body += ": \(top.workers) \(workerNoun) averaging \(topCPU)% CPU."
        } else {
            body += ", averaging \(topCPU)% CPU."
        }
        let normalizedTop = normalizedHeatContributorName(top.label)
        if let second = candidates.dropFirst().first(where: {
            $0.averageCPU >= 15 && $0.averageCPU >= top.averageCPU * 0.15
                && normalizedHeatContributorName($0.label) != normalizedTop
        }) {
            body += " \(second.label) is also contributing at \(Int(second.averageCPU.rounded()))% CPU."
        }
        return body
    }

    private func postHeatNotification(body: String, at now: Date) {
        if heatDebugDryRun {
            NSLog("%@", "Battery Hog Heat Watch dry run — Your Mac is heating up — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Your Mac is heating up"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = heatNotificationCategory
        let request = UNNotificationRequest(
            identifier: "battery-hog-heat-\(Int(now.timeIntervalSince1970))",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Battery Hog Heat Watch: notification failed: \(error)")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case heatOpenAction, UNNotificationDefaultActionIdentifier:
            DispatchQueue.main.async { [weak self] in self?.showWorkloads(nil) }
        case heatSnoozeAction:
            UserDefaults.standard.set(Date().addingTimeInterval(60 * 60).timeIntervalSince1970,
                                      forKey: heatSnoozeUntilKey)
        default:
            break
        }
        completionHandler()
    }

    func backendPOST(_ path: String, _ body: [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.pollStats() }
        }.resume()
    }

    // MARK: lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showDashboard(nil) }
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        NotificationCenter.default.removeObserver(self,
                                                  name: ProcessInfo.thermalStateDidChangeNotification,
                                                  object: nil)
        heatEvaluationWorkItem?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "updates")
        py?.terminate()
    }

    // Drag the window when the web layer reports a mousedown on an empty region.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "drag", let event = NSApp.currentEvent {
            window.performDrag(with: event)
            return
        }
        guard message.name == "updates",
              message.frameInfo.isMainFrame,
              webView.url?.host == "127.0.0.1",
              webView.url?.port == port,
              let payload = message.body as? [String: Any],
              let action = payload["action"] as? String else { return }
        switch action {
        case "getState":
            updateCoordinator.pushState()
        case "check":
            updateCoordinator.checkForUpdates()
        case "setAutomaticChecks":
            if let enabled = payload["enabled"] as? Bool {
                updateCoordinator.setAutomaticChecks(enabled)
            }
        case "copyHomebrewCommand":
            updateCoordinator.copyHomebrewCommand()
        default:
            break
        }
    }

    // WKWebView suppresses JS dialogs unless these are implemented — without them
    // confirm() returns false and the Quit / Low Power Mode actions never fire.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Battery Hog"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let w = window { alert.beginSheetModal(for: w) { _ in completionHandler() } }
        else { alert.runModal(); completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Battery Hog"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let w = window {
            alert.beginSheetModal(for: w) { resp in completionHandler(resp == .alertFirstButtonReturn) }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate

let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
let updateItem = NSMenuItem(title: "Check for Updates…",
                            action: #selector(AppDelegate.checkForUpdates(_:)),
                            keyEquivalent: "")
updateItem.target = delegate
appMenu.addItem(updateItem)
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Hide Battery Hog", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit Battery Hog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let winItem = NSMenuItem()
mainMenu.addItem(winItem)
let winMenu = NSMenu(title: "Window")
winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
winItem.submenu = winMenu

app.mainMenu = mainMenu
app.run()
