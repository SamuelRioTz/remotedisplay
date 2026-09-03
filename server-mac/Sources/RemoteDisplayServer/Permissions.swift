import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Estado y solicitud de los permisos TCC que el motor necesita para servir la
/// pantalla y controlar el equipo. La app y el motor se firman con la MISMA
/// identidad (cert estable), así que el permiso concedido a la app cubre al motor.
enum Permissions {
    // MARK: - Estado

    static func screenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func accessibility() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Solicitud (dispara el diálogo nativo "Permitir")

    static func requestScreenRecording() {
        let r = CGRequestScreenCaptureAccess()
        NSLog("[remotedisplay] CGRequestScreenCaptureAccess -> %d (preflight %d)", r ? 1 : 0, CGPreflightScreenCaptureAccess() ? 1 : 0)
    }

    static func requestAccessibility() {
        // Dispara el diálogo "…quiere controlar esta computadora" y agrega la app
        // a la lista de Accesibilidad. Solo aparece si aún no está concedido.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Abrir el panel exacto

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let ok = NSWorkspace.shared.open(url)
        NSLog("[remotedisplay] open settings %@ -> %d", urlString, ok ? 1 : 0)
        if !ok {
            // Fallback: /usr/bin/open (mismo esquema x-apple.systempreferences).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [urlString]
            try? p.run()
        }
    }
}
