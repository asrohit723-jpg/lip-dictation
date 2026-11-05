import SwiftUI

/// Pick which fixes to share, then open a pre-filled GitHub issue to submit them.
struct ShareFixesView: View {
    @ObservedObject var dictionary: PersonalDictionary
    @State private var chosen: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var candidates: [PersonalDictionary.Fix] { dictionary.unshared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share fixes with everyone").font(.headline)
            Text("Fixes that several people make go into the shared dictionary that ships with every update, so Lip Dictation misreads those words less for everyone. Untick anything personal, like names. This opens a GitHub issue with just these words for you to submit; it needs a GitHub account, and your username shows on the issue.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                Text("Every fix you've made has been shared already.").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                List(candidates) { fix in
                    Toggle(isOn: Binding(get: { chosen.contains(fix.heard) },
                                         set: { on in if on { chosen.insert(fix.heard) } else { chosen.remove(fix.heard) } })) {
                        HStack(spacing: 8) {
                            Text(fix.heard).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(fix.fixed).fontWeight(.medium)
                        }
                    }
                }
                .frame(height: min(CGFloat(candidates.count) * 30 + 12, 240))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open GitHub to submit") {
                    let picked = candidates.filter { chosen.contains($0.heard) }
                    if let url = SharedFixes.issueURL(for: picked) {
                        NSWorkspace.shared.open(url)
                        dictionary.markShared(Set(picked.map(\.heard)))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { chosen = Set(candidates.map(\.heard)) }
    }
}
