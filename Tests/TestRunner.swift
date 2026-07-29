import Testing

/// Entry point for the test executable.
///
/// swift-testing's `__swiftPMEntryPoint` discovers every `@Test` function in this
/// module, runs them, prints the usual pass/fail summary, and exits with a
/// non-zero code if anything fails. This lets `swift run TranscriberTests` work
/// on a machine that only has the Command Line Tools (no Xcode test runner).
@main
enum TestRunner {
    static func main() async {
        await __swiftPMEntryPoint(passing: nil) as Never
    }
}
