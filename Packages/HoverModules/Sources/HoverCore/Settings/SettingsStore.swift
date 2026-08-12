public protocol SettingsStore: AnyObject {
    var inputSource: InputSource { get set }
    var outputDirectoryPath: String? { get set }
}
