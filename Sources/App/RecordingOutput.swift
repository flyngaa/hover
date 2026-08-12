import Foundation
import HoverCore

enum RecordingOutput {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Transcripts")
    }
}
