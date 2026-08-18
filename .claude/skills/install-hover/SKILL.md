---
name: install-hover
description: Install Hover (private on-device macOS transcription) and verify it can record end to end. Use when the user wants to install, set up, or get Hover working, or opens this repo and says "install this".
---

# Install Hover

Get Hover installed and provably working: the app on disk, the `hover` command on
PATH, the Whisper model downloaded, macOS recording permissions granted, and one
real test recording saved to a file.

Hover is a macOS app. The `hover` command lives inside `Hover.app` — there is no
separate CLI binary. Installing the app is one Homebrew command; the friction is
everything after it (a ~575 MB model download and two macOS permissions that only
a human can grant). Your job is to run the deterministic steps and shepherd the
human through the parts macOS reserves for a person clicking in System Settings.

## How to run this

Work through the steps in order. After each step that changes state, run
`hover doctor --json` and let its output — not your assumptions — decide what to do
next. Do not move on from a step until its check passes. Never invent a hidden
download or click a permission on the user's behalf; you cannot, and pretending
otherwise strands the install.

## Step 1 — Preflight

Confirm the machine can run Hover before installing anything:

```bash
uname -m        # must be arm64 (Apple Silicon)
sw_vers -productVersion   # must be 14.2 or later
command -v brew  # Homebrew must be installed
```

If `uname -m` is not `arm64`, or the macOS version is below 14.2, stop and tell the
user Hover requires an Apple Silicon Mac on macOS 14.2 (Sonoma) or later. If
Homebrew is missing, point them at https://brew.sh and stop.

## Step 2 — Install the app

```bash
brew install --cask flyngaa/tap/hover
```

Then confirm the command resolves. In a new shell, `hover` should be on PATH
because the cask links it:

```bash
command -v hover && hover --help
```

If `hover` is not found, the rest of this skill still works by invoking the binary
directly at `/Applications/Hover.app/Contents/MacOS/Hover`. Prefer the `hover`
command when it resolves.

## Step 3 — Establish a baseline with doctor

```bash
hover doctor --json
```

This prints one JSON object: `{ "ready": bool, "checks": [ { "id", "name",
"status", "detail", "fix" } ] }`. `status` is `ok`, `warn`, or `fail`. Only `fail`
makes Hover unready; `warn` is informational (for example, system audio not
granted, which mic-only recording tolerates). The command reads state only — it
never triggers a prompt or a download — so it is safe to call as often as you
like. Use it after every subsequent step to decide what remains.

## Step 4 — Download the model (if the `model` check fails)

Hover deliberately never downloads the model during a recording, so a headless
`hover record` fails fast instead of hanging on an invisible ~575 MB download.

If the `model` check is `fail`, tell the user this will download about 575 MB, then:

```bash
hover setup
```

Re-run `hover doctor --json` and confirm the `model` check is now `ok`.

## Step 5 — Grant permissions (if the `microphone` or `systemAudio` check is not ok)

This is the step you cannot complete alone. macOS permission dialogs must be
answered by a person, and there is no command that grants them.

Critical: trigger the prompt by opening the app, not by running `hover record`.

```bash
open -a Hover
```

Opening the app makes the permission request come from Hover itself, so macOS
attributes the grant to Hover (running `hover record` from a terminal can attribute
it to the terminal instead, and then Hover asks again later). Hover shows its own
sheet with an Allow button, and — for system audio — a Restart button, because
macOS only applies a fresh system-audio grant after the app relaunches.

Ask the user to:

1. In Hover, start a recording (or accept the permission sheet it shows).
2. Click Allow for the microphone.
3. For system audio, allow Hover under System Settings > Privacy & Security >
   Screen & System Audio Recording, then let Hover restart when it offers to.

You can jump them straight to the right panes if needed:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
```

After they confirm, re-run `hover doctor --json`. Repeat until `microphone` is `ok`.
`systemAudio` at `warn` is acceptable — it only means mic-only recording until it is
granted — but prefer getting it to `ok` if the user wants meeting/system audio.

## Step 6 — Prove it with a real recording

Do not trust exit codes alone here: a run can exit non-zero cleanly, and a silent
recording can capture nothing. Record a few seconds to a folder you know is
writable and assert a file was actually saved.

```bash
out="$HOME/Documents/Transcripts"
mkdir -p "$out"
hover record --duration 5 --output "$out" --json
```

Ask the user to speak for those 5 seconds. The result is JSON with `transcript`
and `savedPath`. The install is verified only when `savedPath` is non-null. If
`savedPath` is null but `transcript` is present, saving failed — check the `output`
row of `hover doctor` and pick a writable `--output`. If `transcript` is empty, no
speech was captured; retry and have the user speak.

## Step 7 — Teach Claude how to use Hover afterwards

So the user can just say "record the next 20 minutes into my notes" later, install
the companion usage skill into their personal skills directory:

```bash
mkdir -p "$HOME/.claude/skills/hover"
cp "$(dirname "$0")/../hover/SKILL.md" "$HOME/.claude/skills/hover/SKILL.md"
```

If you cannot resolve the source path, copy it from this repository's
`.claude/skills/hover/SKILL.md`.

## Done

Report to the user: the app is installed, `hover` resolves, the model is present,
which permissions are granted, and the path of the saved test transcript. If
`systemAudio` is still `warn`, say so and how to finish it.
