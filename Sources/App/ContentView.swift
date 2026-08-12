import HoverCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(RecordingModel.self) private var recording
    @Environment(TranscriptLibraryModel.self) private var library
    @Environment(ModelSetupController.self) private var modelSetup
    @State private var offerInstallCLIAfterSetup = false

    var body: some View {
        Group {
            if modelSetup.status == .notNeeded {
                appContent
            } else {
                ModelSetupView()
            }
        }
        .tint(BrandColors.orange)
        .background(WindowTitleHidingView())
        .onChange(of: modelSetup.status) { previous, current in
            if previous != .notNeeded, current == .notNeeded {
                offerInstallCLIAfterSetup = true
            }
        }
        .sheet(isPresented: $offerInstallCLIAfterSetup) {
            InstallCLIView(isOnboarding: true)
        }
        .fileImporter(
            isPresented: .init(
                get: { library.outputDirectoryAuthorizationRequest != nil },
                set: { if !$0 { library.cancelOutputDirectoryAuthorization() } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let directories) = result,
                let directory = directories.first
            else { return }
            library.authorizeOutputDirectory(directory)
        }
        .fileDialogDefaultDirectory(library.outputDirectoryAuthorizationRequest)
        .fileDialogConfirmationLabel("Allow Access")
        .fileDialogMessage(
            "Choose the folder where Hover reads and saves transcript files."
        )
        .alert(
            "Transcript operation failed",
            isPresented: .init(
                get: { library.presentedFailureMessage != nil },
                set: { if !$0 { library.presentedFailureMessage = nil } }
            )
        ) {
            Button("OK") { library.presentedFailureMessage = nil }
        } message: {
            Text(library.presentedFailureMessage ?? "")
        }
    }

    private var appContent: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    OutputDestinationButton()
                    InputSourceMenu()
                    RecordButton()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                detailPane
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        // Presented here rather than on the Record button so a hotkey-started
        // recording reaches it too, whichever pane happens to be on screen.
        .sheet(
            isPresented: .init(
                get: { recording.permissionRequest != nil },
                set: { if !$0 { recording.dismissPermissionRequest() } }
            )
        ) {
            PermissionRequestSheet()
        }
    }

    /// The live transcript owns the pane while a recording is being worked on.
    /// Once it's finished, the sidebar takes over: the saved transcript is marked
    /// by then, and marking another one has to be able to replace it on screen.
    /// Text with nothing marked still shows — that's a recording that couldn't be
    /// saved, and it's the only copy left.
    private var showsLiveTranscript: Bool {
        recording.isRecordingBusy
            || (!recording.committedText.isEmpty && library.markedTranscriptIDs.isEmpty)
    }

    @ViewBuilder
    private var detailPane: some View {
        Group {
            if showsLiveTranscript {
                LiveTranscriptView()
            } else if library.markedTranscriptIDs.count > 1 {
                MarkedTranscriptsView()
            } else if let t = library.primaryMarkedTranscript {
                SavedTranscriptView(transcript: t)
            } else {
                EmptyDetailView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
