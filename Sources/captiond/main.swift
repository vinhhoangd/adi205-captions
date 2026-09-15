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
        NSApp.mainMenu = Self.menu()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window is a status panel for whoever runs the Mac; the captions go to
    /// every viewer's browser. Quitting when it closed meant closing a small
    /// panel ended the lecture for the whole room — with exit code 0 and no log
    /// line, which made it look like the app had silently died during warm-up.
    /// Closing the panel now hides it. Quit is deliberate: Cmd-Q or the menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { false }

    /// Clicking the Dock icon brings the closed panel back.
    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// An exit must never again be silent.
    func applicationWillTerminate(_ note: Notification) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] quitting — captions stopped for all viewers\n".utf8))
    }

    /// Without a main menu there is no Cmd-Q, so the only way to stop the app
    /// would be to kill it. One item is enough.
    private static func menu() -> NSMenu {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ADI205 Captions",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return bar
    }
}

let delegate = CaptiondDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
