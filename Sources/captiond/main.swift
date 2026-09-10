import AppKit
import SwiftUI

final class CaptiondDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ note: Notification) {
        let host = NSHostingView(rootView: CaptiondView())
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 170)
        let w = NSWindow(contentRect: host.frame,
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "ADI205 Captions"
        w.contentView = host
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

let delegate = CaptiondDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
