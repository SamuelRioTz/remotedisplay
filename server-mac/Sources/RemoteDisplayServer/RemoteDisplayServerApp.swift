import SwiftUI

@main
struct RemoteDisplayServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menú de barra = acceso rápido para el uso en segundo plano (estado,
        // abrir la ventana de configuración, servicio, login item, salir).
        // Toda la configuración vive en la ventana principal (MainWindowView).
        MenuBarExtra {
            StatusMenu()
                .environment(appDelegate.controller)
        } label: {
            let c = appDelegate.controller
            Image(systemName: c.isReady
                  ? "display"
                  : "display.trianglebadge.exclamationmark")
        }
        .menuBarExtraStyle(.menu)
    }
}
