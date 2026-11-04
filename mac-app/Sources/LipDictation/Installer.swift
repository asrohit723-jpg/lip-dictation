import CryptoKit
import Foundation

/// Sets up the lip reader on first launch: a private Python with the engine's
/// libraries (fetched by the bundled uv) and the model weights, each checked
/// against its SHA-256. Both run at the same time. After an app update that
/// changes the engine's libraries, only the libraries are reinstalled.
final class Installer: NSObject, ObservableObject {
    enum StepState: Equatable {
        case waiting, running, done
        case failed(String)
    }

    struct ModelFile {
        var path: String
        var url: String
        var sha256: String
        var size: Int64
    }

    static let modelFiles: [ModelFile] = [
        ModelFile(path: "vsr/model.pth", url: "https://huggingface.co/Amanvir/LRS3_V_WER19.1/resolve/main/model.pth",
                  sha256: "e740cef369abeabd0ba2c18e37a0661342e1d94d432d6caa77755a11821d8fe3", size: 1_001_908_942),
        ModelFile(path: "vsr/model.json", url: "https://huggingface.co/Amanvir/LRS3_V_WER19.1/resolve/main/model.json",
                  sha256: "e062e8c58579f54cb51087e639e674781189809905db4162efe0fe1325356d4f", size: 5_512),
        ModelFile(path: "lm/model.pth", url: "https://huggingface.co/Amanvir/lm_en_subword/resolve/main/model.pth",
                  sha256: "c75aa39020dec98f432c8689b145d3f4cc407d4daa90a0c64202386c34f83c18", size: 215_076_928),
        ModelFile(path: "lm/model.json", url: "https://huggingface.co/Amanvir/lm_en_subword/resolve/main/model.json",
                  sha256: "6e2d2004e4066af3e5a3d74c53b0d648fd53904da07178671d1cbe28a206d548", size: 951),
        ModelFile(path: "face_landmarker.task",
                  url: "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task",
                  sha256: "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff", size: 3_758_596),
    ]
    static var modelBytes: Int64 { modelFiles.reduce(0) { $0 + $1.size } }

    @Published private(set) var libraries: StepState = .waiting
    @Published private(set) var librariesDetail = ""
    @Published private(set) var models: StepState = .waiting
    @Published private(set) var modelProgress: Double = 0
    @Published private(set) var running = false

    private var downloadedBefore: Int64 = 0
    private var currentTask: URLSessionDownloadTask?
    private var currentContinuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    // MARK: What's installed

    /// A hash of the bundled requirements file; a change means the libraries need reinstalling.
    static var requirementsHash: String {
        let url = Paths.engineSource.appendingPathComponent("requirements.txt")
        let data = (try? Data(contentsOf: url)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Record: Codable { var requirements: String }

    static var librariesInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: Paths.python.path),
              let data = try? Data(contentsOf: Paths.installRecord),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return record.requirements == requirementsHash
    }

    static var modelsInstalled: Bool {
        modelFiles.allSatisfy { f in
            let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.models.appendingPathComponent(f.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == f.size
        }
    }

    static var isInstalled: Bool { librariesInstalled && modelsInstalled }

    /// Whether this is a first install (show the big download) or a quick library refresh.
    static var hasEverInstalled: Bool { FileManager.default.fileExists(atPath: Paths.venv.path) }

    // MARK: Run

    func run(completion: @escaping (Bool) -> Void) {
        guard !running else { return }
        running = true
        libraries = Self.librariesInstalled ? .done : .waiting
        models = Self.modelsInstalled ? .done : .waiting
        modelProgress = models == .done ? 1 : 0
        Task {
            async let libs: Bool = libraries == .done ? true : installLibraries()
            async let weights: Bool = models == .done ? true : downloadModels()
            let ok = await (libs, weights)
            await MainActor.run {
                running = false
                completion(ok.0 && ok.1)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
    }

    private func set(_ update: @escaping (Installer) -> Void) {
        DispatchQueue.main.async { update(self) }
    }

    // MARK: Libraries

    private func installLibraries() async -> Bool {
        set { $0.libraries = .running; $0.librariesDetail = "Getting Python 3.11…" }
        Paths.ensure(Paths.support)
        let env = [
            "UV_PYTHON_INSTALL_DIR": Paths.pythonInstalls.path,
            "UV_CACHE_DIR": Paths.cache.path,
            "UV_NO_PROGRESS": "1",
        ]
        do {
            if !FileManager.default.isExecutableFile(atPath: Paths.python.path) {
                try await runUV(["venv", "--python", "3.11", "--python-preference", "only-managed", "--seed",
                                 Paths.venv.path], env: env)
            }
            set { $0.librariesDetail = "Installing PyTorch, MediaPipe and OpenCV…" }
            try await runUV(["pip", "install", "--python", Paths.python.path, "-r",
                             Paths.engineSource.appendingPathComponent("requirements.txt").path], env: env)
            set { $0.librariesDetail = "Checking…" }
            try await run(Paths.python, ["-c", "import torch, mediapipe, cv2, anthropic"], env: [:])
            let record = try JSONEncoder().encode(Record(requirements: Self.requirementsHash))
            try record.write(to: Paths.installRecord, options: .atomic)
            try? FileManager.default.removeItem(at: Paths.cache)    // ~1 GB of downloaded wheels
            set { $0.libraries = .done; $0.librariesDetail = "" }
            return true
        } catch {
            Log.write("library install failed: \(error.localizedDescription)")
            set { $0.libraries = .failed(error.localizedDescription) }
            return false
        }
    }

    private func runUV(_ args: [String], env: [String: String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: Paths.uv.path) else {
            throw Self.error("The installer (uv) is missing from the app. Download the app again.")
        }
        try await run(Paths.uv, args, env: env)
    }

    private func run(_ exe: URL, _ args: [String], env extra: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            extra.forEach { env[$0] = $1 }
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let tail = Tail()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                Log.raw(d)
                tail.append(d)
            }
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let lines = tail.text
                        .split(separator: "\n").suffix(2).joined(separator: " ")
                    cont.resume(throwing: Self.error(lines.isEmpty ? "\(exe.lastPathComponent) failed." : lines))
                }
            }
            Log.write("run \(exe.lastPathComponent) \(args.joined(separator: " "))")
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: Models

    private func downloadModels() async -> Bool {
        set { $0.models = .running }
        Paths.ensure(Paths.models)
        downloadedBefore = 0
        do {
            for file in Self.modelFiles {
                let dest = Paths.models.appendingPathComponent(file.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)??.int64Value
                if size == file.size {
                    downloadedBefore += file.size
                    continue
                }
                let tmp = try await download(URL(string: file.url)!)
                guard try Self.sha256(of: tmp) == file.sha256 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw Self.error("\(file.path) didn't match its checksum. Try again.")
                }
                Paths.ensure(dest.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                downloadedBefore += file.size
            }
            set { $0.models = .done; $0.modelProgress = 1 }
            return true
        } catch {
            let message = (error as NSError).code == NSURLErrorCancelled ? "Cancelled." : error.localizedDescription
            Log.write("model download failed: \(message)")
            set { $0.models = .failed(message) }
            return false
        }
    }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            currentContinuation = cont
            let task = session.downloadTask(with: url)
            currentTask = task
            task.resume()
        }
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "Installer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The last few KB a command printed, for its error message.
private final class Tail {
    private var data = Data()
    private let lock = NSLock()

    func append(_ d: Data) {
        lock.withLock {
            data.append(d)
            if data.count > 4000 { data = data.suffix(4000) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

extension Installer: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = Double(downloadedBefore + totalBytesWritten) / Double(Self.modelBytes)
        set { $0.modelProgress = min(fraction, 1) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw Self.error("The download server answered \(status).") }
            try FileManager.default.moveItem(at: location, to: keep)
            currentContinuation?.resume(returning: keep)
        } catch {
            currentContinuation?.resume(throwing: error)
        }
        currentContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            currentContinuation?.resume(throwing: error)
            currentContinuation = nil
        }
    }
}
