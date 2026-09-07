import AppKit
import ServiceManagement
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
        // Launched by the user (Finder, Dock, Spotlight, `open`): show the window — that is
        // what opening an app means. Launched as a login item: stay in the menu bar, unless
        // the setup needs attention (no password, a permission missing, an engine that cannot
        // run). "Service not running yet" is not attention: at login the app itself starts it.
        let loginItem = Self.launchedAsLoginItem
        let needsAttention = !controller.passwordSet || !controller.screenOK
            || !controller.accessibilityOK || controller.engineProblem != nil
        controller.trace("launch: loginItem=\(loginItem) needsAttention=\(needsAttention) sinceLogin=\(Self.secondsSinceConsoleLogin.map { Int($0) } ?? -1)s event=\(Self.launchEventDescription)")
        if !loginItem || needsAttention {
            showMainWindow()
        }
    }

    /// Raw launch Apple event, for the log: class/id and the property-data enum, as four-char codes.
    private static var launchEventDescription: String {
        func fourcc(_ v: UInt32) -> String {
            let b = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
            return String(bytes: b, encoding: .macOSRoman) ?? String(v)
        }
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return "none" }
        let prop = e.paramDescriptor(forKeyword: 0x70726474)?.enumCodeValue
        return "\(fourcc(e.eventClass))/\(fourcc(e.eventID)) prop=\(prop.map(fourcc) ?? "-")"
    }

    /// Seconds since the current console (GUI) login, from the utmpx records; nil if unknown.
    private static var secondsSinceConsoleLogin: TimeInterval? {
        var latest = 0
        setutxent()
        defer { endutxent() }
        while let p = getutxent() {
            let e = p.pointee
            guard Int32(e.ut_type) == USER_PROCESS else { continue }
            let line = withUnsafePointer(to: e.ut_line) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
            }
            if line == "console" { latest = max(latest, Int(e.ut_tv.tv_sec)) }
        }
        guard latest > 0 else { return nil }
        return Date().timeIntervalSince1970 - TimeInterval(latest)
    }

    /// Was this launch the automatic one at login? The launch Apple event does not tell on
    /// macOS 26 (a login item and a Finder/`open` launch both arrive as 'oapp' without
    /// keyAELaunchedAsLogInItem — measured in the test VM), so use the clock: Open at Login
    /// enabled and the app starting within 90 s of the console login.
    private static var launchedAsLoginItem: Bool {
        guard SMAppService.mainApp.status == .enabled else { return false }
        guard let t = secondsSinceConsoleLogin else { return false }
        return t < 90
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
    // bundle stays "in use" and cannot be replaced. The service itself stays enabled
    // (next login / next app launch). Synchronous on purpose: there is nothing left to
    // show meanwhile.
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
