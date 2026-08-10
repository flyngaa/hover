# Refactor Plan 4: Decompose `TranscriberEngine`

## Objective

Replace `TranscriberEngine` with focused feature owners and a thin composition model, without creating a renamed god object or service locator.

Pure extractions may start earlier, but complete decomposition depends on main-actor isolation, async platform seams, and the `RecordingSession` lifecycle from Plans 2 and 3.

## Current responsibility map

| Responsibility | Current location | Intended owner |
| --- | --- | --- |
| Recording lifecycle, permissions, capture, transcription, finalization | `TranscriberEngine.swift` | `RecordingModel` and `RecordingSession` |
| Transcript list, groups, search, selection | engine properties and `TranscriberEngine+Transcripts.swift` / `+Selection.swift` | `TranscriptLibraryModel` |
| Output destinations and relocation | `TranscriberEngine+Output.swift` | `TranscriptLibraryModel` plus app-owned native actions |
| Model setup progress and retry | `TranscriberEngine.swift` | `ModelSetupController` |
| Diarization orchestration, process, parsing, attribution | `TranscriberEngine+Diarization.swift` | four focused types |
| AppKit menu-bar ownership | `MenuBarMoth.swift` and app shell | `StatusItemController` |
| Cross-feature coordination | engine/app shell | small `AppModel` |

The engine also constructs eight concrete dependencies through default arguments. GUI and Agent Mode obtain an entire application by calling `TranscriberEngine()`.

## Target object graph

```text
HoverApp composition root
├── AppModel
│   ├── RecordingModel
│   │   └── RecordingSession
│   ├── TranscriptLibraryModel
│   └── ModelSetupController
├── StatusItemController
├── RecordingHotKeyController
└── concrete adapters
    ├── LiveAudioCapture factory
    ├── WhisperCLITranscriber
    ├── LocalSpeakerDiarizer
    ├── FileTranscriptStore
    ├── UserDefaultsSettings
    ├── SystemRecordingPermissions
    ├── ObsidianVaultFinder
    └── NetworkedModelSetup
```

Agent Mode should use a separate composition root and focused workflows directly. It should not instantiate the GUI `AppModel`.

## `AppModel`

`AppModel` is `@MainActor @Observable` and owns only cross-feature coordination:

```swift
@MainActor
@Observable
final class AppModel {
    let recording: RecordingModel
    let transcriptLibrary: TranscriptLibraryModel
    let modelSetup: ModelSetupController

    var readiness: AppReadiness { /* derived */ }
    var statusItemSnapshot: StatusItemSnapshot { /* derived */ }
    var presentedAlert: PresentedAlert?

    func startRecording() async
    func stopRecording() async
    func respondToPermission(_ response: RecordingPermissionResponse) async
}
```

Allowed responsibilities:

- gate recording on global readiness;
- clear transcript selection when a new recording command is accepted;
- reconcile the exact final recording result with the transcript library;
- prevent output changes during disallowed phases;
- derive a status-item snapshot; and
- trigger cross-feature onboarding presentation after model setup.

It must not:

- manipulate files, processes, AppKit, or network state;
- receive or expose a universal dependency container;
- forward every child property; or
- become the object every feature depends on.

Views should receive the focused observable model they need.

## `TranscriptLibraryModel`

Make it `@MainActor @Observable` and inject only Transcript Store, Settings Store, and Vault Finder.

It owns:

- transcripts and groups;
- `Selection`, marked IDs, and anchor;
- search query/results and latest-query cancellation;
- output directory and available destinations;
- pending output destination changes;
- reload, content, rename, move, delete, marked-content combination, and relocation.

It does not own recording state or the current session path. `AppModel` gates conflicting commands, while `RecordingSession` owns its output identity.

Native UI behavior remains in the app layer:

- revealing in Finder;
- `NSOpenPanel`;
- clipboard access; and
- application activation.

The library must publish state changes only after throwing store operations succeed.

## `ModelSetupController`

```swift
@MainActor
@Observable
final class ModelSetupController {
    private(set) var status: ModelSetupStatus
    private var fetchTask: Task<Void, Never>?

    init(modelSetup: ModelSetup)
    func startIfNeeded()
    func retry()
    func cancel()
}
```

Preserve:

- `.notNeeded` when all data is complete;
- initial running state for missing/partial data;
- no overlapping appearance/retry fetches;
- progress credit for already-present files;
- localized failure presentation; and
- retry and cancellation behavior.

Agent Mode continues to use the `ModelSetup` dependency directly because it does not need an observable controller.

## Diarization split

Split `TranscriberEngine+Diarization.swift` into four roles.

### `SpeakerAttribution`

Pure logic merging timestamped text segments with speaker turns. Move existing merge/attribute behavior without changing it.

### `DiarizationOutputParser`

Pure parsing of native output and Python JSON into `[SpeakerTurn]`. A concrete parser is sufficient unless a real alternate implementation appears.

### `DiarizationProcessRunner`

Platform effect returning typed process output. It must be async, cancellation-aware, and safe for large stdout/stderr.

### `SpeakerDiarizer`

Core dependency contract:

```swift
protocol SpeakerDiarizer: Sendable {
    var unavailableReason: String? { get }
    func diarize(samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn]
}
```

`LocalSpeakerDiarizer` owns temporary WAV handling, helper selection, command construction, injected process runner/parser, and install-layout paths. Keep command construction deterministic and separately testable.

`RecordingSession` orchestrates:

```text
captured samples
  -> SpeakerDiarizer
  -> SpeakerAttribution
  -> labelled transcript
  -> TranscriptStore
```

## `StatusItemController`

Replace direct observation of `TranscriberEngine` with a typed projection:

```swift
struct StatusItemSnapshot: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case idle
        case recording
        case processing
    }

    let activity: Activity
    let tooltip: String
}
```

`@MainActor StatusItemController` owns:

- `NSStatusItem`;
- target/action;
- moth artwork and tooltip;
- rendering idempotency; and
- typed click commands.

It must not accept or observe an engine/application model. The app shell observes the snapshot and calls `render(_:)`, preserving updates even when SwiftUI windows are hidden.

Agent Mode may use the same controller without a show-window command.

## Dependency composition

Add a root-only factory:

```swift
struct AppDependencies {
    let settings: SettingsStore
    let transcriptStore: TranscriptStore
    let vaultFinder: VaultFinder
    let permissions: RecordingPermissions
    let modelSetup: ModelSetup
    let transcriber: Transcriber
    let makeAudioCapture: @Sendable () -> AudioCapture
    let speakerDiarizer: SpeakerDiarizer
}
```

Do not pass `AppDependencies` into feature models. The root supplies exact collaborators:

- library model receives store/settings/vault finder;
- model setup controller receives model setup;
- recording/session factory receives capture/transcriber/diarizer/permissions/store/configuration;
- AppModel receives focused child models;
- status item remains beside the models.

Also replace `TranscriberEngine.Config` with a domain `RecordingConfiguration` before deleting the engine; it is currently referenced by chunking, live capture, and Whisper code.

## Implementation increments

1. Add characterization tests for final-chunk persistence, no-speech stop, diarization fallback, relocation identity, symlink resolution, duplicate setup start, and repeated menu-bar transitions.
2. Extract speaker values, parser, attribution, and command construction, with temporary forwarding where needed.
3. Extract the process runner and `LocalSpeakerDiarizer`; preserve current warning and fallback behavior.
4. Extract `ModelSetupController` and migrate `ModelSetupView`.
5. Extract `TranscriptLibraryModel` in two stages: list/search/selection, then destinations/relocation.
6. Extract `StatusItemController` and migrate GUI and Agent Mode roots to snapshots.
7. Complete the `RecordingSession` work, then introduce the final small `AppModel`.
8. Migrate GUI views to focused environment models.
9. Migrate Agent Mode to focused dependencies and awaited final results.
10. Delete compatibility forwarding and all `TranscriberEngine` extension files.

After each increment, `TranscriberEngine` must become smaller. Do not merely move existing responsibilities into an equally broad replacement.

## Test ownership

Add or migrate suites for:

- recording session transitions and integration;
- transcript library operations and search cancellation;
- model setup progress/retry/cancellation;
- diarization output parsing;
- speaker attribution;
- process runner output, errors, large streams, and cancellation;
- status-item rendering and click commands;
- AppModel cross-feature coordination; and
- Agent Mode readiness, fallback, finalization, and output contracts.

## Risks

- Extracting before concurrency ownership is established simply relocates races.
- A universal AppModel can become the same service locator under a new name.
- Moving native actions into feature/domain code breaks module direction.
- Process output can deadlock if pipes are read only after exit.
- Search results can publish out of order without latest-query cancellation.
- Compatibility forwarding can become permanent if deletion gates are not explicit.

## Completion criteria

- `TranscriberEngine` and its extensions are deleted.
- Recording, transcript library, model setup, diarization, and status-item behavior have distinct owners.
- `AppModel` performs only cross-feature composition and projection.
- Feature models receive exact dependencies rather than a universal container.
- GUI and Agent Mode share workflows but have separate composition shells.
- No view owns filesystem, network, process, or long-running capture resources.
