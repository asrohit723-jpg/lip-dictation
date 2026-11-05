import SwiftUI

/// Shown at the top of the menu when a newer version is on GitHub.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let release = updater.available {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update available · \(release.version)").font(.callout.weight(.semibold))
                    if !release.notes.isEmpty {
                        Text(release.notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    switch updater.status {
                    case .downloading, .installing:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(updater.status == .downloading ? "Downloading… \(Int(updater.progress * 100))%" : "Installing…").font(.caption)
                        }
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.red)
                        Button("Try again") { updater.install() }.controlSize(.small)
                    default:
                        Button("Update now") { updater.install() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Settings › About: version, updates and the project link.
struct AboutTab: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lip Dictation").font(.title2.weight(.semibold))
                        Text("Version \(updater.currentVersion)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Updates") {
                UpdateBanner(updater: updater)
                HStack {
                    Text(statusText).foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    Spacer()
                    Button("Check now") { updater.check() }
                        .disabled(updater.status == .checking || updater.status == .downloading || updater.status == .installing)
                }
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.autoCheck },
                                                                        set: { updater.autoCheck = $0 }))
            }
            Section {
                Link("Source and releases on GitHub",
                     destination: URL(string: "https://github.com/\(Updater.repo)")!)
            } footer: {
                Text("Updates are signed with the app's own certificate, so macOS keeps Camera and Accessibility access after updating. The lip reader and its models stay installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusIsError: Bool {
        if case .failed = updater.status { return true }
        return false
    }

    private var statusText: String {
        switch updater.status {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date."
        case .downloading: return "Downloading… \(Int(updater.progress * 100))%"
        case .installing: return "Installing…"
        case .failed(let m): return m
        case .idle:
            if updater.available != nil { return "A new version is ready." }
            if let d = updater.lastChecked {
                return "Last checked \(d.formatted(date: .omitted, time: .shortened))."
            }
            return "Not checked yet."
        }
    }
}
