import AppKit
import Foundation
import Security

/// In-app updates from GitHub Releases.
///
/// Every push to main builds a release signed with the app's own certificate. The
/// updater downloads it, refuses anything not signed with that certificate, swaps the
/// app in place and relaunches. Same path, same identifier, same certificate, so macOS
/// keeps the Camera and Accessibility permissions.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "asrohit723-jpg/lip-dictation"
    /// Only apps signed with this certificate (its SHA-1) are ever installed.
    static let requirement =
        #"identifier "com.rohit.lipdictation" and certificate leaf = H"D479EDAE5BC9B7997D16D525693E0866842A15F8""#

    struct Release: Equatable {
        var version: String
        var notes: String
        var zip: URL
        var page: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?
    /// 0…1 while downloading an update.
    @Published private(set) var progress: Double = 0
    private var progressWatch: NSKeyValueObservation?

    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates"); objectWillChange.send() }
    }

    /// Check shortly after launch, then every 3 hours.
    func startChecking() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.autoCheck == true { self?.check() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            if self?.autoCheck == true { self?.check() }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Checks unless it checked recently; used when the menu opens.
    func checkIfStale(after seconds: TimeInterval = 15 * 60) {
        guard autoCheck, Date().timeIntervalSince(lastChecked ?? .distantPast) > seconds else { return }
        check()
    }

    var isBusy: Bool { status == .downloading || status == .installing }

    func check(completion: ((Release?) -> Void)? = nil) {
        guard status != .downloading && status != .installing else { return }
        status = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, response, error in
            let release = Self.parse(data)
            DispatchQueue.main.async {
                self.lastChecked = Date()
                if let release, Self.isNewer(release.version, than: self.currentVersion) {
                    self.available = release
                    self.status = .idle
                } else if release != nil {
                    self.available = nil
                    self.status = .upToDate
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode
                    self.status = .failed(error?.localizedDescription ?? "GitHub answered \(code.map(String.init) ?? "nothing")")
                }
                completion?(self.available)
            }
        }.resume()
    }

    private static func parse(_ data: Data?) -> Release? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       zip: zip, page: page)
    }

    // MARK: Install

    func install() {
        guard let release = available else { return }
        status = .downloading
        progress = 0
        let task = URLSession.shared.downloadTask(with: release.zip) { file, _, error in
            do {
                guard let file else { throw Self.fail(error?.localizedDescription ?? "The download didn't finish.") }
                let newApp = try Self.unpackAndVerify(file, expecting: release.version)
                DispatchQueue.main.async {
                    self.status = .installing
                    do { try Self.swapAndRelaunch(with: newApp) } catch { self.status = .failed(error.localizedDescription) }
                }
            } catch {
                DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
            }
        }
        progressWatch = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.progress = p.fractionCompleted }
        }
        task.resume()
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Unzips the release and checks it is our app, signed with our certificate, at the expected version.
    static func unpackAndVerify(_ zip: URL, expecting version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lip-dictation-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = dir.appendingPathComponent("Lip Dictation.app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw fail("The update didn't unpack.")
        }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw fail("Couldn't read the update's signature.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw fail("The update isn't signed by Lip Dictation, so it wasn't installed.")
        }

        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard plist?["CFBundleShortVersionString"] as? String == version else {
            throw fail("The update's version doesn't match the release.")
        }
        return app
    }

    /// Once this app quits, a small script moves the new app into place and opens it.
    static func swapAndRelaunch(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw fail("Updates only work for the installed app.") }
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        /bin/mv "$2" "$2.old" && /bin/mv "$3" "$2" && /bin/rm -rf "$2.old" || /bin/mv "$2.old" "$2"
        /usr/bin/open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "swap", String(ProcessInfo.processInfo.processIdentifier), current.path, newApp.path]
        try p.run()
        NSApp.terminate(nil)
        exit(0)   // when run from the command line there's no running app to terminate
    }
}
