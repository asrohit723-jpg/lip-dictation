import Foundation

/// Runs the Python lip-reading engine as a child process and talks to it over
/// stdin/stdout (see lipdictation/engine.py for the protocol). The app owns the
/// camera and streams grayscale frames in; the engine answers with text.
final class Engine: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting(String)
        case ready
        case failed(String)
    }

    struct Result {
        var id: Int
        var text: String
        var guesses: [String]
        var cleanup: String
        var timing: [String: Double]
    }

    struct Failure {
        var id: Int?
        var kind: String
        var message: String
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var usingGPU = false
    @Published private(set) var cleanupMode = "basic"

    var onFace: ((Bool) -> Void)?
    var onResult: ((Result) -> Void)?
    var onFailure: ((Failure) -> Void)?

    private var process: Process?
    private var _input: FileHandle?
    private let inputLock = NSLock()
    private var input: FileHandle? {   // written on main, read from the write queue
        get { inputLock.withLock { _input } }
        set { inputLock.withLock { _input = newValue } }
    }
    private let writes = DispatchQueue(label: "engine.write")
    private var buffer = Data()
    private var stopping = false
    private var restarts = 0
    private var pendingConfig: [String: Any]?

    var isReady: Bool { state == .ready }

    func start() {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.python.path) else {
            state = .failed("The lip reader isn't installed yet.")
            return
        }
        stopping = false
        state = .starting("Starting the lip reader…")
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = ["-m", "lipdictation.engine", "--models", Paths.models.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = Paths.engineSource.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")   // the key comes from Settings, via config
        p.environment = env
        p.currentDirectoryURL = Paths.support

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.received(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { Log.raw(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.terminated(status: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
            Log.write("engine started (pid \(p.processIdentifier))")
        } catch {
            state = .failed("The lip reader didn't start: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopping = true
        try? input?.close()
        input = nil
        process?.terminate()
        process = nil
        state = .stopped
    }

    func restart() {
        stop()
        restarts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.start() }
    }

    private func terminated(status: Int32) {
        process = nil
        input = nil
        guard !stopping else { return }
        Log.write("engine exited with status \(status)")
        if restarts < 3 {
            restarts += 1
            state = .starting("Restarting the lip reader…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.start() }
        } else if case .failed = state {
        } else {
            state = .failed("The lip reader keeps stopping. See the log in Settings › Advanced.")
        }
    }

    // MARK: Messages in

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            DispatchQueue.main.async { self.handle(msg) }
        }
    }

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "status":
            state = .starting(msg["message"] as? String ?? "Starting…")
        case "ready":
            usingGPU = msg["gpu"] as? Bool ?? false
            state = .ready
            restarts = 0
            if let c = pendingConfig { send(c) }
        case "configured":
            cleanupMode = msg["cleanup"] as? String ?? "basic"
        case "face":
            onFace?(msg["seen"] as? Bool ?? false)
        case "result":
            onResult?(Result(id: msg["id"] as? Int ?? 0, text: msg["text"] as? String ?? "",
                             guesses: msg["guesses"] as? [String] ?? [],
                             cleanup: msg["cleanup"] as? String ?? "basic",
                             timing: msg["timing"] as? [String: Double] ?? [:]))
        case "error":
            onFailure?(Failure(id: msg["id"] as? Int, kind: msg["kind"] as? String ?? "error",
                               message: msg["message"] as? String ?? "Something went wrong."))
        case "fatal":
            stopping = true
            state = .failed(msg["message"] as? String ?? "The lip reader didn't start.")
        default:
            break
        }
    }

    // MARK: Messages out

    func configure(useClaude: Bool, apiKey: String?, beam: Int) {
        let c: [String: Any] = ["type": "config", "cleanup": useClaude ? "auto" : "basic",
                                "api_key": apiKey ?? "", "beam": beam]
        pendingConfig = c
        if isReady { send(c) }
    }

    func begin(id: Int) { send(["type": "begin", "id": id]) }
    func end(id: Int, recent: [String]) { send(["type": "end", "id": id, "recent": recent]) }
    func cancel() { send(["type": "cancel"]) }

    /// One 8-bit grayscale frame. Called from the camera queue.
    func frame(time: Double, width: Int, height: Int, pixels: Data) {
        send(["type": "frame", "t": time, "w": width, "h": height], payload: pixels)
    }

    private func send(_ header: [String: Any], payload: Data? = nil) {
        var header = header
        if let payload { header["n"] = payload.count }
        guard let json = try? JSONSerialization.data(withJSONObject: header) else { return }
        var message = Data()
        var size = UInt32(json.count).bigEndian
        message.append(Data(bytes: &size, count: 4))
        message.append(json)
        if let payload { message.append(payload) }
        writes.async { [weak self] in
            guard let input = self?.input else { return }
            do { try input.write(contentsOf: message) } catch { Log.write("engine write failed: \(error)") }
        }
    }
}
