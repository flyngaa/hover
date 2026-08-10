# Refactor Plan 6: Errors, Logging, Formatting, Tests, and CI

## Objective

Make operational failures explicit, protect user data, adopt privacy-aware structured logging, commit a formatting policy, organize tests around architecture boundaries, and automate production-grade verification.

Some error-contract work should land early so silent semantics are not carried into new feature models. Formatting and final CI/module organization should wait until active architectural moves settle.

## Current evidence

- There is no committed `.swift-format` policy.
- The formatter's defaults disagree with Hover's established four-space indentation, producing thousands of mechanical findings.
- The suite contains 141 tests in 19 Swift Testing suites but runs through a bespoke executable target and `Tests/TestRunner.swift`.
- The only GitHub workflow runs for release tags; pull requests and normal pushes have no test, format, strict-concurrency, or production-build gate.
- Passing package tests do not prove the excluded application entry files compile.
- Development and release builds treat several expected resources as optional.
- Logging primarily uses string closures and `NSLog("[Hover] ...")`.
- Whisper logging currently includes a prefix of transcription output, which can expose private transcript content.
- Important filesystem and persistence operations frequently use `try?`, `nil`, `false`, or placeholder content for unrelated failures.

Agent Mode stdout and stderr are an external process contract. They must remain explicit terminal output and must not be replaced with unified logging.

## Error-handling policy

### Operations that must throw or return typed failure

#### Transcript storage

Make user-data operations explicit:

```swift
protocol TranscriptStore {
    func load(in directory: URL) throws -> TranscriptLibrary
    func write(title: String, body: String, to url: URL) throws -> SavedTranscript
    func content(of transcript: SavedTranscript) throws -> String
    func rename(_ transcript: SavedTranscript, to name: String) throws -> SavedTranscript
    func move(_ transcript: SavedTranscript, toGroup group: String?, in directory: URL) throws -> SavedTranscript
    func delete(_ transcript: SavedTranscript) throws
    func relocate(/* ... */) -> TranscriptRelocationReport
}
```

Current failure modes to eliminate:

- unreadable directories appearing as empty libraries;
- read failure becoming empty transcript content;
- delete failure while the UI removes the row;
- write failure while GUI/Agent Mode reports success;
- collisions and permission errors both becoming `nil`; and
- relocation reporting only a count and hiding per-file failures.

`TranscriptRelocationReport` should preserve each success, no-op, and failure because batch moves can complete partially.

#### Output destination

Create and validate a proposed directory before persisting it or publishing it to observable state. A failed creation must leave the old destination selected.

#### Recording pipeline

Represent chunk transcription loss, capture failure, skipped speaker labels, WAV/process failures, and persistence failure through `RecordingFailure` and `RecordingWarning`.

A degraded transcript may still be saved, but the result must disclose the degradation.

#### Model setup

Distinguish not-found from unreadable. Validate staged downloads before atomically replacing the last valid artifact. Do not ignore destination-removal/replacement failures.

#### CLI installation and startup layout

Only a genuine not-found error means “not installed.” Unreadable entries and symlinks must surface as errors. Resolve `InstallLayout` in the composition root and present a recoverable reinstall message rather than crashing.

#### Agent Mode output

Return the exact saved transcript from recording finalization. Remove newest-file fallback scanning. JSON encoding failure must write to stderr and exit nonzero.

### Acceptable best-effort operations

`try?` is acceptable only for intentionally optional or cleanup behavior, preferably with an explanatory comment and debug log:

- temporary file/directory cleanup;
- cancellation-aware debounce or animation sleeps;
- optional creation-date metadata fallback;
- absent optional Obsidian configuration;
- optional artwork with a documented fallback; and
- deferred cleanup during cancellation/termination.

Malformed or permission-denied optional configuration should be logged rather than being indistinguishable from “not installed.”

## Domain error types

Prefer small feature errors:

- `TranscriptStoreError`
- `RecordingFailure`
- `RecordingWarning`
- `SpeakerDiarizationError`
- `ModelSetupError`
- `CLIInstallationError`
- `AppStartupError`

Preserve the underlying error for private diagnostics while exposing concise user-facing wording. Replace generic `authError` with typed feature presentation.

## Structured logging

Add a central category definition using `Logger`:

```swift
import OSLog

enum HoverLog {
    static let recording = Logger(subsystem: "com.hover.desktop", category: "recording")
    static let audioCapture = Logger(subsystem: "com.hover.desktop", category: "audio-capture")
    static let transcription = Logger(subsystem: "com.hover.desktop", category: "transcription")
    static let diarization = Logger(subsystem: "com.hover.desktop", category: "diarization")
    static let modelSetup = Logger(subsystem: "com.hover.desktop", category: "model-setup")
    static let storage = Logger(subsystem: "com.hover.desktop", category: "storage")
    static let permissions = Logger(subsystem: "com.hover.desktop", category: "permissions")
    static let cliInstallation = Logger(subsystem: "com.hover.desktop", category: "cli-installation")
}
```

### Level policy

- `debug`: optional discovery, cleanup failure, detailed timing.
- `info`: successful workflow boundaries.
- `notice`: deliberate fallback or degraded success.
- `warning`: partial result or retryable failure.
- `error`: requested operation failed and was surfaced.
- `fault`: broken invariant or impossible transition.

### Privacy policy

- Never log transcript text. Remove the Whisper output prefix log.
- Treat paths, transcript names, vault names, output destinations, process stderr, and localized descriptions as private.
- Cap raw process diagnostics.
- Session IDs, counts, durations, exit codes, artifact identifiers, and public helper names may be public.

### Signposts

Use `OSSignposter` for:

- a recording session;
- each Whisper chunk;
- a speaker-diarization pass;
- model artifact download/verification; and
- optionally transcript relocation batches.

Record timing, counts, outcomes, and public error codes. Do not signpost audio buffers or high-frequency status ticks.

Logging does not need dependency injection everywhere. Inject a sink only where tests need to inspect a privacy or diagnostic behavior.

## Formatting rollout

1. Commit a project style policy and `.swift-format` generated for the pinned toolchain.
2. Preserve four-space indentation and choose an explicit line length.
3. Pin/print the Swift and formatter versions in CI.
4. Apply formatting in one isolated mechanical commit after source moves stabilize.
5. Review the formatter diff, then enable strict recursive linting.
6. Never mutate tracked sources during a normal Xcode build.
7. Extend formatting to Swift scripts separately if desired; exclude generated/vendor code explicitly.

Do not combine the formatting baseline with behavior changes, module extraction, or file moves.

## Test organization

Preserve the 141-test baseline before changing contracts.

After the canonical build exists:

- replace the executable test runner with standard Xcode/SwiftPM test targets;
- initially organize tests by product responsibility;
- later split into `HoverCoreTests`, `HoverPlatformTests`, and `HoverAppTests`;
- split `Tests/Fakes.swift` into dependency-specific support;
- replace mutable unchecked test recorders with actors or synchronized values; and
- ensure each test uses an isolated temporary directory and settings suite.

Add failure-path coverage for:

- unreadable or missing output directories;
- failed write not publishing saved state;
- collision versus permission failure;
- failed delete keeping the transcript visible;
- partial relocation reporting exact unmoved files;
- malformed or unreadable vault configuration;
- atomic model replacement preserving the previous valid artifact;
- malformed diarizer output producing a warning; and
- Agent Mode JSON and error contracts.

Test domain outcomes rather than unified-log wording. Use a narrow injected logger only for privacy-critical regressions.

## CI and release gates

Add a normal pull-request/push workflow with this order:

1. Select and print the pinned Xcode/Swift/formatter versions.
2. Run strict formatting lint.
3. Run complete-concurrency checking in Swift 5 mode with warnings as errors.
4. Run standard unit tests.
5. Build the canonical Release scheme with signing disabled.
6. Validate app metadata, resources, and bundle invariants.
7. Run lightweight Agent Mode integration smoke tests.
8. Upload build/test diagnostics on failure.

Bundle validation should cover:

- bundle identifier and deployment target;
- version values and privacy usage descriptions;
- expected resources and licenses;
- wrapper/helper executable bits;
- helper/dylib placement and load paths;
- expected entitlements;
- absence of bundled models and helper archives; and
- GUI and Agent Mode product layout.

The tag workflow should run the same reusable verification against the tagged commit before credential-dependent release work.

Additional safeguards:

- pin third-party GitHub Actions to immutable revisions;
- syntax-check shell scripts and use a pinned shell linter when practical;
- cache only deterministic artifacts keyed by toolchain and lockfiles;
- keep credential import/removal exclusively in the release job; and
- ensure normal CI never invokes signing, Keychain, or notarization commands.

## Swift 6 completion

- Gate complete checking in Swift 5 mode first.
- Reach zero warnings per target.
- Enable Swift 6 in dependency order: Core, Platform, feature models, app/Agent Mode, tests.
- Retain warnings-as-errors and production-scheme validation after migration.
- Permit only narrow, documented `@preconcurrency` imports.
- Do not accept blanket `@unchecked Sendable`.

## Implementation increments

1. Add domain error types and explicit Transcript Store contracts.
2. Update observable state only after successful user-data mutations; add failure tests.
3. Convert recording, diarization, setup, CLI installation, and startup layout to typed outcomes.
4. Add `HoverLog`, replace `NSLog`/string logging, enforce privacy, and add signposts.
5. Apply the isolated formatting baseline and activate lint.
6. Convert to standard test targets and organize tests along production boundaries.
7. Add PR/push CI gates.
8. Reuse verification in the release workflow.
9. Enable Swift 6 target by target after concurrency work is clean.

## Dependencies and risks

- Standard tests and production-scheme validation depend on Refactor Plan 1.
- Swift 6 activation depends on Refactor Plan 2.
- Storage error contracts should precede feature decomposition so silent behavior is not preserved in new APIs.
- Formatting during file moves creates severe merge conflicts.
- Overly verbose logging can leak metadata and make Console unusable.
- Transcript relocation is partially transactional; each source must be preserved until its individual move succeeds.
- Verification requiring secrets would prevent normal CI from exercising the production path.

## Completion criteria

- Material user-data failures are typed and surfaced.
- Observable state changes only after successful persistence.
- Unified logging is categorized and privacy-safe.
- Formatting policy is committed and CI-enforced without mutating builds.
- Tests are standard targets aligned with production boundaries.
- Pull requests build and test the production scheme.
- Release publication depends on the same verification.
- Swift 6 is enabled incrementally after zero complete-concurrency warnings.
