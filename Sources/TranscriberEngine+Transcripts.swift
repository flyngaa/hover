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
        guard let dest = transcriptStore.rename(transcript, to: newName) else { return }
        if currentLogPath == transcript.path { currentLogPath = dest }

        let wasMarked = markedTranscriptIDs.contains(transcript.id)
        let wasLast = lastRecordingTranscript == transcript
        loadSavedTranscripts()
        let renamed = savedTranscripts.first { $0.path == dest }
        if wasMarked, let renamed { replaceMarkedID(transcript.id, with: renamed.id) }
        if wasLast { lastRecordingTranscript = renamed }
    }

    func move(_ transcript: SavedTranscript, toGroup group: String?) {
        guard let dest = transcriptStore.move(transcript, toGroup: group, in: outputDirectory) else { return }
        if currentLogPath == transcript.path { currentLogPath = dest }

        let wasMarked = markedTranscriptIDs.contains(transcript.id)
        let wasLast = lastRecordingTranscript == transcript
        loadSavedTranscripts()
        let moved = savedTranscripts.first { $0.path == dest }
        if wasMarked, let moved { replaceMarkedID(transcript.id, with: moved.id) }
        if wasLast { lastRecordingTranscript = moved }
    }

    func matches(_ transcript: SavedTranscript, query: String) -> Bool {
        transcriptStore.matches(transcript, query: query)
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
