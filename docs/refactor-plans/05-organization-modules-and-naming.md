# Refactor Plan 5: Feature Organization, Modules, and Naming

## Objective

Make file placement, target boundaries, dependency direction, and names communicate product ownership. Begin with feature folders inside the current module, then promote only stable boundaries to `HoverCore` and `HoverPlatform`.

This plan follows the canonical build, concurrency, lifecycle, and engine-decomposition work. Moving files earlier is acceptable only when it is behavior-preserving and does not pretend to enforce dependencies.

## Target dependency graph

```text
HoverApp ───────────────> HoverCore
   │                         ▲
   └──────> HoverPlatform ───┘
```

### `HoverCore`

Contains domain values, pure rules, stable workflow protocols, parsers, and platform-independent workflows.

It must not import or use:

- SwiftUI or AppKit;
- ScreenCaptureKit or AVFoundation;
- Carbon;
- `NSApplication`, `NSWorkspace`, or `NSOpenPanel`;
- `Bundle.main`;
- filesystem, process, network, or `UserDefaults` effects.

Foundation value types such as `URL` and `Date` are acceptable.

### `HoverPlatform`

Contains concrete Apple-framework, filesystem, networking, and process adapters. It depends on `HoverCore` and never on `HoverApp`.

### `HoverApp`

Contains the application and Agent Mode shells, composition roots, feature models, SwiftUI/AppKit presentation, menu-bar behavior, hot keys, and app-owned resources. It depends on both supporting modules.

Do not create a module per screen or per small feature.

## Current dependency blockers

Correct these while code still compiles in one module:

1. `Chunker.swift`, `LiveAudioCapture.swift`, and `Transcriber.swift` depend on `TranscriberEngine.Config`. Introduce `RecordingConfiguration` and inject it.
2. `ModelSetup.swift` obtains artifact filenames from `InstallLayout`. Make `ModelArtifact` own its stable path and validation metadata.
3. Engine and Agent Mode code call `FileTranscriptStore` implementation statics. Move filename/markdown policy into a core value or the store contract.
4. `TranscriberEngine.init` constructs all concrete adapters. Add `AppDependencies` and remove production defaults from feature models.
5. `TranscriberEngine+Diarization.swift` mixes bundle lookup, workflow state, filesystem, process execution, parsing, and attribution. Split it according to Refactor Plan 4.
6. Protocols and implementations share files, preventing clean target membership.
7. Finder, open-panel, clipboard, application lifecycle, and bundle access are embedded in feature/workflow code. Keep native presentation actions in `HoverApp` or behind narrowly named adapters.

## Feature-first source layout

First move and split files inside the existing application module:

```text
Sources/
  App/
    Main.swift
    HoverApp.swift
    ContentView.swift
    AppDependencies.swift
    AgentMode/
      HoverCLI.swift
    MenuBar/
      StatusItemController.swift
    HotKeys/
      RecordingHotKeyController.swift

  Features/
    Recording/
      RecordingModel.swift
      LiveTranscriptView.swift
      RecordingToolbar.swift
      RecordButton.swift
      InputSourceMenu.swift
      RecordingPermissionSheet.swift

    TranscriptLibrary/
      TranscriptLibraryModel.swift
      SidebarView.swift
      SavedTranscriptView.swift
      MarkedTranscriptsView.swift
      WelcomeView.swift
      OutputDestinationButton.swift
      OutputDestinationChange.swift
      TranscriptCopyButton.swift

    ModelSetup/
      ModelSetupController.swift
      ModelSetupView.swift

    Settings/
      SettingsView.swift
      InstallCLIController.swift
      InstallCLIView.swift

  SharedUI/
    BrandColors.swift
    ToolbarPill.swift
    WipeShimmer.swift
    WindowTitleHidingView.swift
```

Only place a view in `SharedUI` when it is genuinely reused across features. A transcript Copy button is transcript-library behavior, not generic UI.

## `HoverCore` layout

```text
Packages/HoverModules/Sources/HoverCore/
  Recording/
    RecordingConfiguration.swift
    RecordingPhase.swift
    RecordingSession.swift
    InputSource.swift
    AudioCapture.swift
    AudioChunk.swift
    CaptureStatus.swift
    Chunker.swift
    AudioLevel.swift
    Transcriber.swift

  Transcripts/
    SavedTranscript.swift
    TranscriptLibrary.swift
    TranscriptStore.swift
    TranscriptDocument.swift

  Diarization/
    TextSegment.swift
    SpeakerTurn.swift
    SpeakerDiarizer.swift
    DiarizationOutputParser.swift
    SpeakerAttribution.swift

  Permissions/
    RecordingPermission.swift
    PermissionState.swift
    RecordingPermissions.swift
    RecordingPermissionRequest.swift

  OutputDestinations/
    OutputDestination.swift
    ObsidianVault.swift
    VaultFinder.swift

  Selection/
    Selection.swift

  Settings/
    SettingsStore.swift

  ModelSetup/
    ModelSetup.swift
    ModelSetupStatus.swift
    ModelArtifact.swift

  AgentMode/
    CLIOptions.swift
```

Strong current candidates include `AudioCapture.swift`, `AudioLevel.swift`, `Chunker.swift`, `CLIOptions.swift`, `Selection.swift`, and the protocol/domain halves of mixed files.

Do not move `TranscriberEngine` to Core. Only the focused recording workflow belongs there after decomposition.

## `HoverPlatform` layout

```text
Packages/HoverModules/Sources/HoverPlatform/
  Audio/
    LiveAudioCapture.swift
  Transcription/
    WhisperCLITranscriber.swift
    WAVFile.swift
  Transcripts/
    FileTranscriptStore.swift
  Diarization/
    LocalSpeakerDiarizer.swift
    DiarizationProcessRunner.swift
  ModelSetup/
    NetworkedModelSetup.swift
  Permissions/
    SystemRecordingPermissions.swift
  Settings/
    UserDefaultsSettings.swift
  Vaults/
    ObsidianVaultFinder.swift
  InstallLayout/
    InstallLayout.swift
  CLIInstallation/
    SystemInstallCLIFileSystem.swift
    PrivilegedCLIWrapperInstaller.swift
    InstallCLI.swift
```

Keep URLSession delegates, filesystem helpers, process plumbing, and concrete formatting internals non-public. Move `InMemorySettings` into test support rather than production Core.

## Generic files to split

- `Models.swift` → `InputSource.swift`, `ObsidianVault.swift`, `SavedTranscript.swift`.
- `DetailViews.swift` → live, saved, marked, and shimmer files.
- `ToolbarButtons.swift` → toolbar style, input menu, copy, and record files.
- `TranscriberEngine+Diarization.swift` → workflow, process runner, parser, and attribution.
- `Transcriber.swift` → protocol/error and Whisper implementation.
- `TranscriptStore.swift` → contract/domain library and filesystem implementation.
- `SettingsStore.swift` → contract and UserDefaults implementation.
- `RecordingPermissions.swift`, `VaultFinder.swift`, and `ModelSetup.swift` → contracts/domain values and concrete platform implementations.
- `InstallCLI.swift` → status/coordination and platform filesystem/process adapters.

## Naming plan

Required changes:

| Current | Planned |
| --- | --- |
| `TranscriberApp` | `HoverApp` |
| package/module `TranscriberKit` | `HoverCore` |
| `TranscriberEngine.Config` | `RecordingConfiguration` |
| `PendingOutputChange` | `PendingOutputDestinationChange` |
| `OutputOptionsButton` | `OutputDestinationButton` |
| `InputMenu` | `InputSourceMenu` |
| `LiveView` | `LiveTranscriptView` |
| `SavedView` | `SavedTranscriptView` |
| `HideWindowTitle` | `WindowTitleHidingView` |
| `HotKeys` | `RecordingHotKeyController` |
| `MenuBarMoth` | `StatusItemController` or a specific moth controller |

Decompose `TranscriberEngine` before naming its small remainder `AppModel`.

Remove `TranscriberEngine.transcriptsDir` if repository-wide search confirms it remains unused.

Replace generic `authError` with feature-specific typed failures or, temporarily, `presentedAlert: AppAlert?`.

## Domain language constraints

`CONTEXT.md` remains authoritative. Preserve:

- `Transcriber`
- `AudioCapture`
- `Chunk` for audio
- `Segment` for timestamped text
- `TranscriptStore`
- `OutputDestination`
- `VaultFinder`
- `Selection`
- `Group`
- `Relocate`
- `RecordingPermission`
- `SettingsStore`
- `ModelSetup`
- `InstallLayout`
- `Agent Mode`

Avoid generic `Manager`, `Helper`, `Service`, `Repository`, or `Util` types. “Helper” remains valid for the shipped executable artifact, not as a catch-all Swift abstraction.

## Implementation increments

### 1. Behavior-preserving folder moves

- Add feature/app/platform/shared-UI folders inside the current target.
- Move whole files where ownership is already clear.
- Split `Models.swift`, `DetailViews.swift`, and `ToolbarButtons.swift` without behavior changes.
- Apply straightforward type/file renames.
- Do not change module membership or formatting.

### 2. Split contracts from implementations

- Split every mixed protocol/concrete file.
- Extract diarization parser, attribution, process runner, and command construction.
- Move in-memory fakes to test support.
- Introduce `RecordingConfiguration`.
- Make model artifacts own stable metadata.
- Remove app dependencies on concrete store statics.
- Add `AppDependencies` and remove concrete feature-model defaults.

### 3. Finish feature model extraction

Complete `RecordingSession`, `TranscriptLibraryModel`, `ModelSetupController`, status ownership, and the small `AppModel`. Move native effects out of workflow/domain code.

### 4. Create `HoverCore`

- Add the local package target.
- Move domain files by product vocabulary.
- Expose only APIs needed by App and Platform.
- Build/test Core independently.
- Use `@testable import HoverCore` rather than widening implementation APIs for tests.

### 5. Create `HoverPlatform`

- Add a target depending only on `HoverCore`.
- Move concrete adapters.
- Pass app resource paths from `AppDependencies`; avoid moving app-owned resources merely to use `Bundle.module`.
- Verify no dependency on `HoverApp`.

### 6. Reorganize tests

```text
Tests/HoverCoreTests/
Tests/HoverPlatformTests/
Tests/HoverAppTests/
Tests/Support/
```

Split mixed suites and fake support by dependency ownership. Replace imports with the owning module.

## Access-control policy

- Public in Core: stable domain values, protocols, workflow commands/results, and necessary initializers/properties.
- Public in Platform: only concrete adapters and initializers the composition root constructs.
- Internal: parsers' implementation helpers, delegates, filesystem utilities, and subprocess plumbing.
- Internal to App: presentation and feature coordination.
- Do not make declarations public mechanically.
- Address module-boundary concurrency errors through isolation and `Sendable`, not unchecked conformances.

## Verification

For every increment:

- keep all existing tests green;
- build GUI and Agent Mode through the canonical scheme;
- verify all app resources and helpers still resolve;
- build/test `HoverCore` independently without UI/platform imports;
- build/test `HoverPlatform` with only a Core dependency;
- verify `HoverApp` owns presentation frameworks and native actions;
- exercise recording, tagging, destinations, transcript operations, setup, permissions, menu bar, CLI installation, and Agent Mode output; and
- keep formatting changes separate from moves and module promotion.

## Risks

- Combining moves, renames, modules, concurrency, and formatting obscures regressions.
- Moving app resources into a package changes lookup semantics.
- Excess public API can freeze implementation details prematurely.
- Folder boundaries alone do not enforce dependency direction.
- A universal AppModel or module-per-feature scheme reproduces the current coupling with more build complexity.
- Renaming away from `CONTEXT.md` weakens an existing architectural strength.

## Completion criteria

- The source tree communicates feature and platform ownership.
- `HoverCore` and `HoverPlatform` enforce inward dependency direction.
- Core compiles without SwiftUI/AppKit or platform effects.
- App-owned native presentation and resources remain in `HoverApp`.
- Generic mixed-purpose files are eliminated.
- Names follow Hover's domain glossary and Swift API Design Guidelines.
