# Refactor Plan 2: Concurrency Ownership and Swift 6

## Objective

Replace implicit queue ownership and cross-thread mutable state with compiler-enforced isolation, structured async workflows, cancellation, and `Sendable` values. Reach zero complete-concurrency warnings before enabling Swift 6 target by target.

This plan follows the canonical build graph and supplies the isolation model required by the recording lifecycle and engine-decomposition plans.

## Current evidence

- `Sources/TranscriberEngine.swift` is mutable `@Observable` UI state without `@MainActor` isolation.
- The engine mixes `DispatchQueue.main.async`, `MainActor.run`, unstructured `Task` creation, transcription and diarization queues, mutable callbacks, and shared session state.
- Audio callbacks capture the engine and enqueue work that later captures it again on the main queue.
- `Sources/TranscriberEngine+Diarization.swift` nests transcription, diarization, and main-queue work while sharing engine state.
- `Sources/LiveAudioCapture.swift` relies on comments to describe ownership of buffers, counters, `Chunker`, and backpressure state.
- `Sources/AudioCapture.swift` exposes mutable callback properties with no isolation or sendability contract.
- `Sources/HoverCLI.swift` combines `onRecordingFinished` with 100/200 ms polling and a 300-second deadline.
- Whisper, diarization, and model archive operations use blocking process waits.
- `Sources/NetworkedModelSetup.swift` contains mutable URLSession delegate state and an `@unchecked Sendable` progress box.
- Complete concurrency checking exposes AppKit isolation issues in CLI startup, hot keys, window coordination, permission UI, controllers, views, and tests.

A correctness defect is coupled to this design: without speaker tagging, `stopRecording()` can report completion immediately after `AudioCapture.stop()` enqueues its final chunk, before that chunk has been transcribed and persisted.

## Target isolation model

### Main-actor presentation

All UI-facing observable state and AppKit ownership should be `@MainActor`:

- `AppModel`
- `RecordingModel`
- `TranscriptLibraryModel`
- `ModelSetupController`
- `StatusItemController`
- hot-key routing
- window coordination
- permission presentation

These types should not be made `Sendable` or `@unchecked Sendable`. Background work returns immutable values to them.

### Recording workflow actor

Create one `RecordingSession` actor per recording. It owns:

- session identity and immutable configuration;
- ordered audio event consumption;
- transcription and timestamped segments;
- stop and final-chunk draining;
- optional speaker diarization;
- transcript persistence and final result;
- cancellation and temporary resource cleanup.

Its stop API must return only after definitive finalization:

```swift
func stop() async throws -> RecordingResult
```

Do not store a shared `currentLogPath`, queue counters, or completion callback on a global application model.

### Ordered audio boundary

Move Apple callback mechanics to a narrow platform adapter. Convert `AVAudioPCMBuffer` and `CMSampleBuffer` contents into owned, `Sendable` values before crossing isolation.

Suggested contract:

```swift
enum AudioCaptureEvent: Sendable {
    case chunk(AudioChunk)
    case status(CaptureStatus)
}

protocol AudioCapture: Sendable {
    func start(configuration: AudioCaptureConfiguration) async throws
        -> AsyncStream<AudioCaptureEvent>
    func stop() async -> CaptureStopResult
}
```

`stop()` must guarantee the final chunk was yielded before the stream finishes. Preserve one ordered consumer; do not create an unstructured task for each real-time buffer.

### Async process boundary

Extract a reusable, cancellation-aware `ProcessRunner` for:

- `WhisperCLITranscriber`;
- speaker diarization;
- model archive extraction; and
- applicable CLI installation operations.

It should:

- return a `Sendable` process result;
- bridge termination through a checked continuation;
- drain stdout and stderr without pipe deadlock;
- terminate the child when its task is cancelled; and
- preserve exit status and bounded diagnostic output.

Make `Transcriber.transcribe` and `SpeakerDiarizer.diarize` async. Keep parsing and speaker attribution pure and synchronous.

### Async model setup

Replace the progress closure with an `AsyncThrowingStream<ModelSetupProgress>` or equivalent async sequence. A main-actor controller consumes progress without nested main-queue dispatches.

Keep synchronization at the URLSession delegate boundary narrow and explicit. Do not mark a mutable workflow object broadly `@unchecked Sendable`.

## Implementation increments

### 1. Establish the compiler gate

- Enable complete concurrency checking in Swift 5 mode for the canonical app, supporting modules, and tests.
- Treat new concurrency warnings as CI failures.
- Use clean builds when measuring diagnostics; incremental builds can hide warnings.
- Do not enable Swift 6 yet.

### 2. Make crossing values `Sendable`

Add `Sendable` where structurally valid to values such as:

- `InputSource`
- `AudioChunk`
- `CaptureStatus`
- `SavedTranscript`
- `TranscriptLibrary`
- `TextSegment`
- `SpeakerTurn`
- permission values and requests
- model status/progress values
- CLI result values
- installation/configuration values

Require background-facing protocols to be `Sendable` where their ownership supports it. Actor-isolate mutable fakes rather than applying blanket unchecked conformances.

### 3. Correct platform/UI isolation

- Isolate the app entry, AppKit delegate state, `HotKeys`, permission UI, status item, and window coordination to `MainActor`.
- Remove redundant `Task { @MainActor ... }`, `MainActor.run`, and `DispatchQueue.main.async` hops once ownership is correct.
- Make controller dependencies immutable and `Sendable`, or place their mutable workflows behind actors.

### 4. Introduce async process and diarization seams

- Add the process runner.
- Make transcription async.
- Extract `SpeakerDiarizer` and its async implementation.
- Keep parsing and speaker attribution outside the process runner.

This should precede `RecordingSession`; otherwise blocking process calls can monopolize the actor executor.

### 5. Replace audio callbacks

- Refactor `AudioCapture` and `LiveAudioCapture` to ordered async events.
- Put buffer state, counters, chunking, and backpressure under one compiler-enforced owner.
- Preserve deterministic final-flush ordering.
- Keep Apple media objects inside `HoverPlatform`.

### 6. Introduce `RecordingSession`

- Move segments, current path, chunk counts, transcription ordering, diarization ordering, and persistence out of `TranscriberEngine`.
- Replace transcription/diarization GCD queues with structured async workflow calls.
- Replace `onRecordingFinished` with the return value from `await stop()`.
- Introduce `RecordingPhase` and derive presentation state from it.

### 7. Introduce main-actor feature models

- Move observed state to focused models.
- Keep filesystem, process, download, and audio work off the main actor.
- Update SwiftUI environment injection, hot keys, permission sheets, sidebar work, and status-item observation.

### 8. Modernize CLI coordination

- Await the exact final recording result.
- Delete completion flags and polling loops.
- Represent signals as an async stream or continuation.
- Race requested duration, stop signals, finalization, and timeout using structured task groups.
- Propagate cancellation into capture and child processes.
- Preserve stdout/stderr and first/second signal semantics.

### 9. Enable Swift 6 target by target

After complete checking is clean:

1. `HoverCore`
2. `HoverPlatform`
3. feature models
4. app and Agent Mode shell
5. test targets

Use narrow `@preconcurrency` imports only for documented SDK annotation gaps. Do not use `@unchecked Sendable` on UI models or workflow actors.

## Likely affected files

- `Sources/TranscriberEngine.swift`
- `Sources/TranscriberEngine+Diarization.swift`
- `Sources/TranscriberEngine+Transcripts.swift`
- `Sources/AudioCapture.swift`
- `Sources/LiveAudioCapture.swift`
- `Sources/Transcriber.swift`
- `Sources/ModelSetup.swift`
- `Sources/NetworkedModelSetup.swift`
- `Sources/TranscriptStore.swift`
- `Sources/HoverCLI.swift`
- `Sources/Main.swift`
- `Sources/TranscriberApp.swift`
- `Sources/MenuBarMoth.swift`
- `Sources/HotKeys.swift`
- `Sources/HideWindowTitle.swift`
- relevant SwiftUI views, fakes, and tests

New files will likely include:

- `RecordingSession.swift`
- `RecordingPhase.swift`
- `SpeakerDiarizer.swift`
- `SpeakerAttribution.swift`
- `ProcessRunner.swift`

## Verification

Retain the existing suite and add tests proving:

- stopping waits for the final chunk with and without speaker tagging;
- duplicate stop callers complete exactly once;
- starts cannot overlap startup or processing;
- late events cannot mutate another session;
- rapid microphone/system events remain ordered;
- cancellation stops capture and child processes and cleans temporary files;
- model progress is monotonic and resumes exactly once;
- CLI duration and signal paths finish without polling;
- transcript search cancellation cannot publish stale results;
- Thread Sanitizer passes repeated start/stop and final-chunk stress tests; and
- complete-concurrency builds produce zero warnings before Swift 6 activation.

## Risks

- Copying audio buffers too often can harm real-time performance.
- Actor reentrancy can reorder the workflow unless one session pipeline owns finalization.
- Cancellation can leave child processes or temporary files without centralized lifecycle handling.
- Old-session results can corrupt new UI state without serialization or session IDs.
- Full-recording `[Float]` retention is large; a later improvement should stream diarization audio to a temporary WAV.
- `@unchecked Sendable` can conceal races instead of resolving them.

## Completion criteria

- UI state and AppKit ownership are main-actor isolated.
- Mutable recording work has a single actor owner.
- Audio and process boundaries are ordered, async, and cancellable.
- CLI and GUI await the same final recording result.
- Complete concurrency checking is warning-free.
- Swift 6 is enabled incrementally without blanket unsafe conformances.
