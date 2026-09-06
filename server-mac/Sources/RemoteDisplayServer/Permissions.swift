import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Network

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

    static func openLocalNetworkSettings() {
        // The pane anchor moved between macOS releases; try the newer one, then the classic.
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork"),
           NSWorkspace.shared.open(url) {
            return
        }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
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

/// Tells whether this app (and so the engine, same code identity) can actually use the
/// local network — the macOS 15+ "Local Network" privacy control. There is no status API
/// for it, so we advertise a throwaway Bonjour service and try to browse it back: it comes
/// back only when access is allowed. When access is undetermined, starting this is what
/// makes macOS show the prompt (attributed to the app); denied or pending → it times out.
/// Discovery uses UDP broadcast, not Bonjour, but both need the same permission, so this is
/// a faithful proxy that needs no clients on the network to test.
final class LocalNetworkProbe {
    private let type = "_rdprobe._udp"
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var completion: ((Bool) -> Void)?
    private var done = false

    /// `allowed` is delivered once, on the main thread.
    func check(timeout: TimeInterval = 4, completion: @escaping (_ allowed: Bool) -> Void) {
        self.completion = completion
        self.done = false
        let name = "rdprobe-\(UInt32.random(in: 0 ..< .max))"

        do {
            let l = try NWListener(using: .udp)
            l.service = NWListener.Service(name: name, type: type)
            l.newConnectionHandler = { $0.cancel() }
            l.start(queue: .global(qos: .utility))
            listener = l
        } catch {
            finish(false)
            return
        }

        let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let seen = results.contains { r in
                if case let .service(n, t, _, _) = r.endpoint { return n == name && t == self.type }
                return false
            }
            if seen { self.finish(true) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(false) }
        }
        b.start(queue: .global(qos: .utility))
        browser = b

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(false)
        }
    }

    private func finish(_ allowed: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.done else { return }
            self.done = true
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            let c = self.completion; self.completion = nil
            c?(allowed)
        }
    }
}
