import Foundation
import HoverCore
import Testing

@testable import HoverApp

/// The doctor mapping and the output-block decision are pure statics, so they
/// can be checked without a machine in any particular state.
@Suite @MainActor struct CLIDoctorTests {

    private func readyReport(
        microphone: PermissionState = .granted,
        systemAudio: PermissionState = .granted,
        modelPresent: Bool = true,
        outputWritable: Bool = true,
        hoverOnPath: String? = "/opt/homebrew/bin/hover"
    ) -> DoctorReport {
        HoverCLI.doctorReport(
            architecture: "arm64",
            architectureSupported: true,
            osVersion: "14.5.0",
            osSupported: true,
            hoverOnPath: hoverOnPath,
            modelPresent: modelPresent,
            microphone: microphone,
            systemAudio: systemAudio,
            outputDirectory: "/Users/me/Documents/Transcripts",
            outputWritable: outputWritable
        )
    }

    @Test func aFullyProvisionedMacIsReady() {
        let report = readyReport()
        #expect(report.isReady)
        #expect(report.exitCode == 0)
    }

    @Test func deniedMicrophoneFailsButDeniedSystemAudioOnlyWarns() {
        let micDenied = readyReport(microphone: .denied)
        #expect(micDenied.isReady == false)
        #expect(micDenied.checks.first { $0.id == "microphone" }?.status == .fail)

        let systemDenied = readyReport(systemAudio: .denied)
        #expect(systemDenied.isReady)
        #expect(systemDenied.checks.first { $0.id == "systemAudio" }?.status == .warn)
    }

    @Test func notRequestedMicrophoneOnlyWarns() {
        let report = readyReport(microphone: .notRequested)
        #expect(report.isReady)
        #expect(report.checks.first { $0.id == "microphone" }?.status == .warn)
    }

    @Test func missingModelFails() {
        let report = readyReport(modelPresent: false)
        #expect(report.isReady == false)
        let model = report.checks.first { $0.id == "model" }
        #expect(model?.status == .fail)
        #expect(model?.fix?.contains("hover setup") == true)
    }

    @Test func unwritableOutputFolderFails() {
        let report = readyReport(outputWritable: false)
        #expect(report.isReady == false)
        #expect(report.checks.first { $0.id == "output" }?.status == .fail)
    }

    @Test func missingCLIOnPathOnlyWarns() {
        let report = readyReport(hoverOnPath: nil)
        #expect(report.isReady)
        #expect(report.checks.first { $0.id == "cli" }?.status == .warn)
    }

    @Test func unsupportedArchitectureAndOSFail() {
        let report = HoverCLI.doctorReport(
            architecture: "x86_64",
            architectureSupported: false,
            osVersion: "13.0.0",
            osSupported: false,
            hoverOnPath: nil,
            modelPresent: true,
            microphone: .granted,
            systemAudio: .granted,
            outputDirectory: "/tmp",
            outputWritable: true
        )
        #expect(report.isReady == false)
        #expect(report.checks.first { $0.id == "architecture" }?.status == .fail)
        #expect(report.checks.first { $0.id == "macos" }?.status == .fail)
    }

    @Test func outputBlockReasonPrefersFailureMessageThenAuthorizationRequest() {
        #expect(
            HoverCLI.outputBlockReason(authorizationRequest: nil, failureMessage: nil) == nil)

        #expect(
            HoverCLI.outputBlockReason(
                authorizationRequest: URL(fileURLWithPath: "/protected"),
                failureMessage: "disk full"
            ) == "disk full")

        let reason = HoverCLI.outputBlockReason(
            authorizationRequest: URL(fileURLWithPath: "/protected"),
            failureMessage: nil
        )
        #expect(reason?.contains("/protected") == true)
    }

    @Test func detectsAnotherInstanceOnlyWhenBundleIDsMatchAndItIsNotSelf() {
        let bundleID = "com.hover.desktop"

        // Only this process is running under the bundle id -> no other instance.
        #expect(
            HoverCLI.hasOtherInstance(
                ofBundleID: bundleID,
                excludingProcessID: 100,
                among: [(processID: 100, bundleID: bundleID)]
            ) == false)

        // A different process with the same bundle id (e.g. the GUI app).
        #expect(
            HoverCLI.hasOtherInstance(
                ofBundleID: bundleID,
                excludingProcessID: 100,
                among: [
                    (processID: 100, bundleID: bundleID),
                    (processID: 200, bundleID: bundleID),
                ]
            ))

        // Other processes, but none is Hover.
        #expect(
            HoverCLI.hasOtherInstance(
                ofBundleID: bundleID,
                excludingProcessID: 100,
                among: [(processID: 200, bundleID: "com.apple.Finder")]
            ) == false)

        // Unknown own bundle id can't match anything.
        #expect(
            HoverCLI.hasOtherInstance(
                ofBundleID: nil,
                excludingProcessID: 100,
                among: [(processID: 200, bundleID: bundleID)]
            ) == false)
    }

    @Test func hoverExecutableOnPathFindsAnExecutableAndIgnoresMissingPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hover-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("hover")
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)

        #expect(
            HoverCLI.hoverExecutableOnPath(environment: ["PATH": directory.path])
                == executable.path)
        #expect(HoverCLI.hoverExecutableOnPath(environment: [:]) == nil)
    }
}
