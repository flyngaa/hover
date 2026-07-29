import Testing
@testable import TranscriberKit

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

    @Test func tagSpeakers() {
        #expect(CLIOptions.parse(["record", "--tag-speakers"]).tagSpeakers == true)
        #expect(CLIOptions.parse(["record", "--no-tag-speakers"]).tagSpeakers == false)
        #expect(CLIOptions.parse(["record"]).tagSpeakers == nil)
    }

    @Test func json() {
        #expect(CLIOptions.parse(["record", "--json"]).json)
    }

    @Test func help() {
        let options = CLIOptions.parse(["--help"])
        #expect(options.help)
        #expect(options.isCLI)
    }

    @Test func autotestBackCompat() {
        #expect(CLIOptions.parse(["--autotest"]).duration == 25)
        #expect(CLIOptions.parse(["--autotest", "10"]).duration == 10)
        #expect(CLIOptions.parse(["--autotest"]).isCLI)
    }

    @Test func combinedFlags() {
        let options = CLIOptions.parse(["record", "--duration", "45", "--output", "Work", "--json"])
        #expect(options.isCLI)
        #expect(options.duration == 45)
        #expect(options.output == "Work")
        #expect(options.json)
    }
}
