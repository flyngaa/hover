import HoverCore
import HoverPlatform

final class InMemorySettings: SettingsStore {
    var inputSource: InputSource
    var diarizeSpeakers: Bool
    var outputDirectoryPath: String?

    init(
        inputSource: InputSource = .both,
        diarizeSpeakers: Bool = false,
        outputDirectoryPath: String? = nil
    ) {
        self.inputSource = inputSource
        self.diarizeSpeakers = diarizeSpeakers
        self.outputDirectoryPath = outputDirectoryPath
    }
}
