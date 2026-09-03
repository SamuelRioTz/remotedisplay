import AppKit
import Foundation
import Observation
import ServiceManagement

/// Controla el motor de Remote Display (`remotedisplayd`) corriéndolo como PROCESO
/// INDEPENDIENTE vía LaunchAgent — NO como hijo de esta app.
///
/// Por qué LaunchAgent y no proceso hijo: cuando el motor corre como hijo de la
/// app, macOS NO le permite inyectar eventos (CGEventPost) aunque AXIsProcessTrusted
/// diga true (el "responsible process" del hijo rompe la atribución TCC para
/// inyección). Como proceso independiente, el motor es su propio sujeto TCC con la
/// identidad `app.remotedisplay.server` (la misma que la app, firmada con cert estable)
/// → un solo permiso que además SÍ funciona para controlar.
@Observable
final class ServerController {
    static let agentLabel = "app.remotedisplay.server"
    static let port: UInt16 = 21118

    var serviceRunning = false
    var launchAtLogin = false
    var screenOK = false
    var accessibilityOK = false
    var lanIP: String?
    var tailscaleIP: String?
    var lastError: String?
    /// Peers conectados ahora ("ip:puerto" remoto), vía lsof del motor.
    var sessions: [String] = []
    /// Hay contraseña permanente definida (RemoteDisplay.toml → password no vacío).
    var passwordSet = false
    var engineVersion = "—"

    var isReady: Bool { serviceRunning && screenOK && accessibilityOK }
    var missingCount: Int {
        (serviceRunning ? 0 : 1) + (screenOK ? 0 : 1) + (accessibilityOK ? 0 : 1) + (passwordSet ? 0 : 1)
    }
    var statusLine: String {
        if !serviceRunning { return "Stopped" }
        let perms = (screenOK ? 0 : 1) + (accessibilityOK ? 0 : 1)
        if perms > 0 { return "Running · \(perms) permission\(perms == 1 ? "" : "s") missing" }
        if !passwordSet { return "Running · no password set" }
        if let ip = lanIP { return "Ready · \(ip):\(Self.port)" }
        return "Ready"
    }

    private var timer: Timer?
    /// Estado deseado por el usuario (persistido): si el motor muere o no
    /// arrancó (sin KeepAlive en el LaunchAgent, a propósito), la app lo
    /// vuelve a levantar; si el usuario lo apagó, no.
    private var serviceDesired: Bool {
        get { UserDefaults.standard.object(forKey: "serviceDesired") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "serviceDesired") }
    }
    private var lastAutoStart = Date.distantPast
    private var prevScreen = false
    private var prevAccessibility = false
    private var firstRefresh = true

    private var enginePath: String { Bundle.main.bundlePath + "/Contents/MacOS/remotedisplayd" }
    private var agentPlistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(Self.agentLabel).plist" }
    private var logDir: String { NSHomeDirectory() + "/Library/Logs/RemoteDisplayServer" }
    private var configDir: String { NSHomeDirectory() + "/Library/Preferences/RemoteDisplay" }
    private var configPath: String { configDir + "/RemoteDisplay2.toml" }
    private var permsPath: String { NSHomeDirectory() + "/Library/Application Support/remotedisplay-perms.json" }
    private var mainConfigPath: String { configDir + "/RemoteDisplay.toml" }
    private var guiDomain: String { "gui/\(getuid())" }

    private let serverlessConfig = """
    rendezvous_server = '127.0.0.1'
    nat_type = 0
    serial = 0

    [options]
    custom-rendezvous-server = '127.0.0.1'
    relay-server = ''
    api-server = ''
    key = ''
    direct-server = 'Y'
    direct-access-port = '21118'
    enable-check-update = 'N'
    allow-auto-update = 'N'
    enable-lan-discovery = 'Y'
    approve-mode = 'password'
    verification-method = 'use-permanent-password'
    """

    // MARK: - Ciclo de vida

    func start() {
        engineVersion = readEngineVersion()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Only start the engine if it isn't already up. Calling setServiceEnabled
        // unconditionally would bootout+bootstrap the LaunchAgent on every app
        // launch, killing any in-progress remote session.
        if !serviceRunning && serviceDesired {
            setServiceEnabled(true)
        }
    }

    /// Si el usuario quiere el servicio activo y el motor no está, relanzarlo
    /// (con un mínimo de 10 s entre intentos).
    private func ensureDesiredState() {
        guard serviceDesired, !serviceRunning, !firstRefresh else { return }
        guard Date().timeIntervalSince(lastAutoStart) > 10 else { return }
        lastAutoStart = Date()
        NSLog("[remotedisplay] engine not running but desired → starting")
        setServiceEnabled(true)
    }

    func refresh() {
        // Use pgrep (passive) to detect the engine. Do NOT probe the port with a
        // real connect(): on macOS every accepted connection spawns `caffeinate`,
        // so a 2s connect-probe kept the Mac awake forever and churned the engine's
        // connection handler (`Input thread exited` every 2s).
        serviceRunning = processRunning()
        if let (s, a) = readEnginePerms() {
            screenOK = s
            accessibilityOK = a
        } else {
            screenOK = Permissions.screenRecording()
            accessibilityOK = Permissions.accessibility()
        }
        // TCC cachea Screen Recording por proceso: ni el motor que ya corre ni esta
        // app ven un permiso recién concedido. Mientras falte algo, preguntar a un
        // proceso FRESCO (`remotedisplayd --check-perms`); si ya está concedido,
        // reiniciar el motor para que lo tome y mostrar la verdad ya mismo.
        if serviceRunning && (!screenOK || !accessibilityOK), let fresh = probePerms() {
            let newlyGranted = (fresh.screen && !screenOK) || (fresh.accessibility && !accessibilityOK)
            if newlyGranted {
                NSLog("[remotedisplay] permission granted (fresh probe) → restarting engine")
                restartEngine()
                screenOK = fresh.screen
                accessibilityOK = fresh.accessibility
            }
        }
        lanIP = NetworkInfo.primaryLAN()
        tailscaleIP = NetworkInfo.tailscale()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        passwordSet = readPasswordSet()
        sessions = serviceRunning ? readSessions() : []

        // Si un permiso pasó de NO a SÍ, reiniciar el motor para que arranque con
        // el permiso ya efectivo.
        let justGranted = (accessibilityOK && !prevAccessibility) || (screenOK && !prevScreen)
        prevScreen = screenOK
        prevAccessibility = accessibilityOK
        if justGranted && serviceRunning && !firstRefresh {
            restartEngine()
        }
        ensureDesiredState()
        firstRefresh = false
    }

    private func readEnginePerms() -> (screen: Bool, accessibility: Bool)? {
        guard let data = FileManager.default.contents(atPath: permsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else { return nil }
        return (obj["screen"] ?? false, obj["accessibility"] ?? false)
    }

    private func processRunning() -> Bool { enginePid() != nil }

    private func enginePid() -> Int32? {
        let out = run("/usr/bin/pgrep", ["-f", "remotedisplayd --server"])
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// Conexiones TCP establecidas del motor en el puerto del servicio → peers.
    private func readSessions() -> [String] {
        guard let pid = enginePid() else { return [] }
        let out = run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:ESTABLISHED", "-F", "n"])
        var peers: [String] = []
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            // n[::ffff:192.168.1.117]:21118->[::ffff:192.168.1.245]:37911  ó  n192.168.1.117:21118->192.168.1.245:37911
            let s = String(line.dropFirst())
            guard let arrow = s.range(of: "->") else { continue }
            let local = s[..<arrow.lowerBound]
            guard local.hasSuffix(":\(Self.port)") else { continue }
            var peer = String(s[arrow.upperBound...])
            peer = peer.replacingOccurrences(of: "[::ffff:", with: "").replacingOccurrences(of: "]", with: "")
            if !peers.contains(peer) { peers.append(peer) }
        }
        return peers
    }

    /// `password = '...'` no vacío en RemoteDisplay.toml (el motor lo guarda cifrado).
    private func readPasswordSet() -> Bool {
        guard let s = try? String(contentsOfFile: mainConfigPath, encoding: .utf8) else { return false }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("password = ") {
                let v = t.dropFirst("password = ".count).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                return !v.isEmpty
            }
        }
        return false
    }

    /// Permisos vistos por un proceso nuevo del motor (`--check-perms`).
    private func probePerms() -> (screen: Bool, accessibility: Bool)? {
        let out = run(enginePath, ["--check-perms"])
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
        else { return nil }
        return (obj["screen"] ?? false, obj["accessibility"] ?? false)
    }

    private func readEngineVersion() -> String {
        let out = run(enginePath, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "—" : out
    }

    /// Ejecuta y devuelve stdout (síncrono, procesos cortos).
    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Corta todas las sesiones reiniciando el motor (los clientes reconectan a mano).
    func disconnectAll() {
        restartEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    func openLogs() {
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: logDir))
    }

    func revealConfig() {
        NSWorkspace.shared.selectFile(configPath, inFileViewerRootedAtPath: configDir)
    }

    // MARK: - Servicio (LaunchAgent)

    func setServiceEnabled(_ on: Bool) {
        serviceDesired = on
        if on {
            ensureConfig()
            writeAgentPlist()
            // Evitar doble-bind del puerto 21118 / socket IPC con la ruta headless
            // legacy (install-host.sh, label app.remotedisplay.engine).
            runLaunchctl(["bootout", "\(guiDomain)/app.remotedisplay.engine"])
            runLaunchctl(["bootout", "\(guiDomain)/\(Self.agentLabel)"])
            let rc = runLaunchctl(["bootstrap", guiDomain, agentPlistPath])
            if rc != 0 { runLaunchctl(["load", "-w", agentPlistPath]) }
        } else {
            runLaunchctl(["bootout", "\(guiDomain)/\(Self.agentLabel)"])
            pkillEngine()
            try? FileManager.default.removeItem(atPath: agentPlistPath)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refresh() }
    }

    private func restartEngine() {
        runLaunchctl(["kickstart", "-k", "\(guiDomain)/\(Self.agentLabel)"])
    }

    private func writeAgentPlist() {
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Self.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(enginePath)</string>
                <string>--server</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
            <key>StandardOutPath</key><string>\(logDir)/engine.log</string>
            <key>StandardErrorPath</key><string>\(logDir)/engine.log</string>
        </dict>
        </plist>
        """
        try? plist.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
    }

    private func ensureConfig() {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if !current.contains("direct-server = 'Y'") {
            try? serverlessConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }

    private func pkillEngine() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "remotedisplayd --server"]
        k.standardError = Pipe()
        try? k.run(); k.waitUntilExit()
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - Permisos (abrir paneles / disparar prompts desde la app)

    func grantScreenRecording() {
        NSLog("[remotedisplay] grantScreenRecording tapped")
        Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
    }

    func grantAccessibility() {
        NSLog("[remotedisplay] grantAccessibility tapped")
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    // MARK: - Abrir al iniciar sesión

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = "Login item: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Contraseña

    func changePassword(_ password: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: self.enginePath)
            p.arguments = ["--set-lan-password", password]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try? p.run(); p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            let ok = s.contains("Done!")
            DispatchQueue.main.async {
                self.refresh()
                completion(ok, ok ? "Password updated" : "Error: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

}
