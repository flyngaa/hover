# Refactor Plan 1: Canonical Build Graph

**Status: Complete — 2026-08-10**

Implemented with the checked-in `Hover.xcodeproj` and shared `Hover` scheme. The
application and standard Swift Testing target now share one source graph;
development, release, and CI automation invoke that graph; build settings,
versions, metadata, entitlements, and required resources have canonical owners.
The legacy test-only package and bespoke test runner were removed.

## Objective

Make one Xcode-owned product graph authoritative for Hover's application, tests, resources, metadata, and release inputs. Development and release automation should invoke that graph rather than compile the application independently.

This plan implements Phase 1 of `codebase_architecuter.md` and must land before concurrency migration, module promotion, or broad source reorganization.

## Current evidence

Hover currently has several overlapping build definitions:

- `Package.swift` explicitly describes a test-only SwiftPM graph, names the module `TranscriberKit`, targets macOS 14, excludes the app entry files, and keeps Swift 5 language mode.
- `build.sh` independently gathers `Sources/*.swift`, invokes `swiftc`, links Apple frameworks, writes bundle metadata, and copies resources.
- `Scripts/build-release-app.sh` repeats application compilation and bundle assembly for release.
- `.github/workflows/release.yml` runs only for version tags and verifies the test-only package graph before invoking the separate release build.

The definitions have already drifted:

| Concern | Test package | Development build | Release build |
| --- | --- | --- | --- |
| Deployment target | macOS 14 | plist declares macOS 13 | plist declares macOS 13 |
| Bundle identifier | none | `com.local.hover` | `com.hover.desktop` |
| Version ownership | none | hard-coded | supplied by release script |
| Entitlements | none | separate/manual behavior | release script behavior |
| Resources | excluded from product testing | copied by shell | copied by another shell path |

Other constraints:

- `Sources/Main.swift` intentionally switches between GUI and Agent Mode inside the same executable.
- `Sources/InstallLayout.swift`, `Sources/InstallCLI.swift`, `Scripts/hover`, and several resource lookups depend on `Bundle.main` representing `Hover.app`.
- There is no checked-in Xcode project, shared scheme, `.xcconfig`, committed app plist, or normal pull-request CI workflow.
- `Tests/TestRunner.swift` invokes Swift Testing through a bespoke executable entry point.

## Target product graph

```text
Hover.app / HoverApp
  ├── HoverCore
  └── HoverPlatform
        └── HoverCore
```

Phase 1 should initially create one monolithic `HoverApp` target using the existing sources. `HoverCore` and `HoverPlatform` should be promoted only after dependency direction has been corrected by later phases.

Agent Mode remains part of `Hover.app`; do not create a separate CLI executable. The installed `hover` wrapper should continue launching `Contents/MacOS/Hover` so bundle resources and helpers resolve consistently.

## Canonical ownership

| Concern | Owner |
| --- | --- |
| Application source membership | `HoverApp` Xcode target |
| Deployment target | checked-in base configuration |
| Bundle identifier | checked-in build configuration |
| Marketing/build versions | Xcode build settings, overridden by tag CI when needed |
| `Info.plist` keys | committed plist plus build-setting substitution |
| Entitlements | `Hover.entitlements` referenced by the target |
| Normal resources | Copy Bundle Resources phase |
| Test discovery/execution | standard Xcode/Swift Testing targets |
| Helper acquisition | `Scripts/build-release-helpers.sh` |
| Helper staging and packaging | release orchestration |
| DMG, notarization, publication | `release.sh` and release CI |

Initial decisions:

- Use macOS 14 consistently because the application already depends on Observation APIs requiring it.
- Retain `com.hover.desktop` unless a deliberate debug suffix is introduced in checked-in configuration. Changing the production identity would reset TCC permissions and `UserDefaults` identity.
- Keep Swift 5 language mode during this phase. Strict concurrency belongs to Phase 2.
- Do not have automated scripts discover signing identities or credentials. Signing inputs must be supplied by CI or a human-controlled environment.

## Implementation increments

### 1. Add the authoritative Xcode application

Create:

```text
Hover.xcodeproj/
Config/
  Base.xcconfig
  Debug.xcconfig
  Release.xcconfig
  Version.xcconfig
  Hover-Info.plist
```

Add a shared `Hover` scheme and one `HoverApp` application target. Initially include every current source file, preserving `Sources/Main.swift` as the single entry point.

Add required target resources explicitly:

- `AppIcon.icns`
- `Logo.png`
- `Moth.svg`
- `Obsidian.svg`
- `Scripts/diarize.py`
- `Scripts/hover`
- `ThirdPartyLicenses.txt`

Missing required resources should fail validation. Preserve the executable permission of `Scripts/hover` in the product.

### 2. Establish standard tests

- Add a standard Swift Testing target against the production graph.
- Temporarily change `@testable import TranscriberKit` to the initial app/module name.
- Remove the dependency on `Tests/TestRunner.swift` after parity is proven.
- Replace `test.sh` with a thin `xcodebuild test` wrapper using the shared scheme and a deterministic Derived Data directory.
- Keep all existing 141 tests green.

Do not combine this change with Swift 6 fixes, formatting, or architecture extraction.

### 3. Switch development builds

Rewrite `build.sh` as a thin Xcode build wrapper. It should no longer:

- invoke `swiftc` directly;
- write an app plist;
- maintain a framework list;
- copy ordinary resources;
- construct another bundle layout; or
- search for signing credentials.

It should build the shared scheme and report the generated app location.

### 4. Switch release compilation

Refactor `Scripts/build-release-app.sh` to build/archive the canonical Release scheme and pass tag-derived version settings.

Remove duplicated source compilation, plist generation, normal resource copying, and product metadata.

Retain release-only responsibilities:

- validate and stage pinned helper artifacts;
- place helpers under `Contents/Helpers`;
- place ONNX Runtime under `Contents/Frameworks`;
- validate load paths and runtime layout;
- perform the required inside-out release signing sequence in the human/CI release environment; and
- validate the final application before DMG creation.

The application must not be modified after its outer signature is produced.

### 5. Add normal CI

Create a pull-request/push workflow that runs:

1. Standard tests.
2. An unsigned Release build of the shared scheme.
3. Bundle metadata and resource validation.
4. Lightweight Agent Mode smoke tests.

Update the tag workflow to reuse the same verification for the exact tagged commit before signing, notarization, or publication.

### 6. Remove duplicate definitions

After Debug, tests, unsigned Release, and release bundle validation all pass:

- remove or replace the test-only `TranscriberKit` graph;
- delete `Tests/TestRunner.swift`;
- remove direct application `swiftc` compilation;
- remove plist heredocs and duplicate resource-copy lists;
- update `RELEASE.md` and build documentation; and
- remove stale Command Line Tools-only comments.

### 7. Prepare later module promotion

Before creating `HoverCore` and `HoverPlatform`:

- replace `TranscriberEngine.Config` with an independent `RecordingConfiguration`;
- make model artifact metadata independent from `InstallLayout`;
- split protocols from concrete implementations;
- remove app calls to `FileTranscriptStore` implementation statics; and
- move concrete dependency construction into `AppDependencies`.

Module promotion is owned by Refactor Plan 5.

## Verification gates

Each increment must verify:

- all 141 existing tests pass;
- Debug and unsigned Release build from the shared scheme;
- processed metadata contains the expected bundle ID, macOS 14 target, usage descriptions, and version values;
- all required resources exist in the built bundle;
- the installed wrapper remains executable and preserves `Bundle.main` behavior;
- Agent Mode retains its stdout/stderr contract;
- helpers and dynamic libraries occupy their expected release locations;
- model data and helper archives are not accidentally bundled; and
- GUI resources, menu-bar artwork, model setup, and transcript creation work in a smoke test.

Credential-dependent signature, notarization, and Gatekeeper checks must be performed by authorized CI or a human. Agents must not invoke Keychain or signing-credential discovery commands.

## Main risks

- Changing the bundle identifier resets permissions and settings.
- Xcode resource copying may lose the wrapper executable bit.
- Staging helpers after signing invalidates the application signature.
- A separate CLI target breaks bundle-relative resource and helper discovery.
- Premature module extraction creates access-control churn and circular dependencies.
- Mixing this migration with concurrency, formatting, or feature decomposition makes parity failures difficult to isolate.

## Completion criteria

- One checked-in Xcode graph builds the shipping application.
- Tests exercise the same production source graph.
- Development and release scripts orchestrate Xcode rather than compile Hover independently.
- Deployment target, metadata, resources, and version ownership cannot drift between development and release.
- Normal CI builds the production scheme without credentials.
