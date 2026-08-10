# Hover Codebase Architecture Findings

## Purpose

This document records an initial architecture review of Hover, a native macOS application built with SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, and Swift concurrency.

The review covers:

- Application architecture and dependency direction
- Swift and SwiftUI conventions
- Naming and domain language
- Source-file and module organization
- Concurrency ownership
- Build and release structure
- Testing, formatting, and logging

The goal is not to impose a fashionable architecture or introduce unnecessary abstractions. The goal is to preserve Hover's good domain design while making ownership, concurrency, build configuration, and feature boundaries clearer and safer.

## Authoritative references

Apple does not prescribe MVVM, VIPER, Clean Architecture, or The Composable Architecture as the standard architecture for macOS applications. Its current guidance is principle-based: maintain a clear source of truth, separate model data from views, make ownership explicit, use platform-native application structure, and enforce safe concurrency boundaries.

The following resources should be treated as the baseline for future decisions:

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): canonical naming and API-design guidance. Clarity at the call site takes precedence over brevity.
- [Managing model data in a SwiftUI app](https://developer.apple.com/documentation/SwiftUI/Managing-model-data-in-your-app): Apple's current guidance on model/view separation, source-of-truth ownership, Observation, modularity, and testability.
- [Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/): guidance for `@Observable`, `@State`, `@Environment`, and `@Bindable`.
- [Swift 6 migration guide](https://www.swift.org/migration/): the authoritative guide to compiler-enforced data-race safety.
- [Swift 6 migration strategy](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/): an incremental, target-by-target migration approach.
- [Organizing code with local Swift packages](https://developer.apple.com/documentation/Xcode/organizing-your-code-with-local-packages): Apple's guidance for using local packages to improve modularity and maintenance.
- [Introducing Swift packages](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/introducingpackages/): explains products, targets, modules, and dependency boundaries.
- [Swift Testing](https://developer.apple.com/xcode/swift-testing/): the current testing framework for Swift packages and Xcode projects.
- [swift-format](https://github.com/swiftlang/swift-format): the formatter bundled with modern Swift toolchains. Its default configuration is not an official Swift style standard, so Hover should commit its own configuration.
- [Apple unified logging](https://developer.apple.com/documentation/os/logging): structured logging through `Logger`, subsystems, categories, levels, and privacy controls.
- [Building a great Mac app with SwiftUI](https://developer.apple.com/documentation/SwiftUI/building-a-great-mac-app-with-swiftui): macOS-specific SwiftUI application structure and controls.
- [Human Interface Guidelines: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars): macOS sidebar behavior and hierarchy.
- [Adding a settings interface to a macOS app](https://developer.apple.com/documentation/foundation/adding-a-settings-interface-to-your-app): platform-standard Settings scene guidance.

[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) is a mature and respected opinionated architecture. It is not an Apple standard, and adopting it would add reducers, actions, stores, effects, and an external dependency. Hover already has effective dependency seams and a manageable codebase, so TCA is not currently recommended.

## Current strengths

### Strong domain language

`CONTEXT.md` defines precise domain terminology and explicitly rejects ambiguous alternatives. Examples include `Transcriber`, `Chunk`, `Audio Capture`, `Transcript Store`, `Output Destination`, `Selection`, and `Model Setup`.

This vocabulary is a valuable architectural asset. Refactoring should preserve it instead of replacing specific domain names with generic names such as `Manager`, `Helper`, `Repository`, or `Service` without a concrete reason.

### Useful dependency seams

External behavior is already hidden behind protocols such as:

- `Transcriber`
- `AudioCapture`
- `TranscriptStore`
- `VaultFinder`
- `SettingsStore`
- `RecordingPermissions`
- `ModelSetup`

Production implementations can be replaced with fakes in tests. This is a sound foundation for extracting stable modules later.

### Pure domain rules

Rules such as chunking, audio-level calculation, transcript selection, CLI option parsing, and speaker attribution are mostly represented as value types or pure functions. These are easy to test and are natural candidates for a platform-independent core target.

### Current SwiftUI data flow

The application already uses the Observation framework and supplies its observable application model through the SwiftUI environment. This follows modern Apple guidance and should be retained.

### Test baseline

At the time of this review, all 141 tests in 19 suites pass. The test suite covers pure rules, adapters, permissions, model setup, output destinations, CLI behavior, and integration seams.

## Main findings

## 1. The build has multiple sources of truth

`Package.swift` states that SwiftPM exists only for testing. Development and release scripts compile all source files directly with `swiftc` and manually assemble an application bundle.

As a result, several systems independently define:

- Source membership
- Framework linkage
- Deployment target
- Bundle identifier
- Version numbers
- Resources
- `Info.plist` keys
- Entitlements and signing behavior

Configuration has already drifted:

- `Package.swift` declares macOS 14 because SwiftUI Observation requires macOS 14.
- Development and release `Info.plist` content declares macOS 13.
- Development and release builds use different bundle identifiers.
- The package manifest still describes a Command Line Tools-only environment even though the active toolchain comes from a full Xcode installation.
- SwiftPM builds in Swift 5 language mode to avoid concurrency errors, while the installed toolchain is Swift 6.3.

### Recommendation

Create one canonical application build graph.

The preferred native macOS setup is:

- An Xcode `Hover` app target owns the bundle, deployment target, resources, entitlements, build settings, and application metadata.
- Local Swift packages or package targets own reusable core and platform code.
- Standard test targets exercise those modules.
- Release scripts orchestrate the canonical build and packaging process rather than compiling the application independently.

Helper acquisition, notarization, and distribution may remain scripted because they are release operations rather than application compilation.

## 2. `TranscriberEngine` has too many responsibilities

`TranscriberEngine` spans approximately 1,243 lines across its base file and extensions. It currently owns or coordinates:

- Observable UI state
- Recording lifecycle
- Recording permissions
- Audio capture callbacks
- Transcription
- Speaker diarization
- External process execution
- Transcript persistence and library refresh
- Transcript selection
- Output destinations and relocation
- User settings
- Model setup and download progress
- GUI behavior used by the CLI
- Recording-completion callbacks
- Background dispatch queues

Moving methods into extension files improves navigation but does not reduce responsibility or coupling.

The type also receives eight major dependencies during initialization, in addition to owning queues and completion closures. This is evidence that it has become the application rather than one cohesive component.

### Recommendation

Decompose the type by behavior and ownership:

- `AppModel`: a small `@MainActor @Observable` composition model exposed to SwiftUI.
- `RecordingSession`: owns the lifecycle of one recording and its resulting transcript.
- `TranscriptLibraryModel`: observable transcript list, groups, search results, and selection coordination.
- `ModelSetupController`: observable setup progress and retry behavior.
- `SpeakerDiarizer`: the side-effecting speaker-analysis dependency.
- `SpeakerAttribution`: pure logic that merges transcript segments with speaker turns.
- Existing platform adapters remain responsible for audio, filesystem, settings, permission, process, and network APIs.

The exact type names should be validated against actual call sites before implementation. The important change is responsibility, not merely renaming.

## 3. Concurrency ownership is implicit

The test build currently reports five concurrency warnings that become errors in Swift 6 language mode. The warnings originate from capturing `TranscriberEngine` across `@Sendable` and concurrently executing closures.

The engine is mutable observable UI state, but it is not isolated to `MainActor`. It instead combines:

- `DispatchQueue.main.async`
- `MainActor.run`
- Unstructured `Task` creation
- A transcription dispatch queue
- A diarization dispatch queue
- Callback properties
- Mutable state accessed from different execution contexts

Comments document intended queue ownership, but the compiler cannot enforce those comments.

### Recommendation

Establish explicit isolation rules:

- Every UI-facing observable model is `@MainActor`.
- Mutable background workflows use actors or clearly isolated async types.
- Values crossing isolation boundaries conform to `Sendable` where appropriate.
- Prefer structured `async` functions over callback properties and polling flags.
- Keep GCD only at callback boundaries where Apple frameworks require it.
- Bridge long-running processes and delegate callbacks into async APIs.
- Enable complete concurrency checking before enabling Swift 6 language mode.
- Migrate target by target, following the official Swift migration strategy.

`stopRecording()` should ultimately be able to return or asynchronously produce the final `SavedTranscript`. The CLI should not need a completion closure plus polling state to learn when recording has finished.

## 4. Recording state permits invalid combinations

Recording lifecycle is represented through several independent values:

- `isRecording`
- `recordingTitle`
- `committedChunks`
- `statusMessage`
- `authError`
- `permissionRequest`
- `lastRecordingTranscript`
- Derived `isProcessing`

This allows contradictory states to be represented, even if current control flow usually avoids them. For example, a title can exist while recording and processing are both false, or an error and a permission request can coexist without the type system explaining which one controls the UI.

### Recommendation

Represent lifecycle with an explicit state machine:

```swift
enum RecordingPhase {
    case idle
    case requestingPermission(RecordingPermissionRequest)
    case starting
    case recording(RecordingSessionState)
    case processing(RecordingSessionState)
    case failed(RecordingFailure)
}
```

The exact associated values can evolve. The main benefit is that buttons, labels, availability, processing indicators, and error presentation become derived from one source of truth.

Model setup should follow the same principle. Its existing `ModelSetupStatus` enum is already a good example.

## 5. Source organization is flat and sometimes groups by syntax

All application code currently lives in one `Sources` directory and one Swift module. Generic filenames include:

- `Models.swift`
- `DetailViews.swift`
- `ToolbarButtons.swift`

These names group declarations by their Swift or visual category rather than by the behavior they implement. As the application grows, this makes ownership and dependencies harder to see.

### Recommendation

Begin with feature-oriented folders inside the current module:

```text
Sources/
  App/
    HoverApp.swift
    HoverMain.swift
    AppModel.swift
    AppDependencies.swift

  Features/
    Recording/
      RecordingModel.swift
      RecordingView.swift
      RecordingToolbar.swift
      RecordingPermissionSheet.swift

    TranscriptLibrary/
      TranscriptLibraryModel.swift
      SidebarView.swift
      TranscriptDetailView.swift
      OutputDestinationPicker.swift

    ModelSetup/
      ModelSetupController.swift
      ModelSetupView.swift

    Settings/
      SettingsView.swift
      InstallCLIController.swift

  Domain/
    Recording/
    Transcripts/
    Diarization/
    Permissions/
    Selection/

  Platform/
    Audio/
    FileSystem/
    Processes/
    Networking/
    macOS/

  SharedUI/
```

Folders improve navigation but do not enforce dependencies. Once these boundaries stabilize, promote them into real targets.

## Real-world macOS application research

The principle-based guidance above was compared with six established, public, native macOS applications:

- [IINA](https://github.com/iina/iina)
- [Stats](https://github.com/exelban/stats)
- [UTM](https://github.com/utmapp/UTM)
- [MonitorControl](https://github.com/MonitorControl/MonitorControl)
- [Ice](https://github.com/jordanbaird/Ice)
- [Rectangle](https://github.com/rxhanson/Rectangle)

Each repository was inspected independently at a pinned commit. The review covered its source tree, Xcode targets, build configuration, application composition, state ownership, platform adapters, concurrency, testing, release automation, and representative implementation files.

These repositories are evidence of production tradeoffs, not standards to copy wholesale. Several are successful despite large global coordinators, manual GCD synchronization, or weak automated testing. The useful method is therefore:

1. Identify a concrete pattern in the repository.
2. Understand the problem that pattern solves.
3. Transfer the underlying principle to Hover.
4. Avoid importing historical constraints or accidental complexity.

## IINA

Snapshot: [`a25ed139`](https://github.com/iina/iina/tree/a25ed1390eff00cbed5f2eca045ee8dccd28d791).

### Observed architecture

- IINA documents enforceable ownership rules: only `VideoView` and `MPVController` may call mpv directly, `PlayerCore` owns playback logic, and `MainWindowController` owns window lifecycle. It also identifies generated files that contributors must not edit manually. See [IINA's contributor architecture rules](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/CONTRIBUTING.md#L64-L74).
- Each playback window has its own `PlayerCore`, including playback state, mpv adapter, plugins, and work queues. See [`PlayerCore`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina/PlayerCore.swift#L21-L87).
- `MPVController` is the narrow owner of mpv handles, property observation, render context, and event processing. Foreign API concepts are concentrated there rather than repeated through the UI. See [`MPVController`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina/MPVController.swift#L87-L118).
- The Xcode project owns the application, CLI, Safari extension, and plugin tool. Layered `.xcconfig` files centralize shared, deployment, debug, release, beta, and nightly settings. See [the target graph](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina.xcodeproj/project.pbxproj#L2744-L2834), [`Shared.xcconfig`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/Configs/Shared.xcconfig), and [`Deployment.xcconfig`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/Configs/Deployment.xcconfig).
- CI builds the checked-in Xcode scheme through the same production build graph. See [IINA CI](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/.github/workflows/ci.yml#L12-L41).
- Its concurrency model is largely based on named queues, locks, atomic wrappers, and documented thread-affinity rules, although newer code has begun adopting `@MainActor` and async APIs. See [`HistoryController`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina/HistoryController.swift#L21-L122) and [`Dialog`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina/Dialog.swift#L9-L105).
- The source tree is mostly flat, and central types have grown very large. `AppDelegate`, `PlayerCore`, `MainWindowController`, and `MPVController` carry broad responsibilities. See the [IINA source tree](https://github.com/iina/iina/tree/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina) and [`AppDelegate`](https://github.com/iina/iina/blob/a25ed1390eff00cbed5f2eca045ee8dccd28d791/iina/AppDelegate.swift#L24-L109).
- The inspected project and CI workflow do not define or run an automated test target.

### Applied takeaway for Hover

Adopt:

- Write down enforceable platform ownership rules, not only a layer diagram.
- Model one recording as a cohesive `RecordingSession`, as IINA models one player operation with `PlayerCore`.
- Keep ScreenCaptureKit, AVFoundation, Whisper, and helper-process APIs inside narrow adapters.
- Use one Xcode build graph with layered `.xcconfig` files.
- Make CI exercise the production build path.
- Preserve IINA's concrete, domain-specific naming style.

Avoid:

- A static registry of recording sessions unless Hover genuinely supports simultaneous sessions.
- Replacing `TranscriberEngine` with an equally broad `AppDelegate` or `AppModel`.
- A flat directory containing every view, adapter, model, and coordinator.
- Treating manually documented queues and locks as the target concurrency model.
- Copying IINA's missing automated test gate.

## Stats

Snapshot: [`4b8f1e0`](https://github.com/exelban/stats/tree/4b8f1e0f32ffef76ed4d34118f243bbc76186809).

### Observed architecture

- CPU, GPU, RAM, Disk, Network, Battery, Sensors, Bluetooth, Clock, and Remote are separate framework targets. They depend primarily on a shared `Kit`, while the application target composes them. The same Xcode graph owns the app, widget extension, helpers, and tests. See [Stats' target definitions](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Stats.xcodeproj/project.pbxproj#L1483-L1829) and [application composition](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Stats/AppDelegate.swift#L10-L38).
- Features follow a repeated vertical-slice layout: coordinator/model, readers, popup, settings, portal, notifications, preview, widget, and configuration. CPU is representative: [`main.swift`](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Modules/CPU/main.swift), [`readers.swift`](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Modules/CPU/readers.swift), and [`settings.swift`](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Modules/CPU/settings.swift).
- Shared `Module` and `Reader<T>` abstractions centralize enable/disable behavior, polling, cached values, callbacks, and resource lifecycle. Readers can pause when their popup or preview is not visible. See [`Module`](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Kit/module/module.swift) and [`Reader<T>`](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Kit/module/reader.swift).
- `MenuBar` and `SWidget` own status-item creation, ordering, width, persistence, and click routing. Feature readers publish values rather than manipulating `NSStatusItem` directly. See [Stats' menu-bar ownership](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Kit/module/widget.swift#L233-L562).
- Platform acquisition code remains at the feature edge. For example, RAM's Mach APIs, processes, and parsing live in its reader implementation, while parsing has fixture-backed tests. See [RAM readers](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Modules/RAM/readers.swift#L14-L275) and [RAM tests](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Tests/RAM.swift).
- Xcode owns archive production. Release automation validates embedded-product and version invariants rather than rebuilding the application independently. See the [Stats Makefile](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/Makefile) and [build workflow](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/.github/workflows/build.yaml).
- Stats remains in Swift 5 mode and relies heavily on queues, locks, main-queue dispatch, globals, singletons, and untyped `NotificationCenter` payloads.
- Separate workflows build/archive, lint, and validate localization, but the test suite is small and is not run by the archive workflow. See [build](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/.github/workflows/build.yaml), [lint](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/.github/workflows/linter.yaml), and [localization validation](https://github.com/exelban/stats/blob/4b8f1e0f32ffef76ed4d34118f243bbc76186809/.github/workflows/i18n.yaml).

### Applied takeaway for Hover

Adopt:

- A repeated internal layout for substantial features.
- Explicit resource lifecycle owners.
- A dedicated `StatusItemController` or `MenuBarCoordinator` that owns AppKit menu-bar objects.
- Separation of process invocation from deterministic output parsing.
- Build-output validation in release automation.
- Compiler-enforced modules when a capability has a stable API and independent tests.

Avoid:

- Creating one dynamic framework per small Hover feature.
- An inheritance-heavy base `Module` that knows every UI surface.
- Global module arrays, singleton storage, and notification dictionaries as a command bus.
- Stats' generic lowercase filenames such as repeated `main.swift` and `settings.swift`; use descriptive Swift filenames.
- Its Swift 5/GCD concurrency model and weak CI test enforcement.

## UTM

Snapshot: [`8e4de50`](https://github.com/utmapp/UTM/tree/8e4de50817e76a83d6840212311627a78dd4f8b2).

### Observed architecture

- UTM separates `Platform/Shared`, `Platform/macOS`, `Platform/iOS`, and `Platform/visionOS`, while backend and persisted configuration code live in `Services` and `Configuration`. The macOS shell constructs shared state and injects it into shared SwiftUI content. See [the Platform tree](https://github.com/utmapp/UTM/tree/8e4de50817e76a83d6840212311627a78dd4f8b2/Platform), [macOS composition](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Platform/macOS/UTMApp.swift), and [shared content](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Platform/Shared/ContentView.swift).
- `UTMVirtualMachine` defines a backend-neutral lifecycle and persistence contract. QEMU and Apple's Virtualization framework implement it separately, while `VMData` presents a UI-facing wrapper around any backend. See [`UTMVirtualMachine`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Services/UTMVirtualMachine.swift), [`UTMQemuVirtualMachine`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Services/UTMQemuVirtualMachine.swift), [`UTMAppleVirtualMachine`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Services/UTMAppleVirtualMachine.swift), and [`VMData`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Platform/VMData.swift).
- VM lifecycle is represented by one typed state with cases such as stopped, starting, started, pausing, saving, and stopping. See [UTM's lifecycle state](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Services/UTMVirtualMachine.swift#L213).
- Persisted configuration is composed from smaller domain values. Loading verifies versions and backend identity, and legacy migrations live in a dedicated folder. See [`UTMQemuConfiguration`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Configuration/UTMQemuConfiguration.swift), [`UTMConfiguration.load`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Configuration/UTMConfiguration.swift), and [legacy migrations](https://github.com/utmapp/UTM/tree/8e4de50817e76a83d6840212311627a78dd4f8b2/Configuration/Legacy).
- UI-facing models are `@MainActor`, and some long-running mutable services are actors. However, central models still mix actors, detached tasks, dispatch queues, and main-actor state. See [`UTMData`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Platform/UTMData.swift) and [`UTMRemoteServer`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Remote/UTMRemoteServer.swift).
- The app composition root is compact, but `UTMData` is approximately 1,476 lines and owns presentation flags, selection, persistence, import, downloads, remote coordination, busy execution, and errors.
- One Xcode project owns app, CLI, helper, launcher, renderer, and framework targets. `Build.xcconfig` centralizes versions and entitlement selection, and CI drives the same graph. See [`Build.xcconfig`](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/Build.xcconfig), [the macOS scheme](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/UTM.xcodeproj/xcshareddata/xcschemes/macOS.xcscheme), and [build CI](https://github.com/utmapp/UTM/blob/8e4de50817e76a83d6840212311627a78dd4f8b2/.github/workflows/build.yml).
- The inspected macOS scheme has no testables, and its build workflow does not run tests.

### Applied takeaway for Hover

Adopt:

- Thin platform/application shells around shared workflows.
- Backend-neutral contracts with concrete macOS/process implementations.
- A typed recording lifecycle rather than coordinated booleans.
- Smaller persisted settings/configuration values with explicit schema versions and migrations.
- `@MainActor` UI state and actor-owned background workflows.
- One Xcode-owned product graph.

Avoid:

- Creating platform folders merely for symmetry while Hover remains macOS-only.
- A universal `AppModel` comparable to `UTMData`.
- Mixing GCD, actors, detached tasks, and main-actor state without one isolation design.
- Multiple helper targets without distinct runtime, security, lifecycle, or packaging needs.
- Pervasive `Hover` prefixes; Swift module and feature context should carry most names.
- UTM's absence of automated test enforcement.

## MonitorControl

Snapshot: [`3cfc405`](https://github.com/MonitorControl/MonitorControl/commit/3cfc40598abbe3d36f5235b9535234a2ab525459).

### Observed architecture

- One Xcode project owns the main app and a small login-launch helper. The helper has one narrow responsibility: find and launch the containing app, then terminate. See [project targets](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl.xcodeproj/project.pbxproj#L376-L423) and [the helper entry point](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControlHelper/main.swift#L3-L26).
- The app uses global mutable application/menu/settings values, while `AppDelegate` constructs keyboard, audio, updater, status-item, and settings dependencies. See [global application state](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/main.swift#L16-L35) and [`AppDelegate`](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/AppDelegate.swift#L13-L51).
- Display, ColorSync, audio-device, accessibility, sleep, and wake events are coordinated centrally. Generation identifiers and delayed callbacks prevent stale work from winning. See [event subscriptions](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/AppDelegate.swift#L170-L179), [display reconfiguration](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/AppDelegate.swift#L118-L155), and [sleep/wake handling](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/AppDelegate.swift#L181-L228).
- `DisplayManager` discovers displays and chooses capability implementations. `OtherDisplay` can use Intel DDC, Apple Silicon DDC, or software fallback. See [display discovery](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/DisplayManager.swift#L163-L190) and [backend branching](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Model/OtherDisplay.swift#L380-L444).
- `MenuHandler` derives a status menu from detected displays, preferences, capabilities, and current state. See [dynamic menu projection](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/MenuHandler.swift#L31-L102).
- Preference keys are typed, including per-display persistence, but model objects directly access global `UserDefaults`. See [`PrefKey`](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Enums/PrefKey.swift#L3-L95) and [display persistence](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Model/Display.swift#L34-L85).
- Hardware operations use global/per-display queues, barriers, semaphores, synchronous dispatch, delayed work, and sleeps. The project remains in Swift 5.5 without strict concurrency. See [global DDC queue](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Support/DisplayManager.swift#L7-L15) and [per-display serialization](https://github.com/MonitorControl/MonitorControl/blob/3cfc40598abbe3d36f5235b9535234a2ab525459/MonitorControl/Model/OtherDisplay.swift#L257-L297).
- Dependencies are resolved through Xcode and pinned in `Package.resolved`. Formatting and linting are build phases, but formatting mutates source during a build and silently skips if tools are missing. The inspected repository defines no automated test target or CI workflow.

### Applied takeaway for Hover

Adopt:

- Create auxiliary executable targets only for a distinct runtime or packaging role.
- Treat native macOS lifecycle events as a coordination domain.
- Select capture/transcription/diarization capabilities at a platform composition boundary.
- Derive menu-bar UI from a typed state snapshot.
- Give persistent resources explicit stable identities.
- Commit dependency resolution and prefer versioned dependencies.

Avoid:

- Global application state and domain objects that directly reach `UserDefaults`.
- Subclassing plus architecture conditionals for backend selection; use protocols and composition.
- Integer generation counters and arbitrary delays where cancellable tasks and typed state can express the workflow.
- Queues, semaphores, and synchronous dispatch as the default concurrency strategy.
- Formatting that mutates tracked files during a normal build.
- MonitorControl's absent test and CI gates.

## Ice

Snapshot: [`11edd39`](https://github.com/jordanbaird/Ice/tree/11edd39115f3f43a83ae114b5348df6a0e1741cf).

### Observed architecture

- Ice organizes one application target by product concepts: `Main`, `MenuBar`, `Permissions`, `Settings`, `Hotkeys`, `Events`, `Updates`, and `UserNotifications`. The folders communicate ownership, but they do not enforce module dependencies. See [the Ice source tree](https://github.com/jordanbaird/Ice/tree/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice) and [target/package graph](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice.xcodeproj/project.pbxproj#L70-L135).
- `IceApp` constructs one `AppState`, adapts `NSApplicationDelegate`, runs migrations, and declares Settings and Permissions scenes. The delegate owns native activation/lifecycle details, while `AppState.performSetup()` starts feature subsystems. See [`IceApp`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Main/IceApp.swift#L8-L22), [`AppDelegate`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Main/AppDelegate.swift#L8-L65), and [`performSetup`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Main/AppState.swift#L180-L192).
- `AppState` is `@MainActor` and owns many feature managers. Most managers receive the entire `AppState`, making it a service locator and creating broad sibling knowledge. See [`AppState`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Main/AppState.swift#L9-L49) and [`SettingsManager`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Settings/SettingsManagers/SettingsManager.swift#L8-L37).
- OS-specific quirks are given named owners: `ScreenCapture`, `EventTap`, and `ControlItem` contain permission workarounds, Core Graphics bridges, run-loop ownership, status-item construction, and documented compatibility hacks. See [`ScreenCapture`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Utilities/ScreenCapture.swift#L9-L99), [`EventTap`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Events/EventTap.swift#L8-L160), and [`ControlItem`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/ControlItem/ControlItem.swift#L84-L125).
- Finite product state is represented with domain enums for permissions, menu-bar sections, hiding state, navigation, hotkey actions, and rehide strategies. See [`PermissionsState`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Permissions/PermissionsManager.swift#L9-L20) and [`ControlItem.HidingState`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/ControlItem/ControlItem.swift#L9-L37).
- Settings are divided by user concern, stable keys are centralized, deprecated keys are retained for migration, and versioned migrations run at startup. See [`Defaults.Key`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Utilities/Defaults.swift#L138-L200) and [`MigrationManager`](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Utilities/MigrationManager.swift#L15-L68).
- UI/AppKit types use `@MainActor`, and low-level callbacks use explicit `nonisolated` bridges. However, the target remains in Swift 5 mode without strict-concurrency checking. See [event callback isolation](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Events/EventTap.swift#L85-L160) and [build settings](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice.xcodeproj/project.pbxproj#L303-L365).
- Ice has one Xcode-owned product graph and strict SwiftLint CI, but no test target. Complexity, file-length, function-length, naming, and type-length rules are globally disabled. See [the scheme](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice.xcodeproj/xcshareddata/xcschemes/Ice.xcscheme#L5-L76), [lint CI](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/.github/workflows/lint.yml#L1-L23), and [lint configuration](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/.swiftlint.yml#L1-L16).

### Applied takeaway for Hover

Adopt:

- Feature-language folders before introducing many modules.
- A minimal app/delegate composition root.
- Explicit `@MainActor` ownership for AppKit and observable UI state.
- Named, documented adapters for OS-version workarounds.
- Typed finite states.
- Domain-grouped settings and versioned migrations.
- One Xcode build graph with automatic lint/format verification.

Avoid:

- Passing a universal `AppModel` to every feature.
- Generic `Manager` proliferation and manually forwarded child observation.
- Concrete/static platform dependencies where Hover already has good protocols.
- Fixed startup delays instead of explicit readiness events.
- Globally disabling size and complexity signals.
- Ice's absence of test/build CI.

## Rectangle

Snapshot: [`55397e0`](https://github.com/rxhanson/Rectangle/tree/55397e034b4f16d837b5658cada04f777dd5661d).

### Observed architecture

- Rectangle represents operations as typed `WindowAction` values and routes them through `WindowCalculation` implementations. Calculations accept value parameters and return geometry/results before Accessibility effects occur. See [`WindowAction`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/WindowAction.swift), the [`WindowCalculation` contract](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/WindowCalculation/WindowCalculation.swift), and a representative [`LeftRightHalfCalculation`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/WindowCalculation/LeftRightHalfCalculation.swift).
- `WindowManager` applies an ordered strategy chain of `WindowMover` implementations, including standard, edge-alignment, and best-effort behavior. See [`WindowManager`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/WindowManager.swift) and [`WindowMover`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/WindowMover/WindowMover.swift).
- Raw `AXUIElement` is wrapped in a semantic `AccessibilityElement` that exposes window frame, minimum size, role, window identity, fullscreen state, and workarounds. See [`AccessibilityElement`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/AccessibilityElement.swift).
- Operational components are constructed only after Accessibility permission becomes trusted. See [permission-gated composition](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/AppDelegate.swift#L130-L143).
- `ShortcutManager` injects its binding store, notification centers, providers, delayed scheduler, and session callback. Tests replace them with isolated fakes/spies to verify lifecycle and timing without global shortcuts. See [`ShortcutManager`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/ShortcutManager.swift#L7-L84) and [its tests](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/RectangleTests/RectangleTests.swift#L2986-L3242).
- Most code remains one application target, but directories and precise filenames organize substantial responsibilities such as `WindowCalculation`, `WindowMover`, `Snapping`, `AccessibilityAuthorization`, and `MultiWindow`. See [project targets](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle.xcodeproj/project.pbxproj#L805-L863).
- Third-party dependencies are narrow: MASShortcut and Sparkle. See [package references](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/Rectangle/Rectangle.xcodeproj/project.pbxproj#L1558-L1588).
- Rectangle has approximately 205 unit tests emphasizing geometry edge cases, repeated actions, monitor changes, shortcut state, and idempotency. Most live in one roughly 3,561-line file, and packaging CI does not run them. See [`RectangleTests.swift`](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/RectangleTests/RectangleTests.swift) and [build workflow](https://github.com/rxhanson/Rectangle/blob/55397e034b4f16d837b5658cada04f777dd5661d/.github/workflows/build.yml).
- The project remains in Swift 5 and uses GCD, NotificationCenter, and dedicated run-loop threads rather than actors or structured concurrency. A dedicated run loop is appropriate for APIs that require one, but not as the application's general concurrency model.

### Applied takeaway for Hover

Adopt:

- Normalize platform inputs, apply pure domain decisions, then perform platform effects.
- Wrap low-level macOS APIs in semantic Hover vocabulary.
- Use a strategy/fallback chain where an unreliable platform boundary genuinely needs graceful degradation.
- Construct/start resources only after permissions and model prerequisites are satisfied.
- Inject volatile collaborators such as clocks, schedulers, event sources, permissions, and stores.
- Use responsibility-oriented directories and precise type/filename pairs.
- Test repeated events, cancellation, delays, idempotency, and lifecycle races densely.

Avoid:

- Letting pure calculation code read global defaults or AppKit values.
- Using strategy chains for ordinary linear workflows.
- A large `AppDelegate`, global defaults, and singleton command routing.
- Replacing one large engine with an enormous action enum/factory or hundreds of near-identical types.
- One monolithic test file and packaging CI that never runs tests.
- Rectangle's Swift 5/GCD-only concurrency as the target for new work.

## Cross-repository synthesis

### Patterns with the strongest real-world support

The following patterns recur across multiple unrelated applications and should be considered high-confidence guidance for Hover.

#### 1. One Xcode-owned product graph

IINA, Stats, UTM, MonitorControl, Ice, and Rectangle all use Xcode as the authoritative owner of native products, resources, packages, and schemes. Their release scripts invoke or package that graph; they do not maintain a second independent Swift source graph comparable to Hover's current test/package versus `swiftc` split.

This substantially strengthens the recommendation to make one Hover Xcode app target authoritative. It is the clearest cross-project consensus.

#### 2. A thin composition root

Every application needs one place that constructs concrete dependencies and handles native lifecycle. The best examples keep that role visible and small. The recurring failure mode is allowing the root state/delegate to absorb feature behavior, producing types such as IINA's `AppDelegate`, UTM's `UTMData`, Ice's `AppState`, and Rectangle's `AppDelegate`.

Hover should keep `HoverApp`/its delegate as the composition root, but `AppModel` must compose focused feature models rather than become a renamed `TranscriberEngine`.

#### 3. Platform APIs behind semantic boundaries

IINA's `MPVController`, UTM's VM backends, Ice's `EventTap`, Rectangle's `AccessibilityElement`, Stats' readers, and MonitorControl's display implementations all isolate difficult native or third-party behavior.

Hover already has good protocol seams. The applied improvement is to make concrete adapters the only types allowed to import or expose ScreenCaptureKit, AVFoundation capture plumbing, helper-process details, Whisper paths, and macOS permission APIs.

#### 4. State grouped by lifecycle

IINA creates one `PlayerCore` per playback lifecycle. UTM represents VM lifecycle with one enum. Ice uses typed finite states. Rectangle gates operational construction on permission state. These patterns all support introducing `RecordingSession` and `RecordingPhase`.

This is not only a SwiftUI presentation technique. It is a way to prevent impossible combinations and keep cancellation, cleanup, and finalization owned by the workflow that creates them.

#### 5. Feature-first source organization before aggressive modularization

Stats demonstrates strong compiler-enforced feature modules, while Ice and Rectangle demonstrate that responsibility-oriented folders can provide most navigation benefits before each feature deserves a target. IINA demonstrates the long-term cost of a very flat source directory.

For Hover, begin with `Recording`, `TranscriptLibrary`, `ModelSetup`, `Diarization`, `Settings`, `App`, and `Platform` folders. Promote only stable dependency boundaries into `HoverCore` and `HoverPlatform`; do not create a target per view.

#### 6. Explicit ownership of long-running resources

Stats centralizes reader lifecycle. IINA groups player queues and shutdown work. MonitorControl serializes display operations. Rectangle owns event run loops. Although several use legacy synchronization, their shared principle is correct: every long-running resource needs one lifecycle owner.

Hover should assign clear owners for capture, live transcription, diarization, model downloads, menu-bar UI, and transcript persistence. Views should consume state and send commands, never own these resources.

#### 7. Pure transformation separated from platform effects

Rectangle provides the clearest example by calculating geometry before Accessibility mutations. Stats separates some process-output parsing for fixture tests. UTM composes persisted configuration from small values.

Hover should explicitly separate:

```text
Capture callback             -> AudioChunk domain value
Diarization process output   -> DiarizationOutputParser -> [SpeakerTurn]
Transcript destination input -> OutputDestination decision
Domain result                -> TranscriptStore mutation
```

#### 8. Menu-bar ownership as a projection of state

Stats centralizes `NSStatusItem` behavior, while MonitorControl rebuilds the menu from current capabilities and settings. Ice gives status-item quirks named owners.

Hover's `MenuBarMoth` should evolve into or sit behind a `StatusItemController` isolated to `MainActor`. It should render a typed snapshot derived from application state and route typed commands back. Recording and transcription services should know nothing about `NSStatusItem`.

#### 9. Persistence requires identity, versioning, and migration

UTM versions its configuration and isolates legacy migrations. Ice centralizes keys and startup migrations. MonitorControl shows why stable hardware identity matters, but also why direct model-to-`UserDefaults` coupling becomes limiting.

Hover should preserve stable transcript identities, define versioned settings/configuration migrations, and keep persistent schema knowledge in `SettingsStore`, `TranscriptStore`, and dedicated migration code.

#### 10. Production success does not imply modern concurrency

Most inspected applications remain in Swift 5 mode and use GCD, locks, semaphores, notification buses, or manual run-loop ownership. Ice and UTM have partial `@MainActor`/actor adoption, but neither supplies a complete model to copy.

The transferable principle is explicit ownership and serialization. Hover should implement that principle using Swift 6 tools: `@MainActor`, actors, structured tasks, cancellation, `AsyncSequence`, and `Sendable` values. The older applications explain the problem; the Swift migration guide supplies the modern mechanism.

#### 11. Preserve Hover's testing advantage

IINA, UTM, MonitorControl, and Ice have no meaningful automated test target in the inspected graph. Stats has few tests, and Rectangle has many tests that packaging CI does not run. Hover already has 141 passing tests and therefore starts from a stronger position than these larger projects.

Do not weaken that advantage during Xcode migration. Tests must remain a first-class target and a required CI gate before archive or release packaging.

### Applied architecture decisions after the case studies

The real-world research changes or sharpens the initial proposal in the following ways:

1. **Make the Xcode migration Phase 1, not an optional cleanup.** It is the strongest consensus across all six repositories.
2. **Keep only three initial product/code boundaries:** `HoverApp`, `HoverCore`, and `HoverPlatform`. Stats shows that more feature modules can work, but Hover does not yet justify their build complexity.
3. **Add a dedicated `StatusItemController` to `HoverApp`.** Stats, MonitorControl, and Ice strongly support isolating AppKit menu-bar behavior.
4. **Make `RecordingSession` the main workflow aggregate.** IINA and UTM validate grouping state and operations by lifecycle.
5. **Keep `AppModel` small and dependency-specific.** IINA, UTM, Ice, and Rectangle all provide examples of central types becoming service locators or god objects.
6. **Split invocation from parsing.** `DiarizationProcessRunner` should not also own `DiarizationOutputParser`; the same rule applies to Whisper output if parsing becomes nontrivial.
7. **Introduce an explicit application readiness phase.** Permissions and model availability should gate construction/start of operational resources, following Rectangle and Ice.
8. **Use fallback strategies only at unstable boundaries.** Capture availability, helper discovery, or transcription backend selection may justify a small ordered strategy chain; ordinary workflows do not.
9. **Add schema migration infrastructure before changing settings or transcript formats.** UTM and Ice demonstrate that this becomes necessary in mature applications.
10. **Require tests, formatting, strict concurrency, and a production-scheme build in CI.** This intentionally improves on the common test gaps in the reference repositories.

## Recommended target architecture

A suitable eventual structure for the current codebase size is three primary targets rather than one target per feature:

### `HoverCore`

Contains domain values, pure rules, and dependency protocols. It should not import SwiftUI or AppKit.

Likely contents:

- `AudioChunk` and `Chunker`
- `AudioLevel`
- `InputSource`
- `SavedTranscript` and `TranscriptLibrary`
- `Selection`
- `TextSegment`, `SpeakerTurn`, and pure speaker-attribution logic
- `RecordingPhase`, `RecordingSessionState`, and the `RecordingSession` workflow
- Pure parsers for helper-process output
- CLI option parsing
- Protocols such as `Transcriber`, `AudioCapture`, `TranscriptStore`, `SettingsStore`, `RecordingPermissions`, `VaultFinder`, and `ModelSetup`

### `HoverPlatform`

Contains concrete adapters for Apple frameworks, the filesystem, subprocesses, and networking. It depends on `HoverCore`.

Likely contents:

- `LiveAudioCapture`
- `WhisperCLITranscriber`
- `FileTranscriptStore`
- `UserDefaultsSettings`
- `SystemRecordingPermissions`
- `ObsidianVaultFinder`
- `NetworkedModelSetup`
- `DiarizationProcessRunner` and other helper-process execution
- `InstallLayout`
- CLI installation filesystem and authorization adapters
- macOS hotkey, workspace, and lifecycle adapters where appropriate

### `HoverApp`

Contains the application composition root, SwiftUI/AppKit presentation, feature models, `StatusItemController`, GUI shell, and CLI shell. It depends on `HoverCore` and `HoverPlatform`.

The intended dependency direction is:

```text
HoverApp ───────────────> HoverCore
   │                         ▲
   └──────> HoverPlatform ───┘
```

More precisely:

- The application shell constructs concrete platform implementations.
- Feature models depend on protocols and domain values from `HoverCore`.
- Platform implementations conform to protocols defined in `HoverCore`.
- `StatusItemController` owns `NSStatusItem` and renders a typed snapshot of application state.
- `HoverCore` never imports the application or platform modules.

Avoid extracting a module solely because a folder contains several files. A module should have a meaningful responsibility and dependency boundary.

## 6. Naming findings

### Preserve the domain glossary

The terminology in `CONTEXT.md` should remain authoritative. Avoid replacing specific domain names with generic architecture vocabulary.

Examples of good existing names:

- `Transcriber`
- `AudioCapture`
- `TranscriptStore`
- `Chunker`
- `Selection`
- `OutputDestination`
- `VaultFinder`
- `ModelSetup`

### Recommended changes

- Rename `TranscriberApp` to `HoverApp` because it represents the product, not the transcription component.
- Rename the Swift package from `TranscriberKit` once its final responsibility is known; `HoverCore` is a likely name.
- Decompose `TranscriberEngine` before renaming it. The small UI-facing remainder could truthfully be called `AppModel`.
- Rename `authError`. It currently represents permission, model setup, recording startup, and diarization failures. Prefer a typed `PresentedError`, `AppAlert`, or feature-specific error state.
- Replace `Models.swift` with files or feature folders that identify the declarations they own.
- Replace generic `Config` with a domain name such as `RecordingConfiguration` if it remains a standalone concept.
- Review `transcriptsDir`, which appears to be a compatibility alias for `defaultOutputDirectory`, and remove it if unused.

### API syntax rules

Follow the Swift API Design Guidelines:

- Optimize names for clarity at use sites.
- Prefer domain nouns over implementation nouns.
- Avoid needless words that simply repeat type information.
- Use argument labels to make calls read naturally.
- Name mutating operations as verbs.
- Name nonmutating values and properties as nouns.
- Document behavior and important invariants, not obvious syntax.
- Avoid abbreviations unless they are established domain terms.

Protocol names do not need a uniform suffix. A protocol describing a thing can use a noun such as `Transcriber` or `TranscriptStore`; a protocol describing a capability may use an `-able`, `-ible`, or `-ing` form.

## 7. Error handling is frequently silent

Filesystem and persistence operations frequently use `try?` or return `nil`/`false` for all failure reasons. This keeps call sites compact but loses information and can cause observable state to disagree with disk state.

Examples include:

- Creating output directories
- Writing transcripts
- Renaming or moving transcripts
- Deleting transcripts
- Reading settings and Obsidian configuration
- Temporary-file cleanup
- Model setup operations

### Recommendation

- Let mutations that can materially fail use `throws`.
- Define small domain errors where the caller can recover or inform the user.
- Use `Result` only where storing or passing a completion value is beneficial; prefer `throws` for direct operations.
- Reserve `try?` for genuinely optional enrichment or best-effort cleanup.
- Update observable application state only after a filesystem mutation succeeds.
- Log ignored cleanup failures at an appropriate debug level when useful.

## 8. Logging should be structured

The application currently routes many messages through `NSLog("[Hover] ...")`.

### Recommendation

Use Apple's `Logger` API with a stable subsystem and focused categories:

```swift
enum HoverLog {
    static let recording = Logger(subsystem: "com.hover.desktop", category: "recording")
    static let transcription = Logger(subsystem: "com.hover.desktop", category: "transcription")
    static let diarization = Logger(subsystem: "com.hover.desktop", category: "diarization")
    static let modelSetup = Logger(subsystem: "com.hover.desktop", category: "model-setup")
    static let storage = Logger(subsystem: "com.hover.desktop", category: "storage")
}
```

Benefits include:

- Filtering by subsystem and category
- Appropriate debug, info, notice, error, and fault levels
- Privacy-aware interpolation
- Better Console and Instruments integration
- Signposts for long-running transcription and diarization work

The logging abstraction does not need to be injected everywhere. Inject it only where tests must inspect logging behavior; otherwise use category-specific static loggers.

## 9. Formatting needs a committed policy

The Swift 6 toolchain includes `swift format`, but the repository does not currently include a `.swift-format` configuration.

Running the formatter's default strict lint produces thousands of findings, primarily because the existing code consistently uses four-space indentation while the tool defaults to two spaces. This should not be interpreted as thousands of independent code-quality defects.

### Recommendation

1. Decide and document the project's formatting conventions.
2. Generate and commit a `.swift-format` configuration, retaining four-space indentation if that is the preferred established style.
3. Apply formatting as one isolated mechanical change so architectural diffs remain reviewable.
4. Add `swift format lint --strict --recursive Sources Tests` to continuous integration.
5. Avoid mixing a repository-wide format change with behavior changes.

Formatting and linting should remove subjective review noise, not dictate architecture.

## 10. Testing recommendations

The current suite is a significant strength and should remain green throughout the refactor.

### Keep

- Swift Testing
- Descriptive test names
- Pure-rule tests
- Fake dependency implementations
- Temporary filesystem isolation
- Tests for platform adapter contracts

### Improve

- Convert the bespoke executable test runner to a standard SwiftPM or Xcode test target once the canonical build supports it.
- Group tests according to the same features and targets as production code.
- Add focused tests for the recording state machine.
- Add concurrency tests for cancellation, overlapping start/stop requests, and late capture callbacks.
- Add integration tests for recording finalization without invoking real audio devices or helper processes.
- Add a small number of macOS UI tests for critical platform interactions after the Xcode app target becomes canonical.
- Ensure parallel tests never share a fixed directory, `UserDefaults` suite, port, or mutable global.

Module boundaries should enforce most architecture rules at compile time. Avoid adding fragile tests that parse source code merely to enforce folder conventions.

## Proposed implementation sequence

The order matters. Cosmetic restructuring should not precede correctness and build ownership.

### Phase 1: Establish one build source of truth

- Introduce the canonical Xcode app target or otherwise unify application compilation.
- Set one deployment target.
- Set one product bundle identifier per configuration.
- Centralize `Info.plist`, resources, entitlements, and versioning.
- Retain release scripts only as orchestration around the canonical build.
- Establish standard test targets.

### Phase 2: Make concurrency explicit

- Mark UI-facing observable state `@MainActor`.
- Enable complete concurrency checking in Swift 5 language mode.
- Resolve warnings without unsafe `@unchecked Sendable` shortcuts unless an invariant is proven and documented.
- Replace cross-queue mutable state with actors or structured async workflows.
- Make recording finalization an async operation.

### Phase 3: Introduce explicit lifecycle state

- Add an explicit application-readiness state for permissions and model availability.
- Add `RecordingPhase`.
- Introduce `RecordingSession` as the owner of capture, transcription, cancellation, processing, and finalization.
- Derive presentation properties from the phase.
- Prevent overlapping start, stop, and processing operations through the type's API.
- Add transition and cancellation tests.

### Phase 4: Decompose `TranscriberEngine`

- Extract speaker-diarization invocation, output parsing, and pure speaker attribution.
- Extract model setup coordination.
- Extract transcript-library state and operations.
- Extract `StatusItemController` and keep `NSStatusItem` out of recording services.
- Reduce the application model to composition and cross-feature coordination.
- Keep every extraction behavior-preserving and test-backed.

### Phase 5: Organize by feature and promote stable modules

- Move files into feature, domain, platform, app, and shared-UI folders.
- Split generic multi-purpose files.
- Create `HoverCore` and `HoverPlatform` only after dependencies reflect the intended direction.
- Keep module APIs internal wherever possible.

### Phase 6: Standardize maintainability tooling

- Add `.swift-format`.
- Adopt structured `Logger` categories.
- Reduce silent error handling.
- Add CI checks for the production scheme, tests, formatting, resource/release invariants, and complete concurrency warnings.
- Enable Swift 6 language mode target by target.

## Decisions to avoid for now

- Do not introduce TCA solely to solve the size of `TranscriberEngine`.
- Do not add a protocol for every type.
- Do not create one Swift module per screen.
- Do not introduce generic `Manager`, `Helper`, `Util`, or `Repository` layers.
- Do not move side effects into SwiftUI views.
- Do not use `@unchecked Sendable` as a blanket migration mechanism.
- Do not run a repository-wide formatter in the same change as architecture work.
- Do not preserve multiple independent application build definitions.
- Do not reorganize files without first identifying dependency ownership.

## Definition of a successful architecture

The refactor is successful when:

- There is one authoritative application build definition.
- The deployment target and bundle metadata cannot drift between test, development, and release builds.
- The project builds without complete-concurrency warnings.
- Swift 6 language mode can be enabled incrementally.
- SwiftUI observes small, main-actor-isolated feature models.
- Recording lifecycle is represented by an explicit state machine.
- GUI and CLI invoke the same application workflows without polling internal state.
- Pure domain rules compile without SwiftUI or AppKit.
- Platform adapters point inward to domain protocols.
- File and target structure communicate feature ownership.
- Names continue to follow Hover's domain glossary.
- Filesystem failures are surfaced instead of silently discarded where user data is involved.
- Formatting, tests, and concurrency checking are automated.
- The full existing behavior remains protected by the test suite.
