import HoverCore
import HoverPlatform
import Testing

@testable import HoverApp

@MainActor
@Suite struct StatusItemControllerTests {
    @Test func rendersTypedActivitySnapshots() {
        let controller = StatusItemController()

        controller.render(
            StatusItemSnapshot(
                activity: .recording,
                tooltip: "Hover — recording"
            ))
        #expect(controller.snapshot.activity == .recording)
        #expect(controller.snapshot.tooltip == "Hover — recording")

        controller.render(
            StatusItemSnapshot(
                activity: .processing,
                tooltip: "Hover — processing"
            ))
        #expect(controller.snapshot.activity == .processing)

        controller.render(StatusItemSnapshot(activity: .idle, tooltip: "Hover"))
        #expect(controller.snapshot.activity == .idle)
    }

    @Test func repeatedIdenticalRenderIsIdempotent() {
        let controller = StatusItemController()
        let snapshot = StatusItemSnapshot(activity: .recording, tooltip: "Recording")

        controller.render(snapshot)
        controller.render(snapshot)

        #expect(controller.snapshot == snapshot)
    }
}
