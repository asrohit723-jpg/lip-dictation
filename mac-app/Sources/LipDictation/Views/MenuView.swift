import SwiftUI

/// The menu bar popover.
struct MenuView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared
    var openSetup: () -> Void
    var openSettings: () -> Void
    var openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            UpdateBanner(updater: updater)
            if state.needsSetup || state.isInstalling {
                setupCard
            } else if !state.cameraAuthorized || !state.accessibilityGranted {
                permissionsCard
            } else if case .failed(let message) = state.engine.state {
                Callout(symbol: "exclamationmark.triangle.fill", tint: .red, title: "The lip reader stopped",
                        text: message) {
                    Button("Restart it") { state.engine.restart() }.controlSize(.small)
                }
            } else {
                HowTo(key: state.settings.holdKey)
            }
            if let last = state.lastResult ?? state.history.entries.first {
                LastDictation(entry: last)
            }
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "History", symbol: "clock.arrow.circlepath", shortcut: nil, action: openHistory)
                MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,", action: openSettings)
                MenuRow(title: "Quit Lip Dictation", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            Text("Lip Dictation").font(.headline)
            Spacer()
            StatusPill(status: state.status)
        }
    }

    private var setupCard: some View {
        Callout(symbol: "arrow.down.circle.fill", tint: .accentColor,
                title: state.isInstalling ? "Setting up the lip reader…" : "Finish setting up",
                text: state.isInstalling ? "Downloading about 2 GB. You can keep working."
                                         : "Lip Dictation needs to download its lip reader (about 2 GB) once.") {
            Button(state.isInstalling ? "Show progress" : "Set up") { openSetup() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private var permissionsCard: some View {
        Callout(symbol: "lock.fill", tint: .orange, title: "Permission needed",
                text: !state.cameraAuthorized ? "Allow the camera so Lip Dictation can see your lips."
                                              : "Allow Accessibility so it can notice the key and type for you.") {
            Button("Fix it") { openSetup() }.controlSize(.small)
        }
    }
}

struct StatusPill: View {
    let status: AppState.Status

    var body: some View {
        HStack(spacing: 5) {
            if status.busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 7, height: 7)
            }
            Text(status.text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}

/// "Hold ⌥ and mouth your words" with a drawn keycap.
struct HowTo: View {
    let key: HoldKeyChoice

    var body: some View {
        HStack(spacing: 12) {
            Keycap(key: key)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold \(key.name)").font(.callout.weight(.semibold))
                Text("silently mouth your words, then let go").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Keycap: View {
    let key: HoldKeyChoice
    var size: CGFloat = 40

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(key.symbol).font(.system(size: size * 0.38, weight: .medium))
            if let side = key.side {
                Text(side).font(.system(size: size * 0.2)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size * 1.25, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 0.5, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).strokeBorder(.primary.opacity(0.12)))
    }
}

struct LastDictation: View {
    let entry: History.Entry
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last dictation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
            Text(entry.text).font(.callout).lineLimit(4).textSelection(.enabled)
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    Paster.copy(entry.text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Callout<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MenuRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).font(.caption) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
