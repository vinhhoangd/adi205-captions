import AppKit
import SwiftUI

// SwiftUI's WindowGroup never materialises for an SPM-built binary, so the
// view that owns the TranslationSession is hosted in an AppKit window we
// create ourselves. Accessory policy keeps it out of the Dock and out of the
// user's way while it runs.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ note: Notification) {
        trace("didFinishLaunching")
        let host = NSHostingView(rootView: BenchView())
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        let w = NSWindow(contentRect: host.frame,
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "ADI205 bench"
        w.contentView = host
        w.orderFrontRegardless()
        window = w
    }
}

if let out = ProcessInfo.processInfo.environment["BENCH_OUT"]
    ?? UserDefaults.standard.string(forKey: "out") {
    freopen(out, "w", stdout)
    freopen(out + ".err", "w", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)
}
trace("app init")

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
