import Cocoa
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

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    let iconHandler = IconSchemeHandler()
    var window: NSWindow!
    var webView: WKWebView!
    var py: Process?
    var port = 8765
    var statusItem: NSStatusItem!
    var pollTimer: Timer?
    var lastLowPower: Bool? = nil

    func applicationDidFinishLaunching(_ note: Notification) {
        port = findFreePort()
        startServer()
        buildStatusItem()
        buildWindow()
        waitForServer(attempt: 0)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: true) { [weak self] _ in
            self?.pollStats()
        }
        pollStats()
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
        p.environment = env
        do { try p.run(); py = p } catch { NSLog("Battery Hog: backend failed: \(error)") }
    }

    // MARK: window

    func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1120, height: 760)

        // JS→native bridge so empty areas of the web UI can drag the window.
        // (WKWebView swallows mouse events, so isMovableByWindowBackground and the
        //  CSS -webkit-app-region:drag both do nothing on their own.)
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "drag")
        let dragJS = """
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
        webView.setValue(false, forKey: "drawsBackground")   // transparent so vibrancy shows through the sidebar
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self                            // so JS confirm()/alert() show native panels

        // Native translucent backdrop. The HTML keeps its sidebar transparent so this
        // vibrancy shows there (the hallmark of a native macOS sidebar); the content
        // pane paints a solid background over the rest.
        let vibrancy = NSVisualEffectView(frame: frame)
        vibrancy.material = .sidebar
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.addSubview(webView)

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Battery Hog"
        window.titlebarAppearsTransparent = true            // content extends under the titlebar
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true            // drag the window from any empty area
        window.isOpaque = false                              // let the vibrancy show the real desktop
        window.backgroundColor = .clear                      // (true translucent "liquid glass" sidebar)
        window.minSize = NSSize(width: 840, height: 560)
        window.contentView = vibrancy
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BatteryHogWindow3")
        window.makeKeyAndOrderFront(nil)
    }

    func waitForServer(attempt: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            DispatchQueue.main.async {
                if let h = resp as? HTTPURLResponse, h.statusCode == 200 {
                    self.webView.load(URLRequest(url: url))
                } else if attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.waitForServer(attempt: attempt + 1)
                    }
                } else {
                    self.webView.loadHTMLString(
                        "<body style='font-family:-apple-system;background:#0e1116;color:#e6e9ef;padding:40px'>"
                        + "<h2>Couldn't start the battery monitor.</h2>"
                        + "<p>Make sure python3 is available, then reopen Battery Hog.</p></body>",
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

    func pollStats() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/stats") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            DispatchQueue.main.async { self.applyStats(obj) }
        }.resume()
    }

    func applyStats(_ obj: [String: Any]) {
        let procs = obj["processes"] as? [[String: Any]] ?? []
        lastLowPower = obj["lowpower"] as? Bool
        let battery = obj["battery"] as? [String: Any] ?? [:]
        let power = obj["power"] as? [String: Any] ?? [:]
        let pct = battery["percent"] as? Int
        let watts = power["watts"] as? Double
        let direction = power["direction"] as? String ?? ""
        let onAC = (battery["on_ac"] as? Bool) ?? false
        let timeStr = battery["time"] as? String

        // status-bar title: user-configurable via Settings ▸ Menu bar
        let settings = obj["settings"] as? [String: Any] ?? [:]
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
        py?.terminate()
    }

    // Drag the window when the web layer reports a mousedown on an empty region.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "drag", let event = NSApp.currentEvent {
            window.performDrag(with: event)
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
