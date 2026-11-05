import SwiftUI

/// First-run setup: what it is → permissions → download the lip reader → try it.
struct WelcomeView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, download, tryIt
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .download: return "Lip reader"
            case .tryIt: return "Try it"
            }
        }
    }

    @ObservedObject var state: AppState
    @State var step: Step = .welcome
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StepBar(current: step)
                .padding(.top, 18)
                .padding(.bottom, 6)
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep(state: state)
                case .download: DownloadStep(state: state)
                case .tryIt: TryStep(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 600, height: 520)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            state.refreshPermissions()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get started") { step = .permissions }.keyboardShortcut(.defaultAction)
            case .permissions:
                if !(state.cameraAuthorized && state.accessibilityGranted) {
                    Button("Skip for now") { advanceFromPermissions() }
                }
                Button("Continue") { advanceFromPermissions() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(state.cameraAuthorized && state.accessibilityGranted))
            case .download:
                Button("Continue") { step = .tryIt }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.needsSetup)
            case .tryIt:
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func advanceFromPermissions() {
        step = .download
        if state.needsSetup && !state.isInstalling { state.install() }
    }
}

private struct StepBar: View {
    let current: WelcomeView.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeView.Step.allCases, id: \.self) { s in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(s.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        if s.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(s.rawValue + 1)").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(s.rawValue <= current.rawValue ? .white : .secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(s.title).font(.caption.weight(s == current ? .semibold : .regular))
                        .foregroundStyle(s == current ? .primary : .secondary)
                }
                if s != WelcomeView.Step.allCases.last {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 26, height: 1)
                }
            }
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Type by moving your lips").font(.system(size: 26, weight: .bold))
                Text("Hold a key, silently mouth what you want to write, and let go.\nThe camera reads your lips and the words appear wherever you're typing.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "speaker.slash.fill", title: "Completely silent",
                        text: "No microphone. Dictate in meetings, libraries or next to someone sleeping.")
                Feature(symbol: "lock.fill", title: "Private",
                        text: "Video is read on this Mac and never saved or uploaded.")
                Feature(symbol: "app.badge.checkmark", title: "Works in any app",
                        text: "Mail, Slack, Notes, your browser — anywhere there's a cursor.")
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }
}

private struct Feature: View {
    let symbol: String, title: String, text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}

struct PermissionsStep: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Text("Two permissions").font(.title2.weight(.bold))
            Text("macOS asks you to allow these once. Lip Dictation only uses the camera while you hold the key.")
                .foregroundStyle(.secondary)
            PermissionRow(symbol: "video.fill", title: "Camera", text: "To see your lips while you hold the key.",
                          granted: state.cameraAuthorized) {
                if Camera.authorization == .notDetermined {
                    Camera.requestAccess { _ in state.refreshPermissions() }
                } else {
                    openSettings("Privacy_Camera")
                }
            }
            PermissionRow(symbol: "accessibility", title: "Accessibility",
                          text: "To notice the hold-to-talk key and type the text where your cursor is.",
                          granted: state.accessibilityGranted) {
                Paster.askForTrust()
                openSettings("Privacy_Accessibility")
            }
            if !state.accessibilityGranted {
                Text("In System Settings, switch on **Lip Dictation** in the list. If it's already on, switch it off and on again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

struct PermissionRow: View {
    let symbol: String, title: String, text: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(granted ? .green : Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.medium))
            } else {
                Button("Allow…", action: grant).controlSize(.regular)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DownloadStep: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Text(state.needsSetup ? "Getting the lip reader" : "The lip reader is ready").font(.title2.weight(.bold))
            Text("It runs on this Mac, so it downloads once: about 0.8 GB of libraries, the 1.2 GB lip reader and a 0.7 GB language model that picks words by context. This takes a few minutes.")
                .foregroundStyle(.secondary)
            InstallRows(installer: state.installer)
            if case .failed = state.installer.libraries { retry }
            else if case .failed = state.installer.models { retry }
            else if state.needsSetup && !state.isInstalling {
                Button("Download") { state.install() }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
        }
    }

    private var retry: some View {
        Button("Try again") { state.install() }.buttonStyle(.borderedProminent)
    }
}

/// The two parallel parts of the install, with their progress.
struct InstallRows: View {
    @ObservedObject var installer: Installer

    var body: some View {
        VStack(spacing: 10) {
            row(symbol: "shippingbox.fill", title: "Python and libraries",
                detail: installer.librariesDetail.isEmpty ? "PyTorch, MediaPipe, OpenCV" : installer.librariesDetail,
                state: installer.libraries, progress: nil)
            row(symbol: "brain.head.profile", title: "Lip-reading and language models",
                detail: modelDetail, state: installer.models, progress: installer.modelProgress)
        }
    }

    private var modelDetail: String {
        let total = Double(Installer.modelBytes) / 1e9
        if installer.models == .running {
            return String(format: "%.2f of %.1f GB", installer.modelProgress * total, total)
        }
        return String(format: "Lip reader and language model · %.1f GB", total)
    }

    private func row(symbol: String, title: String, detail: String, state: Installer.StepState, progress: Double?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    switch state {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .running: if progress == nil { ProgressView().controlSize(.small) }
                    case .waiting: Text("Waiting").font(.caption).foregroundStyle(.secondary)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(3)
                } else {
                    if let progress, state == .running { ProgressView(value: progress) }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TryStep: View {
    @ObservedObject var state: AppState
    @State private var shown = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Try it").font(.title2.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    if state.cameraAuthorized {
                        CameraPreview(session: state.camera.session)
                        MouthGuide()
                    } else {
                        Color.black.opacity(0.85)
                        Label("Camera not allowed", systemImage: "video.slash").foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width: 260, height: 195)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 12) {
                    HowTo(key: state.settings.holdKey)
                    Text("Silently mouth:").font(.callout).foregroundStyle(.secondary)
                    Text("“Hello, how are you today?”").font(.title3.weight(.semibold))
                    Text("Move your lips clearly, a little more than when speaking, and pause before letting go.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            result
            Spacer(minLength: 0)
        }
        .onAppear { state.camera.previewAppeared(cameraID: state.settings.cameraID) }
        .onDisappear { state.camera.previewDisappeared() }
    }

    @ViewBuilder private var result: some View {
        if state.phase == .listening || state.phase == .starting {
            Label("Listening…", systemImage: "record.circle").foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
        } else if state.phase == .reading {
            HStack { ProgressView().controlSize(.small); Text("Reading your lips…") }.frame(maxWidth: .infinity, alignment: .leading)
        } else if let t = state.lastTry {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.text).font(.title3.weight(.medium)).textSelection(.enabled)
                Text("Lips read: \(t.lips.lowercased())").font(.caption).foregroundStyle(.secondary)
                if !state.hasAPIKey {
                    Text("Tip: add an Anthropic API key in Settings › Cleanup and Claude will fix words that look alike on the lips.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// An oval showing where to put your face.
struct MouthGuide: View {
    var body: some View {
        GeometryReader { g in
            Ellipse()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: g.size.width * 0.42, height: g.size.height * 0.62)
                .position(x: g.size.width / 2, y: g.size.height * 0.5)
        }
        .allowsHitTesting(false)
    }
}
