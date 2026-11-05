import AppKit
import Foundation
import Security

/// Where things live. The engine's Python environment and the model weights go in
/// Application Support, so app updates never re-download them.
enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lip Dictation", isDirectory: true)
    }()
    static var venv: URL { support.appendingPathComponent("engine-env", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var pythonInstalls: URL { support.appendingPathComponent("python", isDirectory: true) }
    static var cache: URL { support.appendingPathComponent("cache", isDirectory: true) }
    static var models: URL { support.appendingPathComponent("models", isDirectory: true) }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var installRecord: URL { support.appendingPathComponent("installed.json") }
    static let log: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lip Dictation.log")

    /// The engine's Python source: bundled in the app, or LIPDICTATION_ENGINE for development.
    static var engineSource: URL {
        if let dev = ProcessInfo.processInfo.environment["LIPDICTATION_ENGINE"] {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("engine", isDirectory: true)
    }

    /// uv, which fetches Python and the engine's libraries. Bundled in Contents/Helpers.
    static var uv: URL {
        if let dev = ProcessInfo.processInfo.environment["LIPDICTATION_UV"] { return URL(fileURLWithPath: dev) }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uv")
    }

    static func ensure(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Appends to ~/Library/Logs/Lip Dictation.log.
enum Log {
    private static let queue = DispatchQueue(label: "log")

    static func write(_ text: String) {
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        queue.async {
            Paths.ensure(Paths.log.deletingLastPathComponent())
            if let h = try? FileHandle(forWritingTo: Paths.log) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: Paths.log)
            }
        }
    }

    static func raw(_ data: Data) {
        queue.async {
            if let h = try? FileHandle(forWritingTo: Paths.log) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        }
    }
}

/// The Anthropic API key, kept in the login keychain.
enum Keychain {
    private static let service = "Lip Dictation"
    private static let account = "anthropic-api-key"

    static func apiKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setAPIKey(_ key: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// The key you hold while mouthing words.
enum HoldKeyChoice: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, leftOption, fn

    var id: String { rawValue }
    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .leftOption: return 58
        case .fn: return 63
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }
    var name: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .leftOption: return "Left Option"
        case .fn: return "Fn (Globe)"
        }
    }
    /// What's printed on the keycap.
    var symbol: String {
        switch self {
        case .rightOption, .leftOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .fn: return "fn"
        }
    }
    var side: String? {
        switch self {
        case .rightOption, .rightCommand, .rightControl: return "right"
        case .leftOption: return "left"
        case .fn: return nil
        }
    }
}

enum InsertMode: String, CaseIterable, Identifiable {
    case paste, copy
    var id: String { rawValue }
}

/// Preferences, saved in UserDefaults.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var holdKey: HoldKeyChoice { didSet { d.set(holdKey.rawValue, forKey: "holdKey") } }
    @Published var insertMode: InsertMode { didSet { d.set(insertMode.rawValue, forKey: "insertMode") } }
    @Published var trailingSpace: Bool { didSet { d.set(trailingSpace, forKey: "trailingSpace") } }
    @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
    @Published var useClaude: Bool { didSet { d.set(useClaude, forKey: "useClaude") } }
    @Published var beam: Int { didSet { d.set(beam, forKey: "beam") } }
    @Published var cameraID: String { didSet { d.set(cameraID, forKey: "cameraID") } }
    @Published var keepCameraOn: Bool { didSet { d.set(keepCameraOn, forKey: "keepCameraOn") } }
    @Published var showPreview: Bool { didSet { d.set(showPreview, forKey: "showPreview") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    @Published var useCursorContext: Bool { didSet { d.set(useCursorContext, forKey: "useCursorContext") } }
    /// Names and terms of yours, one per line.
    @Published var customWords: String { didSet { d.set(customWords, forKey: "customWords") } }

    var wordList: [String] {
        customWords.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    init() {
        holdKey = HoldKeyChoice(rawValue: d.string(forKey: "holdKey") ?? "") ?? .rightOption
        insertMode = InsertMode(rawValue: d.string(forKey: "insertMode") ?? "") ?? .paste
        trailingSpace = d.object(forKey: "trailingSpace") as? Bool ?? true
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        useClaude = d.object(forKey: "useClaude") as? Bool ?? true
        beam = d.object(forKey: "beam") as? Int ?? 10
        cameraID = d.string(forKey: "cameraID") ?? ""
        keepCameraOn = d.bool(forKey: "keepCameraOn")
        showPreview = d.object(forKey: "showPreview") as? Bool ?? true
        onboarded = d.bool(forKey: "onboarded")
        useCursorContext = d.object(forKey: "useCursorContext") as? Bool ?? true
        customWords = d.string(forKey: "customWords") ?? ""
    }
}

/// Past dictations, newest first, kept on this Mac.
final class History: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date: Date
        var text: String
        var lips: String
        var app: String
        var seconds: Double
    }

    @Published private(set) var entries: [Entry] = []
    private let limit = 500

    init() {
        if let data = try? Data(contentsOf: Paths.history),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ e: Entry) {
        entries.insert(e, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        Paths.ensure(Paths.support)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Paths.history, options: .atomic) }
    }
}

enum Sound {
    static func play(_ name: String, enabled: Bool) {
        guard enabled, let s = NSSound(named: name) else { return }
        s.volume = 0.35
        s.play()
    }
}
