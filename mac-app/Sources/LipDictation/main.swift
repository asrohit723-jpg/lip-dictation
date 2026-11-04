import AppKit
import Combine
import SwiftUI

/// Menu bar icon and popover, plus the setup, Settings and History windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var windows: [String: NSWindow] = [:]
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        updateIcon()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: menuView())

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        state.camera.$running.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.hud.session = self?.state.camera.session }
            .store(in: &cancellables)
        state.settings.$showPreview.sink { [weak self] in self?.state.hud.showPreview = $0 }.store(in: &cancellables)

        state.launch()
        Updater.shared.startChecking()

        if !state.settings.onboarded || state.needsSetup || !state.cameraAuthorized || !state.accessibilityGranted {
            showSetup()
        }
        // An app update that changed the engine's libraries: refresh them quietly.
        if state.settings.onboarded && Installer.hasEverInstalled && !Installer.librariesInstalled {
            state.install()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        state.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.engine.stop()
    }

    /// Opening the app again from Finder or Spotlight shows the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { togglePopover() }
        return true
    }

    private func menuView() -> MenuView {
        MenuView(state: state,
                 openSetup: { [weak self] in self?.showSetup() },
                 openSettings: { [weak self] in self?.showSettings() },
                 openHistory: { [weak self] in self?.showHistory() })
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: state.menuBarSymbol, accessibilityDescription: "Lip Dictation")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshPermissions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func showSetup() {
        show("setup", title: "Set Up Lip Dictation") {
            WelcomeView(state: state, step: initialStep) { [weak self] in
                self?.state.settings.onboarded = true
                self?.windows["setup"]?.close()
            }
        }
    }

    private var initialStep: WelcomeView.Step {
        guard state.settings.onboarded else { return .welcome }
        if !state.cameraAuthorized || !state.accessibilityGranted { return .permissions }
        return state.needsSetup ? .download : .tryIt
    }

    @objc func showSettings() {
        show("settings", title: "Lip Dictation Settings") { SettingsView(state: state) }
    }

    @objc func showHistory() {
        show("history", title: "History", resizable: true) { HistoryView(history: state.history) }
    }

    @objc private func checkForUpdates() {
        Updater.shared.check()
        showSettings()
    }

    private func show<V: View>(_ name: String, title: String, resizable: Bool = false, view: () -> V) {
        popover.performClose(nil)
        let window = windows[name] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view()))
            w.title = title
            w.styleMask = [.titled, .closable, .miniaturizable]
            if resizable { w.styleMask.insert(.resizable) }
            w.isReleasedWhenClosed = false
            w.center()
            windows[name] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "History", action: #selector(showHistory), keyEquivalent: "y").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Lip Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // Edit menu, so ⌘V and ⌘A work in the API key field and the search box.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }
}

signal(SIGPIPE, SIG_IGN)   // a dead engine must not take the app down with it
let app = NSApplication.shared
let args = CommandLine.arguments

func argument(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let dir = argument("--snapshot") {
    app.setActivationPolicy(.accessory)
    Snapshot.run(dir: dir)
    exit(0)
}
// The first-launch setup without the window, for testing: prints progress, exits 0 when installed.
if args.contains("--install") {
    let installer = AppState.shared.installer
    let ticker = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        print(String(format: "libraries: %@ %@ | models: %@ %.0f%%", "\(installer.libraries)", installer.librariesDetail,
                     "\(installer.models)", installer.modelProgress * 100))
    }
    let started = Date()
    installer.run { ok in
        ticker.invalidate()
        print("libraries: \(installer.libraries) | models: \(installer.models)")
        print(ok ? "installed in \(Int(Date().timeIntervalSince(started)))s" : "install failed")
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
}
// Reads a video file through the real engine and HUD, as if it came from the camera.
if let file = argument("--dictate-file") {
    app.setActivationPolicy(.accessory)
    let state = AppState.shared
    var watch: AnyCancellable?
    watch = state.engine.$state.sink { s in
        switch s {
        case .ready:
            watch = nil
            state.configureEngine()
            state.dictate(file: URL(fileURLWithPath: file), start: Double(argument("--start") ?? "0") ?? 0,
                          end: Double(argument("--end") ?? "10") ?? 10) { result in
                print(result)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { state.engine.stop(); exit(0) }
            }
        case .failed(let m):
            print("engine failed: \(m)")
            exit(1)
        default:
            break
        }
    }
    state.engine.start()
    app.run()
}
if args.contains("--check-update") {
    Updater.shared.check { release in
        print("current \(Updater.shared.currentVersion); latest \(release?.version ?? "none newer"); status \(Updater.shared.status)")
        exit(0)
    }
    RunLoop.main.run()
}
if args.contains("--install-update") {
    let updater = Updater.shared
    updater.check { release in
        guard release != nil else { print("nothing to install: \(updater.status)"); exit(1) }
        var watcher: AnyCancellable?
        watcher = updater.$status.sink { status in
            if case .failed(let message) = status { print("failed: \(message)"); watcher?.cancel(); exit(1) }
        }
        updater.install()
    }
    RunLoop.main.run()
}
if let i = args.firstIndex(of: "--verify-update"), i + 2 < args.count {
    do {
        let app = try Updater.unpackAndVerify(URL(fileURLWithPath: args[i + 1]), expecting: args[i + 2])
        print("verified: \(app.path)")
        exit(0)
    } catch {
        print("rejected: \(error.localizedDescription)")
        exit(1)
    }
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
