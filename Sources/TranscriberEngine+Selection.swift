import Foundation

/// Thin wrappers over ``Selection`` (the pure value type that owns the marking
/// rules), plus the transcript-level actions those marks drive.
extension TranscriberEngine {

    var markedTranscripts: [SavedTranscript] {
        savedTranscripts.filter { selection.isMarked($0.id) }
    }

    var primaryMarkedTranscript: SavedTranscript? {
        guard let id = selection.primaryID else { return nil }
        return savedTranscripts.first { $0.id == id }
    }

    func clearMarkedTranscripts() {
        selection.clear()
    }

    func markAll(ids: [String]) {
        selection.markAll(ids)
    }

    func toggleMark(_ id: String) {
        selection.toggle(id)
    }

    func markRange(to id: String, in orderedIDs: [String]) {
        selection.markRange(to: id, in: orderedIDs)
    }

    func replaceMarkedID(_ oldID: String, with newID: String) {
        selection.replace(oldID, with: newID)
    }

    func unmarkDeleted(_ id: String) {
        selection.unmarkDeleted(id)
    }

    func combinedMarkedContent(separator: String = "\n\n") -> String {
        markedTranscripts
            .map { loadTranscriptContent($0) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    func deleteMarkedTranscripts() {
        let targets = markedTranscripts
        for transcript in targets {
            deleteTranscript(transcript)
        }
        clearMarkedTranscripts()
    }
}
