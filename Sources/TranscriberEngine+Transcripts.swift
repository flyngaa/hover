import Foundation

/// Thin coordination layer over ``TranscriptStore``. The store does the file
/// work; the engine reconciles app state (marks, the live-recording pointers)
/// afterwards.
extension TranscriberEngine {

    func loadSavedTranscripts() {
        let library = transcriptStore.load(in: outputDirectory)
        savedTranscripts = library.transcripts
        groups = library.groups
    }

    func rename(_ transcript: SavedTranscript, to newName: String) {
        moveOnDisk(transcript) { transcriptStore.rename($0, to: newName) }
    }

    func move(_ transcript: SavedTranscript, toGroup group: String?) {
        moveOnDisk(transcript) { transcriptStore.move($0, toGroup: group, in: outputDirectory) }
    }

    /// Perform a file move and catch app state up with it.
    ///
    /// A transcript's ID is derived from its path, so any move invalidates every
    /// reference we hold: the tick in the sidebar, the file the in-progress
    /// recording is appending to, and the pointer to the just-finished recording.
    /// Renaming and regrouping differ only in the file operation itself, so they
    /// share this reconciliation rather than each keeping their own copy.
    private func moveOnDisk(
        _ transcript: SavedTranscript,
        using fileMove: (SavedTranscript) -> URL?
    ) {
        guard let dest = fileMove(transcript) else { return }
        if currentLogPath == transcript.path { currentLogPath = dest }

        let wasMarked = markedTranscriptIDs.contains(transcript.id)
        let wasLast = lastRecordingTranscript == transcript
        loadSavedTranscripts()
        let updated = savedTranscripts.first { $0.path == dest }
        if wasMarked, let updated { replaceMarkedID(transcript.id, with: updated.id) }
        if wasLast { lastRecordingTranscript = updated }
    }

    /// Search all transcripts off the main thread, returning the matching IDs.
    /// Content matching reads every transcript file, so it must never run inside
    /// a view's `body`.
    func searchHits(for query: String) async -> Set<String> {
        let transcripts = savedTranscripts
        let store = transcriptStore
        return await Task.detached(priority: .userInitiated) {
            Set(transcripts.filter { store.matches($0, query: query) }.map(\.id))
        }.value
    }

    func loadTranscriptContent(_ transcript: SavedTranscript) -> String {
        transcriptStore.content(of: transcript)
    }

    func deleteTranscript(_ transcript: SavedTranscript) {
        unmarkDeleted(transcript.id)
        if lastRecordingTranscript == transcript {
            lastRecordingTranscript = nil
            committedChunks = []
        }
        transcriptStore.delete(transcript)
        savedTranscripts.removeAll { $0.id == transcript.id }
    }
}
