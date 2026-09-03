import AppKit
import SwiftUI

/// Main window: ALL the configuration and status, Settings-app style
/// (grouped Form). What's ready, what's missing, and how to connect.
struct MainWindowView: View {
    @Environment(ServerController.self) private var c
    @State private var showPasswordSheet = false
    @State private var newPassword = ""
    @State private var passwordMsg = ""
    @State private var passwordOK = false
    @State private var saving = false
    @State private var copied: String?

    var body: some View {
        Form {
            statusSection
            setupSection
            if c.serviceRunning { connectSection }
            sessionsSection
            settingsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .sheet(isPresented: $showPasswordSheet) { passwordSheet }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "display")
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Display Server").font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(c.isReady ? .green : (c.serviceRunning ? .orange : .secondary))
                            .frame(width: 8, height: 8)
                        Text(c.statusLine).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { c.serviceRunning }, set: { c.setServiceEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .help("Service Active")
                    .disabled(c.engineProblem != nil)
            }
            .padding(.vertical, 4)
            if let problem = c.engineProblem {
                Label(problem, systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 12.5)).foregroundStyle(.red)
            } else if c.translocated {
                Label("Running from a temporary location. Move Remote Display Server to the Applications folder with the Finder and reopen it, or the service will not start after a restart.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Setup checklist

    private var setupSection: some View {
        Section {
            checkRow(ok: c.serviceRunning, title: "Service running",
                     detail: c.serviceRunning ? "Listening on port \(ServerController.port)" : "Turn the service on",
                     cta: c.serviceRunning ? nil : "Turn On") { c.setServiceEnabled(true) }
            checkRow(ok: c.screenOK, title: "Screen Recording",
                     detail: c.screenOK ? "Granted" : "Required to share this Mac's screen",
                     cta: c.screenOK ? nil : "Grant…") { c.grantScreenRecording() }
            checkRow(ok: c.accessibilityOK, title: "Accessibility",
                     detail: c.accessibilityOK ? "Granted" : "Required to control mouse and keyboard",
                     cta: c.accessibilityOK ? nil : "Grant…") { c.grantAccessibility() }
            checkRow(ok: c.passwordSet, title: "Permanent password",
                     detail: c.passwordSet ? "Set — clients use it to connect" : "Clients cannot connect without it",
                     cta: c.passwordSet ? "Change…" : "Set…") { openPasswordSheet() }
        } header: {
            HStack {
                Text("Setup")
                Spacer()
                Text(c.missingCount == 0 ? "All set" : "\(c.missingCount) to do")
                    .foregroundStyle(c.missingCount == 0 ? .green : .orange)
            }
        } footer: {
            if !c.screenOK || !c.accessibilityOK {
                Text("Permissions are granted in System Settings → Privacy & Security. The engine restarts automatically once granted.")
            }
        }
    }

    private func checkRow(ok: Bool, title: String, detail: String,
                          cta: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(ok ? Color.green : Color.secondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if let cta {
                if ok {
                    Button(cta, action: action).buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(cta, action: action).buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Connect

    private var connectSection: some View {
        Section {
            if let ip = c.lanIP { addrRow("Local network", "\(ip):\(ServerController.port)") }
            if let ts = c.tailscaleIP { addrRow("Tailscale", "\(ts):\(ServerController.port)") }
            if c.lanIP == nil && c.tailscaleIP == nil {
                Text("No network address detected").foregroundStyle(.secondary)
            }
        } header: {
            Text("Connect from another device")
        } footer: {
            Text("Direct connection only — no relay or account. Clients on the same network discover this Mac automatically; otherwise enter the address above.")
        }
    }

    private func addrRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == value { copied = nil } }
            } label: {
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied == value ? .green : .secondary)
            }.buttonStyle(.plain).help("Copy")
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        Section {
            if c.sessions.isEmpty {
                Text(c.serviceRunning ? "No one is connected" : "Service is off")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(c.sessions, id: \.self) { peer in
                    HStack {
                        Image(systemName: "laptopcomputer.and.arrow.down").foregroundStyle(.green)
                        Text(peer).font(.system(size: 13, design: .monospaced))
                        Spacer()
                        Text("connected").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Button("Disconnect all", role: .destructive) { c.disconnectAll() }
            }
        } header: {
            HStack {
                Text("Active sessions")
                Spacer()
                if !c.sessions.isEmpty { Text("\(c.sessions.count)").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Section("Settings") {
            Toggle("Open at Login", isOn: Binding(
                get: { c.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
            HStack {
                Text("Permanent password")
                Spacer()
                Text(c.passwordSet ? "••••••••" : "Not set").foregroundStyle(.secondary)
                Button(c.passwordSet ? "Change…" : "Set…") { openPasswordSheet() }.controlSize(.small)
            }
            HStack {
                Text("Access mode")
                Spacer()
                Text("Password only · direct IP · LAN discovery").foregroundStyle(.secondary)
            }
            if let err = c.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            HStack { Text("Engine"); Spacer(); Text(c.engineVersion).foregroundStyle(.secondary) }
            HStack {
                Text("License")
                Spacer()
                Text("AGPL-3.0 · based on RustDesk").foregroundStyle(.secondary)
            }
            HStack {
                Text("Source code")
                Spacer()
                Link("github.com/SamuelRioTz/remotedisplay",
                     destination: URL(string: "https://github.com/SamuelRioTz/remotedisplay")!)
                    .controlSize(.small)
            }
            HStack {
                Text("Logs")
                Spacer()
                Button("Open Folder") { c.openLogs() }.controlSize(.small)
            }
            HStack {
                Text("Configuration")
                Spacer()
                Button("Reveal in Finder") { c.revealConfig() }.controlSize(.small)
            }
        }
    }

    // MARK: - Password sheet

    private func openPasswordSheet() {
        newPassword = ""; passwordMsg = ""; passwordOK = false; saving = false; showPasswordSheet = true
    }

    private func savePassword() {
        guard !saving, newPassword.count >= 6 else { return }
        saving = true; passwordOK = false; passwordMsg = ""
        c.changePassword(newPassword) { ok, msg in
            saving = false; passwordOK = ok; passwordMsg = msg
            if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showPasswordSheet = false } }
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permanent password").font(.headline)
            Text("Clients enter this password to connect to this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .disabled(saving)
                .onSubmit { savePassword() }
            if saving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                }
            } else if !passwordMsg.isEmpty {
                Text(passwordMsg).font(.caption)
                    .foregroundStyle(passwordOK ? Color.secondary : Color.red)
                    .frame(width: 280, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { showPasswordSheet = false }.keyboardShortcut(.cancelAction)
                Button("Save") { savePassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPassword.count < 6 || saving)
            }
        }
        .padding(20)
    }
}
