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
                .tabItem { Label("Accuracy", systemImage: "sparkles") }
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
    @State private var sharing = false

    init(state: AppState, settings: Settings) {
        self.state = state
        self.settings = settings
        self.engine = state.engine
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Context", systemImage: "text.word.spacing")
                    Spacer()
                    Text(engine.hasContextModel ? "On-device language model on" : "Language model not installed")
                        .foregroundStyle(engine.hasContextModel ? Color.secondary : Color.orange)
                }
                Toggle("Use the text before the cursor", isOn: $settings.useCursorContext)
            } footer: {
                Text("Lips can't tell “meal” from “mail”, so a language model on this Mac weighs the lip reader's best readings and look-alike words, and picks the sentence that makes sense — after “I want to eat a”, a food, not a car. It reads the text just before your cursor (never password fields) to know what you're writing. That text stays on this Mac unless Claude cleanup is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Learn from my corrections", isOn: $settings.learnFromCorrections)
                if state.dictionary.fixes.isEmpty {
                    Text("Nothing learned yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.dictionary.fixes) { fix in
                        HStack(spacing: 8) {
                            Text(fix.heard).foregroundStyle(.secondary).strikethrough(color: .secondary.opacity(0.6))
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(fix.fixed).fontWeight(.medium)
                            Spacer()
                            if fix.count > 1 { Text("×\(fix.count)").font(.caption).foregroundStyle(.secondary) }
                            Button { state.dictionary.remove(fix.heard); state.configureEngine() } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Forget this fix")
                        }
                    }
                }
                if !state.dictionary.unshared.isEmpty {
                    HStack {
                        Text("\(state.dictionary.unshared.count) fix\(state.dictionary.unshared.count == 1 ? "" : "es") not shared yet")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Share with everyone…") { sharing = true }
                    }
                }
            } header: {
                Text("Your dictionary")
            } footer: {
                Text("When you fix a word Lip Dictation typed — backspace “PS” and type “PS5” — it notices and remembers. Next time it reads “PS”, it writes “PS5”, unless the sentence clearly means something else. Fixes made more often count for more. You can also fix any dictation in History. It works in apps that let macOS read their text fields (most do).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $settings.customWords)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(alignment: .topLeading) {
                        if settings.customWords.isEmpty {
                            Text("One per line, e.g. names of people, places, products").foregroundStyle(.tertiary)
                                .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Your words")
            } footer: {
                Text("Names and terms you use. A name is just lip shapes to the lip reader, so listing it lets it choose your word when the lips fit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Clean up with Claude", isOn: $settings.useClaude)
            } footer: {
                Text("For the best results, Claude also looks at the readings, the text before your cursor, the app and your words, then writes what you meant with punctuation. Only that text is sent, never video. Without it, the on-device model chooses the words and simple rules add capitals and punctuation.")
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
        .sheet(isPresented: $sharing) { ShareFixesView(dictionary: state.dictionary) }
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
                state.install(stopEngine: true)
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
