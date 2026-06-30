import Cocoa
import WebKit

final class IconSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(NSError(domain:"i",code:1)); return }
        var path = ""
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let p = c.queryItems?.first(where: { $0.name == "p" })?.value { path = p }
        let icon = NSWorkspace.shared.icon(forFile: path)
        let out = NSImage(size: NSSize(width: 64, height: 64))
        out.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .copy, fraction: 1.0)
        out.unlockFocus()
        let data = (out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                    .representation(using: .png, properties: [:])) ?? Data()
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "image/png"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// Offscreen WebKit snapshot: swift snap.swift <file.html> <out.png> [w] [h]
let a = CommandLine.arguments
let fileURL = URL(fileURLWithPath: a[1])
let outPath = a[2]
let W = a.count > 3 ? Int(a[3]) ?? 1060 : 1060
let H = a.count > 4 ? Int(a[4]) ?? 1000 : 1000

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Snapper: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: String
    init(_ web: WKWebView, _ out: String) { self.web = web; self.out = out }
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let cfg = WKSnapshotConfiguration()
            w.takeSnapshot(with: cfg) { img, err in
                if let img = img, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: self.out))
                    print("wrote \(self.out)")
                } else {
                    print("snapshot failed: \(String(describing: err))")
                }
                exit(0)
            }
        }
    }
}

let frame = NSRect(x: 0, y: 0, width: W, height: H)
let _cfg = WKWebViewConfiguration()
_cfg.setURLSchemeHandler(IconSchemeHandler(), forURLScheme: "appicon")
let web = WKWebView(frame: frame, configuration: _cfg)
let isDark = a.contains("dark")
if isDark {
    let dark = NSAppearance(named: .darkAqua)
    web.appearance = dark
    NSApp.appearance = dark
}
// Mimic the app: transparent webview over a vibrancy-toned backing so the
// transparent sidebar shows the backdrop (not a white webview default).
web.setValue(false, forKey: "drawsBackground")
let backing = NSView(frame: frame)
backing.wantsLayer = true
backing.layer?.backgroundColor = (isDark ? NSColor(white: 0.16, alpha: 1)
                                          : NSColor(white: 0.93, alpha: 1)).cgColor
web.autoresizingMask = [.width, .height]
backing.addSubview(web)
let snap = Snapper(web, outPath)
web.navigationDelegate = snap

let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // offscreen, no flash
win.contentView = backing
win.orderFrontRegardless()

web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())

// hard timeout safety net
DispatchQueue.main.asyncAfter(deadline: .now() + 9) { print("timeout"); exit(2) }
app.run()
