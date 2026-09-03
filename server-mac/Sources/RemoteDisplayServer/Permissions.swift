import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Status and requesting of the TCC permissions the engine needs to serve the
/// screen and control the machine. The app and the engine are signed with the SAME
/// identity (stable cert), so the permission granted to the app also covers the engine.
enum Permissions {
    // MARK: - Status

    static func screenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func accessibility() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Requesting (triggers the native "Allow" dialog)

    static func requestScreenRecording() {
        let r = CGRequestScreenCaptureAccess()
        NSLog("[remotedisplay] CGRequestScreenCaptureAccess -> %d (preflight %d)", r ? 1 : 0, CGPreflightScreenCaptureAccess() ? 1 : 0)
    }

    static func requestAccessibility() {
        // Triggers the "…would like to control this computer" dialog and adds the app
        // to the Accessibility list. Only appears if not already granted.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Open the exact panel

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
            // Fallback: /usr/bin/open (same x-apple.systempreferences scheme).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [urlString]
            try? p.run()
        }
    }
}
