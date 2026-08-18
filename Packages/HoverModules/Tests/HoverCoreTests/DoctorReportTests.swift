import Foundation
import Testing

@testable import HoverCore

/// The readiness report is pure, so its exit code and rendering can be checked
/// directly without putting a machine into any particular state.
@Suite struct DoctorReportTests {

    private func check(
        _ id: String,
        _ status: DoctorReport.Status,
        fix: String? = nil
    ) -> DoctorReport.Check {
        DoctorReport.Check(id: id, name: id.capitalized, status: status, detail: "detail", fix: fix)
    }

    @Test func allOkIsReadyAndExitsZero() {
        let report = DoctorReport(checks: [check("mic", .ok), check("model", .ok)])
        #expect(report.isReady)
        #expect(report.exitCode == 0)
    }

    @Test func warningsDoNotFailTheReport() {
        let report = DoctorReport(checks: [check("cli", .warn), check("model", .ok)])
        #expect(report.isReady)
        #expect(report.exitCode == 0)
    }

    @Test func anyFailureMakesTheReportUnready() {
        let report = DoctorReport(checks: [
            check("mic", .fail, fix: "Enable it"),
            check("model", .ok),
        ])
        #expect(report.isReady == false)
        #expect(report.exitCode == 1)
    }

    @Test func textReportShowsFixesOnlyForNonOkChecks() {
        let report = DoctorReport(checks: [
            check("mic", .fail, fix: "Enable Hover in System Settings"),
            check("model", .ok, fix: "should not appear"),
        ])
        let text = report.textReport
        #expect(text.contains("[fail] Mic: detail"))
        #expect(text.contains("Fix: Enable Hover in System Settings"))
        #expect(text.contains("should not appear") == false)
        #expect(text.contains("not ready to record"))
    }

    @Test func jsonReportCarriesReadyFlagAndStableCheckKeys() throws {
        let report = DoctorReport(checks: [check("microphone", .fail, fix: "Enable it")])
        let json = try report.jsonReport()
        let object =
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["ready"] as? Bool == false)
        let checks = object?["checks"] as? [[String: Any]]
        #expect(checks?.first?["id"] as? String == "microphone")
        #expect(checks?.first?["status"] as? String == "fail")
        #expect(checks?.first?["fix"] as? String == "Enable it")
    }
}
