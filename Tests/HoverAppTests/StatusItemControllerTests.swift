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

    @Test func guiMenuEnablesStartWhenIdle() {
        let items = StatusItemController.menuModel(
            activity: .idle,
            supports: [.startRecording, .stopRecording, .showWindow]
        )
        #expect(
            items.map(\.title) == [
                "Hover — Ready", "Start Recording", "Stop Recording", "Show Hover",
            ]
        )
        #expect(enabled(items, .startRecording) == true)
        #expect(enabled(items, .stopRecording) == false)
        #expect(enabled(items, .showWindow) == true)
    }

    @Test func guiMenuEnablesStopWhileRecording() {
        let items = StatusItemController.menuModel(
            activity: .recording,
            supports: [.startRecording, .stopRecording, .showWindow]
        )
        #expect(items.first?.title == "Recording…")
        #expect(enabled(items, .startRecording) == false)
        #expect(enabled(items, .stopRecording) == true)
    }

    @Test func transcribingDisablesBothStartAndStop() {
        let items = StatusItemController.menuModel(
            activity: .processing,
            supports: [.startRecording, .stopRecording, .showWindow]
        )
        #expect(items.first?.title == "Transcribing…")
        #expect(enabled(items, .startRecording) == false)
        #expect(enabled(items, .stopRecording) == false)
    }

    @Test func headlessMenuOffersOnlyStop() {
        let items = StatusItemController.menuModel(activity: .recording, supports: [.stopRecording])
        #expect(items.map(\.title) == ["Recording…", "Stop Recording"])
        #expect(enabled(items, .stopRecording) == true)
    }

    private func enabled(
        _ items: [StatusItemController.MenuItemModel],
        _ command: StatusItemController.Command
    ) -> Bool? {
        items.first { $0.command == command }?.isEnabled
    }
}
