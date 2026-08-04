# Hover Transcriber

A macOS app that captures audio (system and/or microphone) and turns it into saved text transcripts, with optional speaker tagging. Transcripts are saved to one folder of the user's choosing — which may be inside an Obsidian vault — and never duplicated elsewhere.

## Language

**Transcriber**:
The thing that turns captured audio samples into text. A seam in the app: production uses the whisper.cpp CLI, tests can supply a fake.
_Avoid_: recognizer, speech engine, whisper (whisper is one implementation, not the concept).

**Chunk**:
A short slice of captured audio flushed to the Transcriber as one unit, sliced on a pause or a hard time cap.
_Avoid_: segment (reserved for a timestamped piece of transcript text), buffer.

**Audio Capture**:
The thing that records system and/or microphone audio, mixes the sources, and emits ready-to-transcribe Chunks. A seam: production uses the live OS capture, tests can feed canned samples.
_Avoid_: recorder, audio engine (that's one implementation detail).

**Recording Permission**:
Something macOS has to allow before Hover can hear: the Microphone, or Screen Recording (where macOS files system-audio capture — Hover reads the audio and never looks at the screen). A seam: production reads the real system state, tests supply canned answers. Settled before a recording starts, never during one — Hover explains what a permission buys before triggering macOS's own prompt, and offers to record with whatever is already allowed. A Screen Recording grant only reaches the *next* launch, so allowing it ends in a restart.
_Avoid_: authorization, TCC, privacy settings (that's where the user changes one, not the concept), entitlement (that's code signing).

**Chunker**:
The rule for where one Chunk ends and the next begins — based on length and trailing silence. Pure logic, independent of how audio is captured.
_Avoid_: splitter, buffer.

**Segment**:
A timestamped piece of transcript text (start/end in seconds), used to align spoken words with speaker turns.
_Avoid_: chunk (that's audio, not text).

**Transcript Store**:
The thing that owns transcript files on disk — listing, searching, reading, renaming, moving, deleting, and the markdown format they're saved in. A seam: production reads the filesystem, tests can use an in-memory fake.
_Avoid_: repository, database, manager.

**Group**:
A named folder that transcripts can be filed under, shown as a section in the sidebar.
_Avoid_: folder, category, tag.

**Output Destination**:
A place the user can pick for saved transcripts: the standard folder, an Obsidian Vault, or any folder they choose. Exactly one is in use at a time, and transcripts are never copied to a second one.
_Avoid_: export target, sync location, push target.

**Vault Finder**:
The thing that discovers the Obsidian vaults on this Mac so they can be offered as Output Destinations. A seam: production reads Obsidian's config, tests can report canned vaults.
_Avoid_: exporter (nothing is exported), sync, integration, plugin.

**Vault**:
An Obsidian vault folder. Picking one as the Output Destination means transcripts are saved into its Transcripts subfolder — they live there, rather than being copied there.
_Avoid_: workspace, library.

**Relocate**:
To move existing transcripts out of the old folder and into a newly chosen Output Destination, keeping their Groups. Offered when switching folders would otherwise leave files behind.
_Avoid_: export, copy, push (all imply a second copy, which the app never makes).

**Selection**:
Which transcripts are currently marked in the sidebar, plus the anchor used for shift-range marking. Pure value logic, independent of the engine and views.
_Avoid_: highlight, focus, checked set.

**Mark**:
To include a transcript in the current Selection (via the checkbox/keyboard). Marked transcripts can be exported or deleted together.
_Avoid_: select (SwiftUI's `List` selection is the underlying mechanism, but "mark" is the user-facing concept).

**Settings Store**:
The thing that persists user preferences (input source, speaker tagging, output folder). A seam: production uses `UserDefaults`, tests use an in-memory store.
_Avoid_: config, preferences manager, defaults.

**Menu Bar Moth**:
The moth Hover shows in the macOS menu bar for as long as it's running — white on the dark menu bar when idle, red while a recording is in progress. Clicking it brings the window back to the front. It needs roughly 40 points of free menu bar space; if there is none, macOS hides it rather than shrinking it.
_Avoid_: tray icon (that's Windows), status icon, indicator.

**Agent Mode** (headless / CLI):
Running Hover from the command line (e.g. driven by Claude Code) instead of the GUI: it starts recording immediately, stops on a duration or Ctrl-C, and prints the transcript to stdout. `--output` can point the run at a folder or a Vault. No window, no dock icon.
_Avoid_: server mode, daemon, autotest (autotest is one legacy flag, not the concept).

**Install Layout**:
Where the Whisper helper, the speaker-tagging helper, and the model data live on this Mac. A value type that resolves presence-based from an injected bundle root and home directory: bundled helpers and Application Support model data win when present, otherwise the dev locations (Homebrew `whisper-cli`, transcripts `models/`, `diar-venv`). The Transcriber and the speaker-tagging pass both read from it; model data never follows the Output Destination.
_Avoid_: path resolver, tool locator, bootstrap paths.

**Model Setup**:
The thing that reports which model data is present and fetches what is missing, reporting overall progress. A seam: production downloads the three pinned model files into the Application Support model directory; tests supply a fake. Required until all three files are present and size-checked; the app window shows a setup screen in place of its normal content while setup is required. Agent Mode does not run it — a headless run with model data missing fails fast on stderr.
_Avoid_: installer, downloader, bootstrapper.
