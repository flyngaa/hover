// swift-tools-version:5.9
import PackageDescription
import Foundation

// This package exists only to run the unit test suite (`swift test`).
// The shipping app is still built by `build.sh` with swiftc directly — this
// manifest just re-uses the same Sources as a library so tests can import them.
//
// swift-tools-version:5.9 keeps everything in the Swift 5 language mode, matching
// how build.sh compiles today (avoids Swift 6 strict-concurrency errors).

/// This machine has the Command Line Tools (no full Xcode), where SwiftPM doesn't
/// automatically add swift-testing's framework search path. Locate it so the test
/// target can `import Testing`.
func testingFrameworksPath() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try? proc.run()
    proc.waitUntilExit()
    let dev = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let candidates = [
        dev + "/Library/Developer/Frameworks",                            // Command Line Tools
        dev + "/Platforms/MacOSX.platform/Developer/Library/Frameworks",  // full Xcode
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0 + "/Testing.framework") }
}

let fw = testingFrameworksPath()

// swift-testing loads at runtime, so we need both a framework search path (-F)
// for Testing.framework and rpaths for it plus its sibling lib_TestingInterop.dylib
// (which lives in .../Library/Developer/usr/lib under the Command Line Tools).
func runtimeLibDirs(forFrameworkPath fwPath: String) -> [String] {
    // fwPath is .../Library/Developer/Frameworks — its sibling usr/lib holds the interop dylib.
    let interopLib = (fwPath as NSString).deletingLastPathComponent + "/usr/lib"
    return [fwPath, interopLib]
}

var testSwiftSettings: [SwiftSetting] = []
var testLinkerSettings: [LinkerSetting] = []
if let fw {
    testSwiftSettings = [.unsafeFlags(["-F", fw])]
    var linkerFlags = ["-F", fw]
    for dir in runtimeLibDirs(forFrameworkPath: fw) {
        linkerFlags += ["-Xlinker", "-rpath", "-Xlinker", dir]
    }
    testLinkerSettings = [.unsafeFlags(linkerFlags)]
}

let package = Package(
    name: "TranscriberKit",
    // macOS 14: the engine uses the @Observable macro, which is 14+.
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TranscriberKit",
            path: "Sources",
            // The @main entry point and the SwiftUI App are only meaningful in
            // the real app build, not the test library.
            exclude: ["Main.swift", "TranscriberApp.swift"]
        ),
        // Run with:  swift run TranscriberTests
        //
        // This is an *executable* rather than a `.testTarget` on purpose: this
        // machine has only the Command Line Tools (no Xcode), so `swift test`
        // can build a test bundle but has no runner to execute it. An executable
        // that calls swift-testing's own entry point runs the exact same @Test
        // functions and prints a normal pass/fail summary. (With full Xcode
        // installed, `swift test` also works.)
        .executableTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberKit"],
            path: "Tests",
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
