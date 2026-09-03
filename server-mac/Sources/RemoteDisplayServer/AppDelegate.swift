import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate?

    let controller = ServerController()
    private var mainWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon while there's no window.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        // First run / setup incomplete → open the configuration window on its own.
        if !controller.isReady || !controller.passwordSet {
            showMainWindow()
        }
    }

    // Double click on the app (Finder) or click on the Dock → main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // Closing the window does NOT close the app: it stays in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The engine runs as an independent LaunchAgent: closing the WINDOW leaves it
    // running in the background (that's what "Service Active" / login item is for).
    // QUITTING the app (⌘Q, menu bar item) stops the engine as well: otherwise the
    // bundle stays "in use" and cannot be replaced, and a connected client would be
    // left with the Mac on a virtual monitor. The engine restores the displays on
    // SIGTERM; the service itself stays enabled (next login / next app launch).
    // Synchronous on purpose: quitting may take the few seconds the engine needs to
    // put the displays back, and there is nothing left to show meanwhile.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.stopEngineForQuit()
        return .terminateNow
    }

    // MARK: - Main window (single instance)

    func showMainWindow() {
        if mainWindow == nil {
            let root = MainWindowView().environment(controller)
            let hosting = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Remote Display Server"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 700))
            w.center()
            w.delegate = self
            mainWindow = w
        }
        // With a visible window the app behaves like a normal app (Dock, ⌘Tab).
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        // Go back to being just a menu bar icon.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
