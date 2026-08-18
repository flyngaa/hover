---
name: hover
description: Record and transcribe audio on macOS with Hover from the command line — meetings, voice notes, system audio, or the microphone — and save transcripts to a folder or an Obsidian vault. Use when the user wants to record, transcribe, or capture audio, or asks Hover to take notes.
---

# Using Hover

Hover records audio on-device and writes a Markdown transcript. It is agent-first:
the transcript goes to stdout, everything else goes to stderr, and the exit code
tells you whether it worked. If `hover` is not on PATH, invoke
`/Applications/Hover.app/Contents/MacOS/Hover` instead.

## Before recording

If a recording fails or you are unsure the machine is ready, check first:

```bash
hover doctor --json
```

It reports architecture, macOS version, PATH install, model data, microphone,
system audio, and output-folder writability as `{ "ready", "checks": [...] }`
without prompting or downloading. If it is not ready, run the `install-hover`
skill.

## Recording

```bash
hover record [options]
```

Options:

- `-d, --duration <seconds>` — record for N seconds, then stop. Omit to record
  until interrupted (see Stopping).
- `-o, --output <path|vault>` — where to save. A path (starts with `/`, `~`, or
  `.`) saves to that folder; any other value is looked up as an Obsidian vault
  name and saves into its `Transcripts` subfolder. If it matches neither, the run
  fails before recording and lists the vaults it found. Omit to use the folder set
  in the app (default `~/Documents/Transcripts`).
- `--source <both|system|microphone>` — which audio to capture. Omit to use the
  app's saved choice (default `both`).
- `--json` — emit `{ "transcript": string, "savedPath": string|null }` instead of
  plain text.

Examples:

```bash
hover record --duration 30                          # 30s, app defaults
hover record --source both --output ~/Desktop       # mic + system audio to a folder
hover record --output "My Notes" --json             # into an Obsidian vault, as JSON
hover record                                         # until stopped, then transcribe
```

## The output contract

- stdout carries only the transcript (or the JSON object with `--json`). Capture
  it directly: `transcript="$(hover record -d 20)"`.
- stderr carries progress and diagnostics (`• Recording…`, `• Transcribing…`,
  warnings). Never parse stdout for status.
- Exit code is non-zero on failure, including when a transcript was produced but
  could not be saved — in that case the transcript is still printed to stdout so it
  is not lost, but treat the run as failed and fix the output folder.

Do not rely on the exit code alone to confirm a save. When you need the file, use
`--json` and check that `savedPath` is non-null. An empty transcript means no
speech was captured, not an error.

## Stopping a recording

A recording started without `--duration` runs until it receives a stop signal.
`Ctrl-C` (SIGINT), `kill` (SIGTERM), and the hangup from a closing terminal
(SIGHUP) all mean "stop and save" — never "discard". Hover keeps running past the
signal until the transcript is written, because the audio only exists in memory
until then. To stop a background recording:

```bash
kill -INT <pid>   # or -TERM; Hover finishes transcription, then exits
```

Do not `kill -9` a recording you care about — that skips the save.

## Notes

- A headless run shows no window and no dock icon, only a menu-bar moth for the
  duration. It needs a logged-in GUI session; it will not work over a bare SSH
  connection.
- In `both` mode, transcript lines are labelled `**Mic:**` / `**System:**` by
  which pipe captured them, not by speaker identification.
- If system audio was refused, a `both` recording falls back to mic-only and notes
  it on stderr rather than failing.
