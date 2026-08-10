# Refactor Plan 3: Recording Lifecycle and `RecordingSession`

## Objective

Represent recording and application readiness with explicit finite state, make invalid combinations unrepresentable, and give one session ownership of capture through final persistence.

This plan depends on the isolation design in Refactor Plan 2 and precedes final `TranscriberEngine` decomposition.

## Current invalid-state surface

`Sources/TranscriberEngine.swift` spreads lifecycle across:

- `isRecording`
- `recordingTitle`
- `committedChunks`
- `lastRecordingTranscript`
- `statusMessage`
- `authError`
- `permissionRequest`
- derived `isProcessing`
- non-observed `sessionSegments`, `currentLogPath`, `chunksTranscribed`, queues, and a completion callback

This permits or causes several problematic states:

- a second start can arrive while asynchronous capture startup is suspended;
- a capture-start failure can clear the previous transcript before recording begins;
- stop is accepted while idle;
- the non-diarization path can finish before the final chunk is transcribed;
- a new recording can begin while the previous speaker pass is running;
- late capture callbacks have no session identity and can mutate a later recording;
- output destination and speaker-tagging settings can change mid-session;
- permission requests and generic errors can coexist;
- the current log path can remain live after finalization; and
- the CLI infers completion through a callback, polling, and fallback directory scanning.

## Proposed domain values

```swift
struct RecordingRequest: Sendable, Equatable {
    let inputSource: InputSource
    let tagsSpeakers: Bool
    let outputDirectory: URL
}

struct RecordingSessionState: Sendable, Equatable {
    let id: UUID
    let title: String
    let requestedInputSource: InputSource
    let activeInputSource: InputSource
    let tagsSpeakers: Bool
    let outputURL: URL
    var committedText: String
    var chunkCount: Int
    var warnings: [RecordingWarning]
}

enum RecordingProcessingStage: Sendable, Equatable {
    case flushingFinalChunk
    case transcribing
    case taggingSpeakers
    case saving
}

enum RecordingPhase: Sendable, Equatable {
    case idle
    case checkingReadiness(RecordingRequest)
    case requestingPermission(PendingRecordingPermission)
    case starting(RecordingSessionState)
    case recording(RecordingSessionState)
    case stopping(RecordingSessionState)
    case processing(RecordingSessionState, RecordingProcessingStage)
    case completed(RecordingResult)
    case cancelling(RecordingSessionState)
    case failed(RecordingFailure)
}
```

`RecordingResult` should distinguish a saved transcript from a successful no-speech result. Use `RecordingWarning` for recoverable degradation, such as unavailable system audio or skipped speaker labels. Use `RecordingFailure` when the requested workflow cannot complete.

Configuration is immutable for the lifetime of a session. UI changes affect only the next `RecordingRequest`.

## Application readiness

Add a separate readiness source of truth:

```swift
enum ApplicationReadiness: Sendable, Equatable {
    case checking
    case settingUpModels(ModelSetupStatus)
    case ready(RecordingCapabilities)
    case unavailable(ReadinessFailure)
}
```

Model/transcriber availability is a global prerequisite. Recording permissions remain request-specific because Hover supports microphone/system fallback depending on the requested input.

Extract the permission decision table from `permittedInputSource(for:)` into a pure rule. Preserve current behavior:

- prompt directly for an unrequested microphone;
- explain Screen Recording before invoking its system flow;
- do not stack permission prompts;
- allow a one-session fallback without changing the persisted preference; and
- preserve restart-required handling for Screen Recording permission.

The readiness snapshot must be revalidated immediately before constructing capture resources.

## `RecordingSession` ownership

Create one `RecordingSession` actor per attempted recording. It owns:

- the immutable request and stable session identity;
- the session output path;
- a session-scoped audio capture instance;
- ordered capture event consumption;
- transcription and timestamped text segments;
- draft persistence;
- optional speaker tagging;
- stop, cancellation, cleanup, and final result.

Prefer a capture factory over one reused global capture object. Session-scoped capture prevents stale callbacks and retained framework state from leaking into later recordings.

Suggested API:

```swift
actor RecordingSession {
    let events: AsyncStream<RecordingSessionEvent>

    func start(using source: InputSource) async throws
    func stop() async throws -> RecordingResult
    func cancel() async
}
```

`AudioCapture.stop()` must not return until the final chunk has been delivered and its event stream is closed. `RecordingSession.stop()` then:

1. Stops capture.
2. Awaits consumption and transcription of every chunk.
3. Runs optional speaker tagging.
4. Persists the definitive transcript.
5. Returns the exact result.

Transcript persistence should throw and return the saved transcript directly. Do not reload the directory and infer success from the newest or path-matching file.

## UI-facing recording model

```swift
@MainActor
@Observable
final class RecordingModel {
    private(set) var phase: RecordingPhase = .idle

    func start(_ request: RecordingRequest) async -> RecordingStartOutcome
    func respondToPermission(_ response: RecordingPermissionResponse) async
    func stop() async throws -> RecordingResult
    func cancel() async
    func dismissResult()
}
```

Views observe derived projections and send commands. They never assign lifecycle properties directly.

## Transition policy

Legal transitions:

```text
idle/completed/failed
  -> checkingReadiness
  -> requestingPermission | starting | failed | idle
  -> recording | stopping | cancelling | failed
  -> stopping
  -> processing
  -> completed | failed
```

Command rules:

- A second start during starting, recording, stopping, or processing returns `.busy` without mutating state.
- Multiple stop callers await the same finalization task; capture stops once.
- A stop arriving during startup becomes a pending stop and executes after successful startup.
- Permission responses carry a request/session ID so stale UI actions cannot start another request.
- Cancellation discards the session and removes its draft on a best-effort basis.
- “Finish without speaker tags” must be a distinct action if introduced; it is not equivalent to cancellation.
- Output destination, input source, and speaker tagging controls are disabled for all busy phases.
- The previous completed result remains visible until a new recording actually reaches `.starting`.

## GUI migration

Update these surfaces to derive behavior from `RecordingPhase`:

- `Sources/ToolbarButtons.swift`: button state, input availability, stop/start commands, copying.
- `Sources/ContentView.swift`: readiness routing and permission presentation.
- `Sources/SidebarView.swift`: in-progress row.
- `Sources/DetailViews.swift`: live text, status, shimmer, and recording indicator.
- `Sources/PermissionRequestSheet.swift`: typed responses carrying request identity.
- `Sources/OutputOptionsButton.swift`: configuration availability.
- `Sources/TranscriberApp.swift`: hot keys await the same workflow; restart must await finalization.
- `Sources/MenuBarMoth.swift`: consume a typed activity snapshot rather than observing mutable engine flags.

Do not clear the previous transcript merely because a readiness or permission check begins.

## Agent Mode migration

Refactor `Sources/HoverCLI.swift` to use the same workflow:

- `start(request)` returns a typed recording, permission, busy, or failure outcome.
- Agent Mode applies its fallback policy to the typed permission decision.
- `try await recording.stop()` replaces `onRecordingFinished`, polling flags, sleeps, and newest-file scanning.
- Timeout races finalization against an injected clock and cancels explicitly.
- stdout and JSON are produced from `RecordingResult`.
- degraded success warnings go to stderr without being represented as generic application errors.
- a stop signal during startup becomes a pending stop for the same session.

## Implementation increments

1. Add characterization tests for the permission matrix, previous-result preservation, final-chunk ordering, overlapping commands, configuration mutation, and late callbacks.
2. Add recording request/phase/result/failure/warning/readiness value types and a pure permission-decision rule.
3. Add application readiness behind compatibility projections for existing model-setup state.
4. Introduce `RecordingSession` behind `TranscriberEngine`; expose legacy properties as read-only projections temporarily.
5. Convert Audio Capture to session-scoped async events with a firm stop contract.
6. Move transcription, draft persistence, speaker tagging, and finalization into the session.
7. Make Transcript Store finalization throwing and return the exact `SavedTranscript`.
8. Migrate Agent Mode and remove callback/polling completion.
9. Migrate GUI controls, sheets, hot keys, and status projection.
10. Add cancellation and application-termination cleanup.
11. Delete the legacy lifecycle properties, queues, path, and completion callback.

Keep files in the existing source layout while these behavioral changes land. Physical module moves belong to Refactor Plan 5.

## Verification

Add focused suites for:

- every legal and rejected `RecordingPhase` transition;
- the full permission/fallback matrix;
- global readiness and Agent Mode fail-fast behavior;
- final chunk inclusion;
- immutable request configuration;
- no-speech completion;
- definitive persistence failures;
- speaker-tagging success, failure, and cancellation;
- duplicate start/stop and stop-during-startup;
- stale permission responses and late capture events;
- inability to start while processing;
- CLI duration and signal handling without polling; and
- derived UI availability and status-item activity.

Use controllable fakes, continuations, and injected clocks instead of timing sleeps.

## Risks

- `LiveAudioCapture.stop()` currently crosses Timer, queue, and ScreenCaptureKit behavior; its new stop guarantee requires deadlock and late-callback tests.
- Blocking process calls must become async before session cancellation is reliable.
- Preventing a new recording during speaker processing changes current button/hot-key behavior but avoids shared-state corruption.
- Minute-resolution recording filenames can collide; session output identity must become collision-safe.
- Cancellation must not silently overwrite or discard a valid unlabeled transcript.
- Treating denied permission as global application failure would incorrectly remove valid reduced-input modes.

## Completion criteria

- One typed phase is the source of truth for recording presentation and availability.
- Invalid overlapping lifecycle operations are rejected by the workflow API.
- One session owns capture through definitive transcript persistence.
- Stop is async and returns the exact final result.
- GUI and Agent Mode invoke the same workflow without polling internal state.
- Late events and stale permission responses cannot affect another recording.
