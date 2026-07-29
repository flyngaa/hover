import SwiftUI

struct SidebarView: View {
    @Environment(TranscriberEngine.self) private var engine
    @State private var searchText = ""
    /// IDs matching the current search, computed off the render path.
    /// nil = no active filter. Content search reads every transcript file,
    /// so it runs debounced in a task — never during body evaluation.
    @State private var searchHits: Set<String>?
    @State private var renameTarget: SavedTranscript?
    @State private var renameText = ""
    @State private var newGroupTarget: SavedTranscript?
    @State private var newGroupName = ""
    @State private var confirmDeleteMarked = false

    private var filtered: [SavedTranscript] {
        guard let searchHits else { return engine.savedTranscripts }
        return engine.savedTranscripts.filter { searchHits.contains($0.id) }
    }

    private var orderedVisibleIDs: [String] {
        var ids: [String] = []
        ids += filtered.filter { $0.group == nil }.map(\.id)
        for group in engine.groups {
            ids += filtered.filter { $0.group == group }.map(\.id)
        }
        return ids
    }

    var body: some View {
        @Bindable var engine = engine
        List(selection: $engine.markedTranscriptIDs) {
            let rootItems = filtered.filter { $0.group == nil }
            Section("Transcripts") {
                if let title = engine.recordingTitle {
                    InProgressRow(title: title)
                }
                if engine.savedTranscripts.isEmpty {
                    if engine.recordingTitle == nil {
                        Text("No transcripts yet")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                } else {
                    ForEach(rootItems) { t in
                        row(t)
                    }
                }
            }

            ForEach(engine.groups, id: \.self) { group in
                let items = filtered.filter { $0.group == group }
                if searchHits == nil || !items.isEmpty {
                    Section(group) {
                        ForEach(items) { t in
                            row(t)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("")
        .tint(BrandColors.orange)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search transcripts")
        .task(id: searchText) {
            // Debounced, off-render search. Content matching reads every
            // transcript file, so it must never run inside `body`.
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                searchHits = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let hits = await engine.searchHits(for: query)
            guard !Task.isCancelled else { return }
            searchHits = hits
        }
        .onChange(of: engine.markedTranscriptIDs) { _, ids in
            if ids.count == 1 {
                engine.selectionAnchorID = ids.first
            }
        }
        .background(shortcutButtons)
        .alert("Rename Transcript", isPresented: .init(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let t = renameTarget { engine.rename(t, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("New Group", isPresented: .init(
            get: { newGroupTarget != nil },
            set: { if !$0 { newGroupTarget = nil } }
        )) {
            TextField("Group name", text: $newGroupName)
            Button("Create & Move") {
                if let t = newGroupTarget { engine.move(t, toGroup: newGroupName) }
                newGroupTarget = nil
            }
            Button("Cancel", role: .cancel) { newGroupTarget = nil }
        }
        .alert("Delete marked transcripts?", isPresented: $confirmDeleteMarked) {
            Button("Delete", role: .destructive) {
                engine.deleteMarkedTranscripts()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(engine.markedTranscriptIDs.count) files.")
        }
    }

    @ViewBuilder
    private func row(_ t: SavedTranscript) -> some View {
        Text(t.name)
            .lineLimit(1)
            .padding(.vertical, 2)
            .tag(t.id)
            .contextMenu {
                Button(engine.markedTranscriptIDs.contains(t.id) ? "Unmark" : "Mark") {
                    engine.toggleMark(t.id)
                }
                Button("Rename…") {
                    renameText = t.name
                    renameTarget = t
                }
                .disabled(engine.markedTranscriptIDs.count > 1)
                Menu("Move to") {
                    Button("Transcripts") { engine.move(t, toGroup: nil) }
                        .disabled(t.group == nil)
                    if !engine.groups.isEmpty { Divider() }
                    ForEach(engine.groups, id: \.self) { group in
                        Button(group) { engine.move(t, toGroup: group) }
                            .disabled(t.group == group)
                    }
                    Divider()
                    Button("New Group…") {
                        newGroupName = ""
                        newGroupTarget = t
                    }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(t.path.path, inFileViewerRootedAtPath: "")
                }
                Divider()
                if engine.markedTranscriptIDs.count > 1 {
                    Button("Delete \(engine.markedTranscriptIDs.count) Marked", role: .destructive) {
                        confirmDeleteMarked = true
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        engine.deleteTranscript(t)
                    }
                }
            }
    }

    private var shortcutButtons: some View {
        Group {
            Button("Mark All") {
                engine.markAll(ids: orderedVisibleIDs)
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("Clear Marks") {
                engine.clearMarkedTranscripts()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button("Toggle Mark") {
                toggleFocusedMark()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Extend Mark Up") {
                extendMark(direction: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: .shift)

            Button("Extend Mark Down") {
                extendMark(direction: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: .shift)

            Button("Delete Marked") {
                guard !engine.markedTranscriptIDs.isEmpty else { return }
                confirmDeleteMarked = true
            }
            .keyboardShortcut(.delete, modifiers: [])
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    private func toggleFocusedMark() {
        let ids = orderedVisibleIDs
        guard !ids.isEmpty else { return }

        if let anchor = engine.selectionAnchorID, ids.contains(anchor) {
            engine.toggleMark(anchor)
            return
        }

        if let marked = engine.markedTranscriptIDs.first, ids.contains(marked) {
            engine.toggleMark(marked)
            return
        }

        engine.toggleMark(ids[0])
    }

    private func extendMark(direction: Int) {
        let ids = orderedVisibleIDs
        guard !ids.isEmpty else { return }

        let currentIndex: Int
        if let anchor = engine.selectionAnchorID, let index = ids.firstIndex(of: anchor) {
            currentIndex = index
        } else if let marked = engine.markedTranscriptIDs.first, let index = ids.firstIndex(of: marked) {
            currentIndex = index
        } else {
            engine.markRange(to: ids[0], in: ids)
            return
        }

        let nextIndex = max(0, min(ids.count - 1, currentIndex + direction))
        engine.markRange(to: ids[nextIndex], in: ids)
    }
}

/// The sidebar row for the recording currently in progress. A highlight band
/// sweeps across the name (a "gradient wipe") to signal that it's still being
/// worked on, until the finished transcript replaces it.
private struct InProgressRow: View {
    let title: String

    var body: some View {
        Text(title)
            .lineLimit(1)
            .padding(.vertical, 2)
            .wipeShimmer(active: true)
            .allowsHitTesting(false)
            .help("Recording in progress…")
    }
}
