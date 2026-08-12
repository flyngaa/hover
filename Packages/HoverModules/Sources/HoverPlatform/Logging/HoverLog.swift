import OSLog

/// Privacy-safe unified logging categories for Hover's operational boundaries.
/// Dynamic messages are private because they can contain paths, device details,
/// process diagnostics, transcript names, or other user-controlled metadata.
public enum HoverLog {
    private static let subsystem = "com.hover.desktop"
    private static let performanceLog = OSLog(
        subsystem: subsystem,
        category: .pointsOfInterest
    )

    private static let recordingLogger = Logger(subsystem: subsystem, category: "recording")
    private static let audioCaptureLogger = Logger(subsystem: subsystem, category: "audio-capture")
    private static let transcriptionLogger = Logger(subsystem: subsystem, category: "transcription")
    private static let modelSetupLogger = Logger(subsystem: subsystem, category: "model-setup")
    private static let storageLogger = Logger(subsystem: subsystem, category: "storage")
    private static let permissionsLogger = Logger(subsystem: subsystem, category: "permissions")
    private static let cliInstallationLogger = Logger(
        subsystem: subsystem,
        category: "cli-installation"
    )

    public static func recording(_ message: String) {
        recordingLogger.info("\(message, privacy: .private)")
    }

    public static func audioCapture(_ message: String) {
        audioCaptureLogger.info("\(message, privacy: .private)")
    }

    public static func transcription(_ message: String) {
        transcriptionLogger.info("\(message, privacy: .private)")
    }

    public static func modelSetup(_ message: String) {
        modelSetupLogger.info("\(message, privacy: .private)")
    }

    public static func storage(_ message: String) {
        storageLogger.info("\(message, privacy: .private)")
    }

    public static func permissions(_ message: String) {
        permissionsLogger.info("\(message, privacy: .private)")
    }

    public static func cliInstallation(_ message: String) {
        cliInstallationLogger.info("\(message, privacy: .private)")
    }

    public static func beginWhisperChunk() {
        os_signpost(.begin, log: performanceLog, name: "Whisper Chunk")
    }

    public static func endWhisperChunk() {
        os_signpost(.end, log: performanceLog, name: "Whisper Chunk")
    }

    public static func beginModelSetup() {
        os_signpost(.begin, log: performanceLog, name: "Model Setup")
    }

    public static func endModelSetup() {
        os_signpost(.end, log: performanceLog, name: "Model Setup")
    }
}
