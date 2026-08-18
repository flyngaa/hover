import Foundation

public enum CLICommand: Equatable, Sendable {
    case gui
    case record
    case setup(statusOnly: Bool)
    case doctor(json: Bool)
    case invalid
}

/// Parsed command-line options that let Hover run headlessly for agents/scripts
/// (e.g. from Claude Code) instead of opening the GUI.
///
/// Pure value logic — parsing is separated from doing so it can be unit-tested
/// without launching an app. See ``HoverCLI`` for the runner that acts on these.
public struct CLIOptions: Equatable, Sendable {

    public var command: CLICommand = .gui

    /// True when any CLI flag was passed; the app runs headless instead of GUI.
    public var isCLI: Bool { command != .gui || help }

    /// Record length in seconds. `nil` means record until interrupted (Ctrl-C).
    public var duration: Double?

    /// Where to save the transcript for this run: an absolute folder *path* or an
    /// Obsidian vault *name*. When `nil`, the folder set in the app is used.
    public var output: String?

    /// Override which audio source to record (system / microphone / both).
    public var inputSource: InputSource?

    /// Emit machine-readable JSON instead of plain text.
    public var json = false

    /// True when the user asked for help.
    public var help = false

    public static func parse(_ args: [String]) -> CLIOptions {
        var options = CLIOptions()

        if args.first == "setup" {
            switch Array(args.dropFirst()) {
            case []:
                options.command = .setup(statusOnly: false)
            case ["--status"]:
                options.command = .setup(statusOnly: true)
            default:
                options.command = .invalid
            }
            return options
        }

        if args.first == "doctor" {
            switch Array(args.dropFirst()) {
            case []:
                options.command = .doctor(json: false)
            case ["--json"]:
                options.command = .doctor(json: true)
            default:
                options.command = .invalid
            }
            return options
        }

        let recordArguments: Set<String> = [
            "record", "--record", "-r", "--duration", "--seconds", "-d",
            "--output", "-o", "--source", "--input", "--json",
        ]
        if args.contains(where: recordArguments.contains) {
            options.command = .record
        }

        var index = 0

        func value() -> String? {
            guard index + 1 < args.count else { return nil }
            return args[index + 1]
        }

        while index < args.count {
            switch args[index] {
            case "record", "--record", "-r":
                break

            case "--duration", "--seconds", "-d":
                if let raw = value(), let seconds = Double(raw) {
                    options.duration = seconds
                    index += 1
                }

            case "--output", "-o":
                if let raw = value() {
                    options.output = raw
                    index += 1
                }

            case "--source", "--input":
                if let raw = value(), let source = InputSource(rawValue: raw) {
                    options.inputSource = source
                    index += 1
                }

            case "--json":
                options.json = true

            case "--help", "-h":
                options.help = true

            default:
                break
            }
            index += 1
        }

        return options
    }

    /// One-screen usage text for `--help`.
    public static let helpText = """
        Hover — record audio and transcribe it, agent-first.

        USAGE:
          hover record [options]
          hover setup [--status]
          hover doctor [--json]

        OPTIONS:
          -d, --duration <sec>   Record for this many seconds, then stop.
                                 Omit to record until you press Ctrl-C.
          -o, --output <path|vault>  Save the transcript here instead of the folder set
                                 in the app: a folder path, or the name of an Obsidian
                                 vault (saves into its Transcripts subfolder).
              --source <both|system|microphone>   Which audio to record.
              --json             Print the result as JSON.
              --status           Report whether Model Setup is complete without downloading.
          -h, --help             Show this help.

        EXAMPLES:
          hover record --duration 30
          hover record --output ~/Desktop
          hover record --output "My Notes"   # an Obsidian vault
          hover record            # records until Ctrl-C, then transcribes
          hover setup             # downloads missing model data
          hover setup --status    # checks Model Setup without downloading
          hover doctor            # report whether Hover is ready to record
          hover doctor --json     # the same report as JSON, for scripts and agents
        """
}
