import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralTab(state: state, settings: state.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupTab(state: state, settings: state.settings)
                .tabItem { Label("Cleanup", systemImage: "sparkles") }
            CameraTab(state: state, settings: state.settings)
                .tabItem { Label("Camera", systemImage: "video") }
            AdvancedTab(state: state, settings: state.settings)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            AboutTab(updater: Updater.shared)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 470)
    }
}

struct GeneralTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                Picker("Hold to dictate", selection: $settings.holdKey) {
                    ForEach(HoldKeyChoice.allCases) { k in Text("\(k.symbol)  \(k.name)").tag(k) }
                }
                if settings.holdKey == .fn {
                    Text("macOS and Wispr Flow may also use Fn. Set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Hold the key, silently mouth your words, then let go. Press Esc while holding to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When it's read") {
                Picker("Text goes", selection: $settings.insertMode) {
                    Text("Into the app you're typing in").tag(InsertMode.paste)
                    Text("To the clipboard only").tag(InsertMode.copy)
                }
                Toggle("Add a space after the text", isOn: $settings.trailingSpace)
                Toggle("Play sounds", isOn: $settings.sounds)
            }
            Section {
                Toggle("Open Lip Dictation when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginProblem { Text(loginProblem).font(.caption).foregroundStyle(.orange) }
            }
            Section("Permissions") {
                PermissionLine(title: "Camera", granted: state.cameraAuthorized, pane: "Privacy_Camera")
                PermissionLine(title: "Accessibility", granted: state.accessibilityGranted, pane: "Privacy_Accessibility")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PermissionLine: View {
    let title: String
    let granted: Bool
    let pane: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}

struct CleanupTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    @ObservedObject var engine: Engine
    @State private var key = ""
    @State private var editing = false

    init(state: AppState, settings: Settings) {
        self.state = state
        self.settings = settings
        self.engine = state.engine
    }

    var body: some View {
        Form {
            Section {
                Toggle("Clean up with Claude", isOn: $settings.useClaude)
            } footer: {
                Text("Lip reading can't tell apart sounds that look the same on the lips, like p, b and m. Claude looks at the lip reader's five best guesses and your recent dictations, picks what you meant and adds punctuation. Only that text is sent, never video. Without it, simple rules fix capitals and punctuation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anthropic API key") {
                if state.hasAPIKey && !editing {
                    HStack {
                        Label("Saved in your keychain", systemImage: "key.fill")
                        Spacer()
                        Button("Change") { editing = true }
                        Button("Remove", role: .destructive) { state.saveAPIKey(nil) }
                    }
                } else {
                    HStack {
                        SecureField("API key", text: $key, prompt: Text("sk-ant-…")).labelsHidden().textFieldStyle(.roundedBorder)
                        Button("Save") {
                            state.saveAPIKey(key)
                            key = ""
                            editing = false
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Link("Get a key from the Anthropic Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }
            }
            Section {
                HStack {
                    Text("Cleaning up with")
                    Spacer()
                    Text(engine.cleanupMode == "claude" ? "Claude (claude-opus-5-5)" : "Offline rules")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct CameraTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    @State private var devices = Camera.devices()

    var body: some View {
        Form {
            Section {
                Picker("Camera", selection: $settings.cameraID) {
                    Text("Built-in camera").tag("")
                    ForEach(devices, id: \.uniqueID) { d in Text(d.localizedName).tag(d.uniqueID) }
                }
                ZStack {
                    if state.cameraAuthorized {
                        CameraPreview(session: state.camera.session)
                        MouthGuide()
                    } else {
                        Color.black.opacity(0.85)
                        Label("Camera not allowed", systemImage: "video.slash").foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onAppear { state.camera.previewAppeared(cameraID: settings.cameraID) }
                .onDisappear { state.camera.previewDisappeared() }
            } footer: {
                Text("For the best reading: face the camera, keep your whole mouth in view and lit from the front, and avoid a bright window behind you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show my face while listening", isOn: $settings.showPreview)
                Toggle("Keep the camera on between dictations", isOn: $settings.keepCameraOn)
            } footer: {
                Text("Otherwise the camera turns off a minute after your last dictation. Keeping it on makes the first dictation start instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: Settings
    @ObservedObject var engine: Engine
    @State private var confirmReinstall = false

    init(state: AppState, settings: Settings) {
        self.state = state
        self.settings = settings
        self.engine = state.engine
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Slider(value: Binding(get: { Double(settings.beam) }, set: { settings.beam = Int($0) }),
                           in: 4...24, step: 2) {
                        Text("Search width")
                    } minimumValueLabel: { Text("Faster").font(.caption) } maximumValueLabel: { Text("Thorough").font(.caption) }
                    Text("How many readings the lip reader weighs at once (\(settings.beam)). Wider is a little more accurate and slower.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Lip reader") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(engineStatus).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Restart") { engine.restart() }
                    Button("Repair…") { confirmReinstall = true }
                    Spacer()
                    Button("Show log") { NSWorkspace.shared.open(Paths.log) }
                    Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([Paths.support]) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Download the lip reader's libraries again?", isPresented: $confirmReinstall) {
            Button("Repair") {
                try? FileManager.default.removeItem(at: Paths.installRecord)
                state.install()
            }
        } message: {
            Text("This reinstalls Python and its libraries and re-checks the model files. The model is only downloaded again if a file is damaged.")
        }
    }

    private var engineStatus: String {
        switch engine.state {
        case .ready: return engine.usingGPU ? "Running on the Apple GPU" : "Running on the CPU"
        case .starting(let m): return m
        case .failed(let m): return m
        case .stopped: return state.isInstalling ? "Installing…" : "Stopped"
        }
    }
}
