import AppKit
import SwiftUI

/// Debug aid: `LipDictation --snapshot <dir>` renders each screen to a PNG and exits.
enum Snapshot {
    static func run(dir: String) {
        let state = AppState.shared
        let bg = Color(nsColor: .windowBackgroundColor)
        render(MenuView(state: state, openSetup: {}, openSettings: {}, openHistory: {}).background(bg), "menu", dir)
        for step in WelcomeView.Step.allCases {
            render(WelcomeView(state: state, step: step, done: {}).background(bg), "setup-\(step.rawValue + 1)", dir)
        }
        render(GeneralTab(state: state, settings: state.settings).frame(width: 560, height: 520).background(bg), "settings-general", dir)
        render(CleanupTab(state: state, settings: state.settings).frame(width: 560, height: 470).background(bg), "settings-cleanup", dir)
        render(AdvancedTab(state: state, settings: state.settings).frame(width: 560, height: 360).background(bg), "settings-advanced", dir)
        render(HistoryView(history: state.history).frame(width: 560, height: 420).background(bg), "history", dir)
        let pills: [(String, HUDController.Content)] = [
            ("starting", .starting),
            ("listening", .listening(since: Date().addingTimeInterval(-3), faceOK: true)),
            ("noface", .listening(since: Date().addingTimeInterval(-5), faceOK: false)),
            ("reading", .reading),
            ("done", .done(text: "Born in New York City and raised mostly in Chicago, Nancy Davis graduated from Smith College in 1943.", copied: false)),
            ("message", .message(symbol: "hand.tap", text: "Hold Right Option while you mouth the words", tint: .secondary)),
        ]
        for (name, content) in pills {
            render(HUDPill(content: content).background(Color.gray.opacity(0.35)), "hud-\(name)", dir)
        }
    }

    private static func render<V: View>(_ view: V, _ name: String, _ dir: String) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
