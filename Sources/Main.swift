import Foundation

/// Process entry point. Chooses between the headless CLI (agent-first) and the
/// normal SwiftUI app based on the command-line arguments.
@main
enum HoverMain {
    static func main() {
        let options = CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
        if options.isCLI {
            HoverCLI.run(options) // headless; never returns
        } else {
            TranscriberApp.main() // normal GUI app
        }
    }
}
