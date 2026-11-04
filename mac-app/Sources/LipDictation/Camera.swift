import AVFoundation
import AppKit

/// The camera. It starts with the first dictation and stops after a minute
/// without one (or stays on, if you choose), so back-to-back dictations start
/// at once and the camera light is off the rest of the time.
///
/// While recording, the brightness plane of every frame (640×480, 8-bit) goes to
/// `onFrame`; the lip reader only needs grayscale.
final class Camera: NSObject, ObservableObject {
    enum Problem: Error, Equatable {
        case notAuthorized, noCamera, failed(String)
        var message: String {
            switch self {
            case .notAuthorized: return "Lip Dictation can't use the camera. Allow it in System Settings › Privacy & Security › Camera."
            case .noCamera: return "No camera found."
            case .failed(let m): return m
            }
        }
    }

    let session = AVCaptureSession()
    @Published private(set) var running = false
    @Published private(set) var problem: Problem?

    /// Called on the camera queue with (seconds, width, height, grayscale pixels) while recording.
    var onFrame: ((Double, Int, Int, Data) -> Void)?
    var idleSeconds: TimeInterval = 60
    var keepOn = false

    private let queue = DispatchQueue(label: "camera")
    private let output = AVCaptureVideoDataOutput()
    private var configuredID: String?
    private let lock = NSLock()
    private var _recording = false
    private var firstFrame: (() -> Void)?
    private var idleTimer: Timer?
    /// Previews (Settings, setup) that need the camera on while they're visible.
    private var previewUsers = 0

    private var recording: Bool {
        get { lock.withLock { _recording } }
        set { lock.withLock { _recording = newValue } }
    }

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// The camera to use: the chosen one if present, else the built-in one, else any.
    static func device(id: String) -> AVCaptureDevice? {
        let all = devices()
        return all.first { $0.uniqueID == id }
            ?? all.first { $0.deviceType == .builtInWideAngleCamera }
            ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: Session

    /// Starts the camera (if needed) and calls back on main once frames flow.
    func turnOn(cameraID: String, ready: @escaping (Problem?) -> Void) {
        idleTimer?.invalidate()
        guard Self.authorization == .authorized else {
            problem = .notAuthorized
            return ready(.notAuthorized)
        }
        queue.async { [self] in
            do {
                try configure(cameraID: cameraID)
            } catch let p as Problem {
                DispatchQueue.main.async { self.problem = p; ready(p) }
                return
            } catch {
                let p = Problem.failed(error.localizedDescription)
                DispatchQueue.main.async { self.problem = p; ready(p) }
                return
            }
            if !session.isRunning { session.startRunning() }
            let ok = session.isRunning
            DispatchQueue.main.async {
                self.running = ok
                self.problem = ok ? nil : .failed("The camera didn't start. Is another app using it?")
                ready(self.problem)
            }
        }
    }

    private func configure(cameraID: String) throws {
        guard let device = Self.device(id: cameraID) else { throw Problem.noCamera }
        if configuredID == device.uniqueID { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Problem.failed("The camera couldn't be used.") }
        session.addInput(input)
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        if session.outputs.isEmpty {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        configuredID = device.uniqueID
    }

    func turnOff() {
        idleTimer?.invalidate()
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            DispatchQueue.main.async { self.running = false }
        }
    }

    /// Switch to another camera now if the session is running.
    func switchCamera(to id: String) {
        queue.async { [self] in
            configuredID = nil
            try? configure(cameraID: id)
        }
    }

    private func scheduleIdleOff() {
        idleTimer?.invalidate()
        guard !keepOn, previewUsers == 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { [weak self] _ in
            guard let self, !self.recording, self.previewUsers == 0 else { return }
            self.turnOff()
        }
    }

    // MARK: Previews

    func previewAppeared(cameraID: String) {
        previewUsers += 1
        turnOn(cameraID: cameraID) { _ in }
    }

    func previewDisappeared() {
        previewUsers = max(0, previewUsers - 1)
        if !recording { scheduleIdleOff() }
    }

    // MARK: Recording

    func startRecording(cameraID: String, started: @escaping (Problem?) -> Void) {
        turnOn(cameraID: cameraID) { [self] problem in
            if let problem { return started(problem) }
            lock.withLock {
                _recording = true
                firstFrame = { DispatchQueue.main.async { started(nil) } }
            }
        }
    }

    func stopRecording() {
        recording = false
        lock.withLock { firstFrame = nil }
        scheduleIdleOff()
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let (w, h, data) = Self.luma(pixels) else { return }
        onFrame?(time, w, h, data)
        let first: (() -> Void)? = lock.withLock { let f = firstFrame; firstFrame = nil; return f }
        first?()
    }

    /// The brightness plane, packed row by row.
    static func luma(_ buffer: CVPixelBuffer) -> (Int, Int, Data)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        var data = Data(count: w * h)
        data.withUnsafeMutableBytes { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress! + row * w, base + row * stride, w)
            }
        }
        return (w, h, data)
    }
}

/// Plays a video file as if it were the camera, for testing the whole app without one:
/// `LipDictation --dictate-file clip.mov --start 20 --end 28`.
enum VideoFile {
    static func frames(_ url: URL, start: Double, end: Double,
                       each: @escaping (Double, Int, Int, Data) -> Void, done: @escaping () -> Void) {
        DispatchQueue.global().async {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first,
                  let reader = try? AVAssetReader(asset: asset) else { return done() }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           end: CMTime(seconds: end, preferredTimescale: 600))
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
            reader.add(out)
            reader.startReading()
            let began = Date()
            while let sample = out.copyNextSampleBuffer() {
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let wait = (t - start) - Date().timeIntervalSince(began)       // real time, like a camera
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if let buf = CMSampleBufferGetImageBuffer(sample), let (w, h, d) = Camera.luma(buf) { each(t, w, h, d) }
            }
            done()
        }
    }
}
