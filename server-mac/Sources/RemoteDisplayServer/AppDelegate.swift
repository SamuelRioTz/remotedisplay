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
        // App de barra de menú: sin ícono en el Dock mientras no haya ventana.
        NSApp.setActivationPolicy(.accessory)
        controller.start()
        // Primer uso / falta setup → abrir la ventana de configuración sola.
        if !controller.isReady || !controller.passwordSet {
            showMainWindow()
        }
    }

    // Doble click en la app (Finder) o click en el Dock → ventana principal.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // Cerrar la ventana NO cierra la app: sigue en la barra de menú.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // El motor corre como LaunchAgent independiente: al cerrar la app sigue
    // corriendo en segundo plano (para eso está "Service Active" / login item).

    // MARK: - Ventana principal (única)

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
        // Con ventana visible la app se comporta como app normal (Dock, ⌘Tab).
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        // Volver a ser solo un ícono de la barra de menú.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
