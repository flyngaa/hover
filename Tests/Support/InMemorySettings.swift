import Foundation
import HoverCore

final class InMemorySettings: SettingsStore {
    var inputSource: InputSource
    var outputDirectoryPath: String?

    init(
        inputSource: InputSource = .both,
        outputDirectoryPath: String? = nil
    ) {
        self.inputSource = inputSource
        self.outputDirectoryPath = outputDirectoryPath
    }
}
