import Foundation

/// Parsed command-line options that let Hover run headlessly for agents/scripts
/// (e.g. from Claude Code) instead of opening the GUI.
///
/// Pure value logic — parsing is separated from doing so it can be unit-tested
/// without launching an app. See ``HoverCLI`` for the runner that acts on these.
struct CLIOptions: Equatable {

    /// True when any CLI flag was passed; the app runs headless instead of GUI.
    var isCLI = false

    /// Record length in seconds. `nil` means record until interrupted (Ctrl-C).
    var duration: Double?

    /// Where to save the transcript for this run: an absolute folder *path* or an
    /// Obsidian vault *name*. When `nil`, the folder set in the app is used.
    var output: String?

    /// Override which audio source to record (system / microphone / both).
    var inputSource: InputSource?

    /// Override speaker tagging for this run.
    var tagSpeakers: Bool?

    /// Emit machine-readable JSON instead of plain text.
    var json = false

    /// True when the user asked for help.
    var help = false

    static func parse(_ args: [String]) -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        func value() -> String? {
            guard index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        while index < args.count {
            switch args[index] {
            case "record", "--record", "-r":
                options.isCLI = true

            case "--autotest":
                // Back-compat with the old scripted end-to-end check: record for
                // N seconds (default 25), then quit.
                options.isCLI = true
                if let raw = value(), let seconds = Double(raw) {
                    options.duration = seconds
                    index += 1
                } else {
                    options.duration = 25
                }

            case "--duration", "--seconds", "-d":
                options.isCLI = true
                if let raw = value(), let seconds = Double(raw) {
                    options.duration = seconds
                    index += 1
                }

            case "--output", "-o":
                options.isCLI = true
                if let raw = value() {
                    options.output = raw
                    index += 1
                }

            case "--source", "--input":
                options.isCLI = true
                if let raw = value(), let source = InputSource(rawValue: raw) {
                    options.inputSource = source
                    index += 1
                }

            case "--tag-speakers":
                options.isCLI = true
                options.tagSpeakers = true

            case "--no-tag-speakers":
                options.isCLI = true
                options.tagSpeakers = false

            case "--json":
                options.isCLI = true
                options.json = true

            case "--help", "-h":
                options.isCLI = true
                options.help = true

            default:
                break
            }
            index += 1
        }

        return options
    }

    /// One-screen usage text for `--help`.
    static let helpText = """
    Hover — record audio and transcribe it, agent-first.

    USAGE:
      hover record [options]

    OPTIONS:
      -d, --duration <sec>   Record for this many seconds, then stop.
                             Omit to record until you press Ctrl-C.
      -o, --output <path|vault>  Save the transcript here instead of the folder set
                             in the app: a folder path, or the name of an Obsidian
                             vault (saves into its Transcripts subfolder).
          --source <both|system|microphone>   Which audio to record.
          --tag-speakers / --no-tag-speakers  Force speaker labelling on/off.
          --json             Print the result as JSON.
      -h, --help             Show this help.

    EXAMPLES:
      hover record --duration 30
      hover record --output ~/Desktop
      hover record --output "My Notes"   # an Obsidian vault
      hover record            # records until Ctrl-C, then transcribes
    """
}
