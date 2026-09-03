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
    /// Motivo por el que el motor NO puede ejecutarse en este Mac (arquitectura,
    /// permisos de archivo, binario ausente). Mientras no sea nil, nada funciona.
    var engineProblem: String?
    /// La app corre desde App Translocation (copiada sin el Finder / abierta desde
    /// el DMG): la ruta del bundle es temporal y el LaunchAgent dejará de arrancar.
    var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    var isReady: Bool { serviceRunning && screenOK && accessibilityOK }
    var missingCount: Int {
        (serviceRunning ? 0 : 1) + (screenOK ? 0 : 1) + (accessibilityOK ? 0 : 1) + (passwordSet ? 0 : 1)
    }
    var statusLine: String {
        if engineProblem != nil { return "Cannot run on this Mac" }
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
        engineProblem = Self.checkEngine(at: enginePath)
        if let problem = engineProblem { NSLog("[remotedisplay] engine problem: %@", problem) }
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

    /// Ejecuta y devuelve stdout (síncrono, procesos cortos). Nunca bloquea más de
    /// unos segundos: si el proceso no arranca o no termina, devuelve "".
    private func run(_ path: String, _ args: [String]) -> String {
        Self.runProcess(path, args, timeout: 5).output
    }

    /// Resultado de un proceso corto.
    struct ProcessResult {
        var output = ""
        /// Código de salida; nil si no llegó a ejecutarse o no terminó a tiempo.
        var status: Int32?
        /// Motivo legible cuando no se pudo ejecutar o completar.
        var failure: String?
    }

    /// Ejecuta un proceso con timeout. Lee stdout (y stderr si `mergeStderr`) en un
    /// hilo aparte ANTES de esperar la salida: esperar primero deja el pipe sin
    /// lector (deadlock si el hijo escribe mucho) y, si `run()` falla, leer hasta EOF
    /// no termina nunca porque nadie cierra el extremo de escritura — exactamente el
    /// cuelgue de "Saving…" que se veía al fijar la contraseña con un motor que no
    /// puede ejecutarse (p. ej. binario arm64 en un Mac Intel).
    static func runProcess(_ path: String, _ args: [String], timeout: TimeInterval, mergeStderr: Bool = false) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = mergeStderr ? out : Pipe()
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do {
            try p.run()
        } catch {
            return ProcessResult(output: "", status: nil, failure: describeLaunchError(error, path: path))
        }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        var result = ProcessResult()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            result.failure = "\(URL(fileURLWithPath: path).lastPathComponent) did not finish in \(Int(timeout)) s"
        } else {
            result.status = p.terminationStatus
        }
        if readDone.wait(timeout: .now() + 1) == .success {
            result.output = String(data: data, encoding: .utf8) ?? ""
        }
        return result
    }

    private static func describeLaunchError(_ error: Error, path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let arch = checkEngine(at: path) { return arch }
        return "Could not start \(name): \(error.localizedDescription)"
    }

    /// nil si el binario del motor existe, es ejecutable y contiene la arquitectura
    /// de este Mac; si no, el motivo. Lee la cabecera Mach-O (thin o fat).
    static func checkEngine(at path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else {
            return "The engine (\(name)) is missing from the app bundle."
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "The engine (\(name)) is not executable. Reinstall the app from the DMG."
        }
        guard let fh = FileHandle(forReadingAtPath: path), let head = try? fh.read(upToCount: 4096), head.count >= 8 else {
            return nil
        }
        try? fh.close()
        func be32(_ o: Int) -> UInt32 { head.subdata(in: o..<o+4).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) } }
        func le32(_ o: Int) -> UInt32 { head.subdata(in: o..<o+4).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) } }
        let cpuArm64: UInt32 = 0x0100000C, cpuX86_64: UInt32 = 0x01000007
        var archs: [UInt32] = []
        switch be32(0) {
        case 0xCAFEBABE: // fat, big-endian
            let n = Int(be32(4))
            for i in 0..<min(n, 8) { archs.append(be32(8 + i * 20)) }
        case 0xCFFAEDFE: archs.append(le32(4))   // MH_MAGIC_64 little-endian on disk
        case 0xFEEDFACF: archs.append(be32(4))
        default: return nil                        // not Mach-O we understand: let exec decide
        }
        #if arch(arm64)
        let want = cpuArm64, wantName = "Apple silicon", other = "Intel"
        #else
        let want = cpuX86_64, wantName = "Intel", other = "Apple silicon"
        #endif
        if archs.contains(want) { return nil }
        if archs.contains(want == cpuArm64 ? cpuX86_64 : cpuArm64) {
            return "This build of Remote Display Server only runs on \(other) Macs; this Mac is \(wantName)."
        }
        return "The engine (\(name)) is built for another CPU architecture."
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
            if let problem = engineProblem {
                NSLog("[remotedisplay] not starting the service: %@", problem)
                return
            }
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

    /// Fija la contraseña permanente. `--set-lan-password` habla por IPC con el motor
    /// en ejecución, así que exige el servicio encendido. Nunca deja la UI esperando:
    /// falla con un mensaje claro si el motor no arranca o no responde.
    func changePassword(_ password: String, completion: @escaping (Bool, String) -> Void) {
        if let problem = engineProblem {
            completion(false, problem)
            return
        }
        guard serviceRunning else {
            completion(false, "Turn the service on first: the running engine stores the password.")
            return
        }
        let path = enginePath
        DispatchQueue.global().async {
            let r = Self.runProcess(path, ["--set-lan-password", password], timeout: 15, mergeStderr: true)
            let ok = r.output.contains("Done!")
            let msg: String
            if ok {
                msg = "Password updated"
            } else if let failure = r.failure {
                msg = failure
            } else {
                let detail = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                msg = detail.isEmpty
                    ? "The engine did not accept the password (exit status \(r.status ?? -1))."
                    : detail.replacingOccurrences(of: "set-lan-password failed: ", with: "Could not set the password: ")
            }
            DispatchQueue.main.async {
                self.refresh()
                completion(ok, msg)
            }
        }
    }

}
