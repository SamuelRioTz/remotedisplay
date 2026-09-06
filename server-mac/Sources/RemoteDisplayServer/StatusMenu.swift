import AppKit
import SwiftUI

/// Menu bar icon menu: ONLY what's needed in the background. The
/// full configuration lives in the main window.
struct StatusMenu: View {
    @Environment(ServerController.self) private var c

    var body: some View {
        Text(c.statusLine)
        if c.serviceRunning, let ip = c.lanIP {
            Text("LAN  \(ip):\(String(ServerController.port))")
        }
        if c.serviceRunning, let ts = c.tailscaleIP {
            Text("Tailscale  \(ts):\(String(ServerController.port))")
        }
        if c.serviceRunning && !c.sessions.isEmpty {
            Text("\(c.sessions.count) active session\(c.sessions.count == 1 ? "" : "s")")
        }
        Divider()
        Button("Open Remote Display Server…") { AppDelegate.shared?.showMainWindow() }
            .keyboardShortcut("o")
        Divider()
        Toggle("Service Active", isOn: Binding(
            get: { c.serviceRunning }, set: { c.setServiceEnabled($0) }))
        if c.serviceRunning {
            // Monitors are configured here, on the Mac, and reset when the service stops.
            Toggle(c.displayBusy ? "Virtual monitor…" : "Virtual monitor", isOn: Binding(
                get: { c.virtualMonitorOn }, set: { c.setVirtualMonitor($0) }))
                .disabled(c.displayBusy)
            Toggle(c.displayBusy ? "Main screen follows remote…" : "Main screen follows remote", isOn: Binding(
                get: { c.dynamicMainOn }, set: { c.setDynamicMain($0) }))
                .disabled(c.displayBusy)
        }
        Toggle("Open at Login", isOn: Binding(
            get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit Remote Display Server") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
