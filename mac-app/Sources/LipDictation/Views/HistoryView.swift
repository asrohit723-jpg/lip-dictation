import SwiftUI

/// Everything you've dictated, kept only on this Mac.
struct HistoryView: View {
    @ObservedObject var history: History
    var correct: (History.Entry, String) -> Void = { _, _ in }
    @State private var editing: History.Entry?
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var confirmClear = false

    private var filtered: [History.Entry] {
        search.isEmpty ? history.entries
            : history.entries.filter { $0.text.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "mouth",
                                       description: Text("What you dictate shows up here."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(selection: $selection) {
                    ForEach(grouped, id: \.0) { day, entries in
                        Section(day) {
                            ForEach(entries) { e in HistoryRow(entry: e, fix: { editing = e }).tag(e.id) }
                        }
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let e = history.entries.first(where: { ids.contains($0.id) }) {
                        Button("Fix the Text…") { editing = e }
                    }
                    Button("Copy") { copy(ids) }
                    Divider()
                    Button("Delete", role: .destructive) { history.delete(ids) }
                }
                .onDeleteCommand { history.delete(selection) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: { Label("Clear History", systemImage: "trash") }
                    .disabled(history.entries.isEmpty)
            }
        }
        .sheet(item: $editing) { e in
            FixSheet(entry: e) { text in correct(e, text) }
        }
        .confirmationDialog("Delete all \(history.entries.count) dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var grouped: [(String, [History.Entry])] {
        var out: [(String, [History.Entry])] = []
        for e in filtered {
            let day = Self.dayName(e.date)
            if out.last?.0 == day { out[out.count - 1].1.append(e) } else { out.append((day, [e])) }
        }
        return out
    }

    static func dayName(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .complete, time: .omitted)
    }

    private func copy(_ ids: Set<UUID>) {
        let text = history.entries.filter { ids.contains($0.id) }.reversed().map(\.text).joined(separator: "\n")
        Paster.copy(text)
    }
}

/// Fix what a dictation should have said; the changed words go into your dictionary.
private struct FixSheet: View {
    let entry: History.Entry
    let save: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix this dictation").font(.headline)
            Text("Change the words it got wrong. Lip Dictation remembers the fix for next time.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(text); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || text == entry.text)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { text = entry.text }
    }
}

private struct HistoryRow: View {
    let entry: History.Entry
    var fix: () -> Void = {}
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                    if !entry.app.isEmpty { Text("·"); Text(entry.app) }
                    if !entry.lips.isEmpty {
                        Text("·")
                        Text("lips: \(entry.lips.lowercased())").lineLimit(1).help(entry.lips.lowercased())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: fix) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Fix the text")
                .opacity(hover ? 1 : 0)
            Button {
                Paster.copy(entry.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .opacity(hover || copied ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hover = $0 }
    }
}
