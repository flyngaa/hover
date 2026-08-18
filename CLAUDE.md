# Hover

Hover is a private, on-device transcription app for macOS. It captures system
audio and/or the microphone and saves Markdown transcripts to a folder or an
Obsidian vault. It has two entry points into one recording pipeline: a SwiftUI
app, and an agent-first `hover` command that lives inside `Hover.app`.

## If the user wants to install or use Hover (not develop it)

Do not build from this source. Use the skills:

- To install Hover and verify it can record end to end, follow
  [.claude/skills/install-hover/SKILL.md](.claude/skills/install-hover/SKILL.md).
  It installs the released app via Homebrew, downloads the model, walks the user
  through the macOS permissions only a human can grant, and proves the install
  with a real test recording.
- To record or transcribe once Hover is installed, follow
  [.claude/skills/hover/SKILL.md](.claude/skills/hover/SKILL.md).

Start with `hover doctor --json`, which reports readiness (architecture, macOS
version, PATH install, model data, microphone, system audio, output folder)
without prompting or downloading.

## If the user wants to develop Hover

- Build: `./build.sh` (Debug app under `.build/xcode-derived-data/...`).
- Test: `./test.sh`.
- Domain language and module boundaries: [CONTEXT.md](CONTEXT.md).
- Architecture, CLI usage, and the release process: [README.md](README.md).

Domain logic lives in `Packages/HoverModules/Sources/HoverCore`, platform
integrations in `HoverPlatform`, and the app plus Agent Mode in `Sources/`.
