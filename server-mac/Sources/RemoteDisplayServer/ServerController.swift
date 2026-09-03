import AppKit
import Foundation
import Observation
import ServiceManagement

/// Controls the Remote Display engine (`remotedisplayd`), running it as an INDEPENDENT
/// PROCESS via LaunchAgent — NOT as a child of this app.
///
/// Why LaunchAgent and not a child process: when the engine runs as a child of the
/// app, macOS does NOT let it inject events (CGEventPost) even if AXIsProcessTrusted
/// says true (the child's "responsible process" breaks TCC attribution for
/// injection). As an independent process, the engine is its own TCC subject with the
/// `app.remotedisplay.server` identity (the same as the app, signed with a stable cert)
/// → a single permission that ALSO actually works for control.
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
    /// Peers currently connected ("ip:port" remote), via the engine's lsof.
    var sessions: [String] = []
    /// Whether a permanent password is set (RemoteDisplay.toml → password not empty).
    var passwordSet = false
    var engineVersion = "—"
    /// Reason the engine CANNOT run on this Mac (architecture,
    /// file permissions, missing binary). While not nil, nothing works.
    var engineProblem: String?
    /// The app is running from App Translocation (copied without the Finder / opened
    /// straight from the DMG): the bundle path is temporary and the LaunchAgent will stop starting.
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
    /// User-desired state (persisted): if the engine dies or fails to
    /// start (no KeepAlive on the LaunchAgent, on purpose), the app brings
    /// it back up; if the user turned it off, it doesn't.
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

    // MARK: - Lifecycle

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

    /// If the user wants the service active and the engine isn't up, relaunch it
    /// (with a minimum of 10 s between attempts).
    private func ensureDesiredState() {
        guard !quitting, serviceDesired, !serviceRunning, !firstRefresh else { return }
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
        // TCC caches Screen Recording per process: neither the already-running engine
        // nor this app sees a permission just granted. While something's missing, ask a
        // FRESH process (`remotedisplayd --check-perms`); if it's already granted,
        // restart the engine so it picks it up and show the truth right away.
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

        // If a permission flipped from NO to YES, restart the engine so it starts with
        // the permission already in effect.
        let justGranted = (accessibilityOK && !prevAccessibility) || (screenOK && !prevScreen)
        prevScreen = screenOK
        prevAccessibility = accessibilityOK
        forgetPromptsForGrantedPermissions()
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

    /// The engine as launchd runs it: the bundled binary with exactly `--server`.
    /// Anchored so that shells or scripts merely mentioning the name do not match.
    private static let enginePattern = "/Contents/MacOS/remotedisplayd --server$"

    private func enginePid() -> Int32? {
        let out = run("/usr/bin/pgrep", ["-f", Self.enginePattern])
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// Established TCP connections of the engine on the service port → peers.
    private func readSessions() -> [String] {
        guard let pid = enginePid() else { return [] }
        let out = run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:ESTABLISHED", "-F", "n"])
        var peers: [String] = []
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            // n[::ffff:192.168.1.117]:21118->[::ffff:192.168.1.245]:37911  or  n192.168.1.117:21118->192.168.1.245:37911
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

    /// `password = '...'` non-empty in RemoteDisplay.toml (the engine stores it encrypted).
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

    /// Permissions as seen by a fresh engine process (`--check-perms`).
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

    /// Runs and returns stdout (synchronous, short-lived processes). Never blocks more
    /// than a few seconds: if the process doesn't start or doesn't finish, returns "".
    private func run(_ path: String, _ args: [String]) -> String {
        Self.runProcess(path, args, timeout: 5).output
    }

    /// Result of a short-lived process.
    struct ProcessResult {
        var output = ""
        /// Exit code; nil if it never ran or didn't finish in time.
        var status: Int32?
        /// Human-readable reason when it couldn't run or complete.
        var failure: String?
    }

    /// Runs a process with a timeout. Reads stdout (and stderr if `mergeStderr`) on a
    /// separate thread BEFORE waiting for exit: waiting first leaves the pipe with no
    /// reader (deadlock if the child writes a lot), and if `run()` fails, reading until EOF
    /// never finishes because nobody closes the write end — exactly the
    /// "Saving…" hang seen when setting the password with an engine that
    /// can't run (e.g. an arm64 binary on an Intel Mac).
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

    /// nil if the engine binary exists, is executable, and contains this Mac's
    /// architecture; otherwise, the reason. Reads the Mach-O header (thin or fat).
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

    /// Cuts all sessions by restarting the engine (clients reconnect manually).
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

    // MARK: - Service (LaunchAgent)

    func setServiceEnabled(_ on: Bool) {
        serviceDesired = on
        trace("service \(on ? "on" : "off") requested")
        if on {
            if let problem = engineProblem {
                NSLog("[remotedisplay] not starting the service: %@", problem)
                return
            }
            ensureConfig()
            writeAgentPlist()
            // Avoid a double bind of port 21118 / the IPC socket with the legacy
            // headless path (install-host.sh, label app.remotedisplay.engine).
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

    /// Quit (⌘Q or the menu bar item): stop the engine too, so nothing of the bundle
    /// stays in use (replacing the app in /Applications failed with "in use" while the
    /// engine kept running) and the Mac's displays are put back by the engine's SIGTERM
    /// handler. The service is NOT turned off: the agent plist stays registered, so the
    /// engine comes back at the next login, and the app starts it again when reopened.
    func stopEngineForQuit() {
        // No more refresh() while we quit: ensureDesiredState() would bring the
        // engine right back after the bootout (seen in the test VM).
        quitting = true
        timer?.invalidate(); timer = nil
        guard processRunning() else { trace("quit: engine not running"); return }
        trace("quit: stopping the engine (bootout)")
        let rc = runLaunchctl(["bootout", "\(guiDomain)/\(Self.agentLabel)"])
        trace("quit: bootout rc=\(rc)")
        // bootout returns as soon as launchd has signalled the job; the engine's
        // display restore takes a few seconds. Fall back to a plain SIGTERM if the
        // job was not under launchd.
        var waited = 0
        while processRunning() && waited < 60 { usleep(250_000); waited += 1 }
        if processRunning() {
            trace("quit: engine still running after \(waited / 4) s, pkill")
            pkillEngine()
            waited = 0
            while processRunning() && waited < 40 { usleep(250_000); waited += 1 }
        }
        trace("quit: engine \(processRunning() ? "STILL RUNNING" : "stopped") after \(waited / 4) s")
    }

    private var quitting = false

    /// Plain-text trace for the quit/service paths: NSLog output is not reachable
    /// with `log show` over ssh, and the user can send this file with a bug report.
    private func trace(_ line: String) {
        NSLog("[remotedisplay] %@", line)
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let path = logDir + "/app.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
            h.seekToEndOfFile(); h.write("\(stamp) \(line)\n".data(using: .utf8)!); h.closeFile()
        }
    }

    private func restartEngine() {
        // Not `kickstart -k`: that kills the running instance outright and the engine
        // never gets to put the displays back. bootout (SIGTERM, reset, exit) + bootstrap.
        trace("restarting the engine")
        runLaunchctl(["bootout", "\(guiDomain)/\(Self.agentLabel)"])
        var waited = 0
        while processRunning() && waited < 60 { usleep(250_000); waited += 1 }
        if processRunning() { pkillEngine() }
        runLaunchctl(["bootstrap", guiDomain, agentPlistPath])
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
        k.arguments = ["-f", Self.enginePattern]
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

    // MARK: - Permissions

    // The first tap asks macOS, whose own dialog offers "Open System Settings" and
    // adds the app to the permission's list. Opening Settings at the same time put
    // two things on screen for one action. macOS shows that dialog once and never
    // again after it was answered (not even in a later launch), so once we have
    // asked, a tap while the permission is still missing opens the exact Settings
    // panel instead. The flag is cleared when the permission shows up as granted.
    private static let screenPromptedKey = "screenRecordingPrompted"
    private static let accessibilityPromptedKey = "accessibilityPrompted"

    func grantScreenRecording() {
        let prompted = UserDefaults.standard.bool(forKey: Self.screenPromptedKey)
        NSLog("[remotedisplay] grantScreenRecording tapped (prompted before: %d)", prompted ? 1 : 0)
        if prompted {
            Permissions.openScreenRecordingSettings()
        } else {
            UserDefaults.standard.set(true, forKey: Self.screenPromptedKey)
            Permissions.requestScreenRecording()
        }
    }

    func grantAccessibility() {
        let prompted = UserDefaults.standard.bool(forKey: Self.accessibilityPromptedKey)
        NSLog("[remotedisplay] grantAccessibility tapped (prompted before: %d)", prompted ? 1 : 0)
        if prompted {
            Permissions.openAccessibilitySettings()
        } else {
            UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedKey)
            Permissions.requestAccessibility()
        }
    }

    private func forgetPromptsForGrantedPermissions() {
        if screenOK { UserDefaults.standard.removeObject(forKey: Self.screenPromptedKey) }
        if accessibilityOK { UserDefaults.standard.removeObject(forKey: Self.accessibilityPromptedKey) }
    }

    // MARK: - Open at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = "Login item: \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Password

    /// Sets the permanent password. `--set-lan-password` talks IPC to the running
    /// engine, so it requires the service to be on. Never leaves the UI hanging:
    /// fails with a clear message if the engine doesn't start or doesn't respond.
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
