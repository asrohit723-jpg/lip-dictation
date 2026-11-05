import AppKit
import Combine
import SwiftUI

/// Ties the pieces together: hold the key → camera frames stream to the engine →
/// release → the engine reads the lips → the text is pasted and kept in History.
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle, starting, listening, reading
    }

    let settings = Settings()
    let engine = Engine()
    let installer = Installer()
    let camera = Camera()
    let history = History()
    let hud = HUDController()
    lazy var holdKey = HoldKey(choice: settings.holdKey)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastResult: History.Entry?
    @Published private(set) var lastRaw: String?
    @Published var cameraAuthorized = Camera.authorization == .authorized
    @Published var accessibilityGranted = Paster.trusted
    @Published var hasAPIKey = Keychain.apiKey() != nil
    /// The setup window's "Try it" step watches this.
    @Published private(set) var lastTry: (text: String, lips: String)?

    private var dictationID = 0
    private var pressedAt: Date?
    private var maxTimer: Timer?
    private var faceSeen = true
    /// Captured when the key goes down, before anything changes focus.
    private var context: String?
    private var targetApp = ""
    private var cancellables = Set<AnyCancellable>()

    static let tail: TimeInterval = 0.4        // keep filming after release: the last word needs it
    static let minHold: TimeInterval = 0.45
    static let maxHold: TimeInterval = 60

    var needsSetup: Bool { !Installer.isInstalled }
    var isInstalling: Bool { installer.running }

    init() {
        engine.onResult = { [weak self] r in self?.finished(r) }
        engine.onFailure = { [weak self] f in self?.failed(f) }
        engine.onFace = { [weak self] seen in self?.face(seen) }
        camera.onFrame = { [weak self] t, w, h, data in self?.engine.frame(time: t, width: w, height: h, pixels: data) }

        holdKey.onDown = { [weak self] in self?.keyDown() }
        holdKey.onUp = { [weak self] in self?.keyUp() }
        holdKey.onCancel = { [weak self] quietly in self?.cancel(quietly: quietly) }

        settings.$holdKey.sink { [weak self] in self?.holdKey.choice = $0 }.store(in: &cancellables)
        settings.$keepCameraOn.sink { [weak self] on in
            self?.camera.keepOn = on
        }.store(in: &cancellables)
        settings.$useClaude.combineLatest(settings.$beam, settings.$customWords).dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.configureEngine() }
            .store(in: &cancellables)
        settings.$cameraID.dropFirst().sink { [weak self] id in self?.camera.switchCamera(to: id) }
            .store(in: &cancellables)
        // Republish child changes so views watching AppState refresh.
        [engine.objectWillChange, installer.objectWillChange, camera.objectWillChange, history.objectWillChange]
            .forEach { $0.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables) }
        engine.$state.removeDuplicates().sink { [weak self] s in
            if s == .ready { DispatchQueue.main.async { self?.configureEngine() } }
        }.store(in: &cancellables)
    }

    // MARK: Lifecycle

    func launch() {
        holdKey.start()
        // During an update that needs new parts, run on what's already installed meanwhile.
        if Installer.isInstalled || Installer.canRunMeanwhile {
            engine.start()
        }
    }

    /// First install, repair, or an update that needs new parts. Dictation keeps working during an
    /// update (the running engine is restarted when it's done); a repair stops it first.
    func install(stopEngine: Bool = false, _ done: ((Bool) -> Void)? = nil) {
        if stopEngine || !Installer.hasEverInstalled { engine.stop() }
        installer.run { [weak self] ok in
            guard let self else { return }
            if ok { self.engine.isReady ? self.engine.restart() : self.engine.start() }
            done?(ok)
        }
    }

    /// An earlier version is installed and this one needs more (new libraries or models).
    var isUpgrading: Bool { Installer.hasEverInstalled && (isInstalling || needsSetup) }

    func configureEngine() {
        engine.configure(useClaude: settings.useClaude, apiKey: settings.useClaude ? Keychain.apiKey() : nil,
                         beam: settings.beam, words: settings.wordList)
    }

    func saveAPIKey(_ key: String?) {
        Keychain.setAPIKey(key?.trimmingCharacters(in: .whitespacesAndNewlines))
        hasAPIKey = Keychain.apiKey() != nil
        configureEngine()
    }

    func refreshPermissions() {
        cameraAuthorized = Camera.authorization == .authorized
        let trusted = Paster.trusted
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            if trusted { holdKey.start() }    // monitors installed before trust don't fire
        }
    }

    // MARK: Status for the menu bar and menu

    var menuBarSymbol: String {
        switch phase {
        case .listening, .starting: return "mouth.fill"
        case .reading: return "ellipsis.bubble"
        case .idle:
            if needsAttention { return "exclamationmark.triangle" }
            return "mouth"
        }
    }

    var needsAttention: Bool {
        if case .failed = engine.state { return true }
        return !cameraAuthorized || !accessibilityGranted || (needsSetup && !isInstalling && !Installer.hasEverInstalled)
    }

    struct Status {
        var text: String
        var color: Color
        var busy = false
    }

    var status: Status {
        if isInstalling { return Status(text: Installer.hasEverInstalled ? "Updating…" : "Setting up…", color: .blue, busy: true) }
        if needsSetup && !Installer.hasEverInstalled { return Status(text: "Needs setup", color: .orange) }
        if !cameraAuthorized { return Status(text: "Needs camera access", color: .orange) }
        if !accessibilityGranted { return Status(text: "Needs Accessibility", color: .orange) }
        switch phase {
        case .starting, .listening: return Status(text: "Listening", color: .red)
        case .reading: return Status(text: "Reading", color: .blue, busy: true)
        case .idle: break
        }
        switch engine.state {
        case .ready: return Status(text: "Ready", color: .green)
        case .starting(let m): return Status(text: m.replacingOccurrences(of: "…", with: ""), color: .blue, busy: true)
        case .failed: return Status(text: "Not working", color: .red)
        case .stopped: return Status(text: "Stopped", color: .secondary)
        }
    }

    // MARK: Dictation

    private func keyDown() {
        guard phase == .idle else { return }
        if needsSetup && !engine.isReady {
            hud.show(.message(symbol: "arrow.down.circle", text: "Finish setting up Lip Dictation first", tint: .orange))
            return
        }
        guard engine.isReady else {
            let text: String
            if case .failed(let m) = engine.state { text = m } else { text = "The lip reader is still starting…" }
            hud.show(.message(symbol: "hourglass", text: text, tint: .orange))
            return
        }
        guard Camera.authorization == .authorized else {
            hud.show(.message(symbol: "video.slash", text: "Allow camera access in Settings", tint: .orange))
            return
        }
        dictationID += 1
        let id = dictationID
        pressedAt = Date()
        targetApp = Paster.frontApp
        context = settings.useCursorContext && Paster.trusted && !NSApp.isActive ? FocusContext.textBeforeCursor() : nil
        faceSeen = true
        phase = .starting
        engine.begin(id: id)
        hud.show(.starting)
        camera.startRecording(cameraID: settings.cameraID) { [weak self] problem in
            guard let self, self.dictationID == id, self.phase == .starting else { return }
            if let problem {
                self.phase = .idle
                self.engine.cancel()
                self.hud.show(.message(symbol: "video.slash", text: problem.message, tint: .orange))
                return
            }
            self.phase = .listening
            Sound.play("Tink", enabled: self.settings.sounds)
            self.hud.show(.listening(since: Date(), faceOK: true))
        }
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: Self.maxHold, repeats: false) { [weak self] _ in
            self?.keyUp()
        }
    }

    private func keyUp() {
        maxTimer?.invalidate()
        guard phase == .starting || phase == .listening, let pressedAt else { return }
        let held = Date().timeIntervalSince(pressedAt)
        self.pressedAt = nil
        if held < Self.minHold || phase == .starting {
            camera.stopRecording()
            engine.cancel()
            phase = .idle
            hud.show(.message(symbol: "hand.tap", text: "Hold \(settings.holdKey.name) while you mouth the words",
                              tint: .secondary))
            return
        }
        let id = dictationID
        phase = .reading
        hud.show(.reading)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tail) { [self] in
            camera.stopRecording()
            guard dictationID == id else { return }
            Sound.play("Pop", enabled: settings.sounds)
            engine.end(id: id, recent: history.entries.prefix(3).reversed().map(\.text), context: context, app: targetApp)
        }
    }

    private func cancel(quietly: Bool) {
        guard phase == .starting || phase == .listening else { return }
        maxTimer?.invalidate()
        pressedAt = nil
        camera.stopRecording()
        engine.cancel()
        phase = .idle
        if quietly {
            hud.hide()
        } else {
            Sound.play("Funk", enabled: settings.sounds)
            hud.show(.message(symbol: "xmark.circle", text: "Cancelled", tint: .secondary))
        }
    }

    private func face(_ seen: Bool) {
        guard phase == .listening, seen != faceSeen else { return }
        faceSeen = seen
        hud.updateFace(seen)
    }

    private func finished(_ r: Engine.Result) {
        guard r.id == dictationID, phase == .reading else { return }
        phase = .idle
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hud.show(.message(symbol: "questionmark.circle", text: "Couldn't make out any words", tint: .orange))
            return
        }
        let entry = History.Entry(date: Date(), text: text, lips: r.guesses.first ?? "", app: targetApp,
                                  seconds: r.timing["frames"].map { $0 / 25 } ?? 0)
        history.add(entry)
        lastResult = entry
        lastRaw = r.guesses.first
        lastTry = (text, r.guesses.first ?? "")
        Log.write("read \(Int(r.timing["frames"] ?? 0)) frames: encode \(r.timing["encode"] ?? 0)s search \(r.timing["search"] ?? 0)s cleanup \(r.timing["cleanup"] ?? 0)s (\(r.cleanup))")
        deliver(text)
    }

    func deliver(_ text: String) {
        let out = settings.trailingSpace ? text + " " : text
        if settings.insertMode == .paste && Paster.trusted && !NSApp.isActive {
            Paster.paste(out)
            hud.show(.done(text: text, copied: false))
        } else {
            Paster.copy(out)
            hud.show(.done(text: text, copied: true))
        }
    }

    private func failed(_ f: Engine.Failure) {
        guard f.id == nil || f.id == dictationID else { return }
        if phase == .reading || phase == .listening { phase = .idle }
        let symbol = f.kind == "face" ? "face.dashed" : f.kind == "short" ? "hand.tap" : "exclamationmark.triangle"
        hud.show(.message(symbol: symbol, text: f.message, tint: .orange))
    }

    // MARK: Testing without a camera

    /// Streams a video file through the same path as a real dictation and prints the result.
    func dictate(file: URL, start: Double, end: Double, done: @escaping (String) -> Void) {
        dictationID += 1
        let id = dictationID
        phase = .listening
        engine.begin(id: id)
        hud.show(.listening(since: Date(), faceOK: true))
        let previous = engine.onResult
        engine.onResult = { [weak self] r in       // a test: no history, no clipboard
            self?.engine.onResult = previous
            self?.phase = .idle
            self?.hud.show(.done(text: r.text, copied: false))
            done("\(r.text)\n  lips: \(r.guesses.first ?? "")\n  timing: \(r.timing)")
        }
        VideoFile.frames(file, start: start, end: end, each: { [weak self] t, w, h, d in
            self?.engine.frame(time: t, width: w, height: h, pixels: d)
        }, done: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .reading
                self.hud.show(.reading)
                self.engine.end(id: id, recent: [], context: nil, app: "")
            }
        })
    }
}
