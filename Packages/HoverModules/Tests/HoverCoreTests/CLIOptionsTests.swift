import Testing

@testable import HoverCore

/// Argument parsing is pure, so the agent-facing flags can be checked directly.
@Suite struct CLIOptionsTests {

    @Test func noArgsMeansGUI() {
        let options = CLIOptions.parse([])
        #expect(options.isCLI == false)
        #expect(options.duration == nil)
        #expect(options.output == nil)
    }

    @Test func unknownArgsDoNotTriggerCLI() {
        #expect(CLIOptions.parse(["--weird", "foo"]).isCLI == false)
    }

    @Test func recordSubcommandEnablesCLI() {
        #expect(CLIOptions.parse(["record"]).isCLI)
        #expect(CLIOptions.parse(["--record"]).isCLI)
        #expect(CLIOptions.parse(["-r"]).isCLI)
    }

    @Test func setupCommandsSelectModelSetupWithoutRecordOptions() {
        #expect(CLIOptions.parse(["setup"]).command == .setup(statusOnly: false))
        #expect(CLIOptions.parse(["setup", "--status"]).command == .setup(statusOnly: true))
    }

    @Test func setupRejectsEveryOtherFlagOrSubcommand() {
        #expect(CLIOptions.parse(["setup", "--force"]).command == .invalid)
        #expect(CLIOptions.parse(["setup", "status"]).command == .invalid)
        #expect(CLIOptions.parse(["setup", "--status", "--json"]).command == .invalid)
    }

    @Test func duration() {
        #expect(CLIOptions.parse(["record", "--duration", "30"]).duration == 30)
        #expect(CLIOptions.parse(["-d", "15"]).duration == 15)
        #expect(CLIOptions.parse(["-d", "15"]).isCLI)
        // Missing/garbage value leaves duration nil rather than crashing.
        #expect(CLIOptions.parse(["record", "--duration"]).duration == nil)
        #expect(CLIOptions.parse(["record", "--duration", "abc"]).duration == nil)
    }

    /// `--output` takes either a folder path or an Obsidian vault name; which one
    /// it is gets worked out at run time, not while parsing.
    @Test func output() {
        #expect(CLIOptions.parse(["record", "--output", "~/Desktop"]).output == "~/Desktop")
        #expect(CLIOptions.parse(["-o", "My Notes"]).output == "My Notes")
        #expect(CLIOptions.parse(["-o", "My Notes"]).isCLI)
        // Missing value leaves it nil rather than swallowing the next flag.
        #expect(CLIOptions.parse(["record", "--output"]).output == nil)
    }

    @Test func source() {
        #expect(CLIOptions.parse(["record", "--source", "microphone"]).inputSource == .microphone)
        #expect(CLIOptions.parse(["record", "--input", "system"]).inputSource == .system)
        // Unknown source is ignored.
        #expect(CLIOptions.parse(["record", "--source", "bogus"]).inputSource == nil)
    }

    @Test func json() {
        #expect(CLIOptions.parse(["record", "--json"]).json)
    }

    @Test func help() {
        let options = CLIOptions.parse(["--help"])
        #expect(options.help)
        #expect(options.isCLI)
    }

    @Test func combinedFlags() {
        let options = CLIOptions.parse(["record", "--duration", "45", "--output", "Work", "--json"])
        #expect(options.isCLI)
        #expect(options.duration == 45)
        #expect(options.output == "Work")
        #expect(options.json)
    }
}
