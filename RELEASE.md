# Cutting a Hover release

Day-to-day work stays on `./build.sh`. A human-pushed `vMAJOR.MINOR.PATCH` tag is the only publish trigger: GitHub Actions builds on an Apple Silicon `macos-15` runner, notarizes `Hover.dmg`, publishes the GitHub Release, and updates the `flyngaa/homebrew-tap` cask. Nothing secret belongs in git.

`./release.sh` remains a local production-build smoke path. It can build the same notarized DMG on the release Mac, but it never creates a GitHub Release or updates the personal tap.

## GitHub Actions secrets (repository setup)

Configure these secrets before pushing the first release tag:

- `DEVELOPER_ID_P12_BASE64`: base64-encoded Developer ID Application `.p12`
- `DEVELOPER_ID_P12_PASSWORD`: password for that `.p12`
- `ASC_API_KEY_P8_BASE64`: base64-encoded App Store Connect API key
- `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`: identifiers for that API key
- `HOMEBREW_TAP_TOKEN`: token with contents write access to `flyngaa/homebrew-tap`

The workflow writes credentials only into the runner's temporary directory and a temporary Keychain, then removes them in an `always()` cleanup step. The coding Mac does not need release credentials.

## One-time setup (human)

Do this once on the Mac that will cut releases. Re-do only when the identity or notary credentials are replaced.

1. Install a **Developer ID Application** certificate for team **ALHP6856UK** so this identity is available for codesign:

   `Developer ID Application: Antoine Valente (ALHP6856UK)`

2. Store App Store Connect notary credentials in the Keychain as profile **`hover-notary`**:

   ```bash
   xcrun notarytool store-credentials hover-notary
   ```

   Prefer an App Store Connect API key (Issuer ID, Key ID, and the `.p8` file kept somewhere durable and private — not in this repo).

3. Confirm the profile authenticates:

   ```bash
   xcrun notarytool history --keychain-profile hover-notary
   ```

`./setup-signing.sh` is only for local **Hover Local Dev** signing used by `./build.sh`. It is not part of the release track.

## Helper cache (when needed)

`Scripts/build-release-helpers.sh` fills the gitignored `dist/helpers/` cache:

- `whisper-cli`
- `sherpa-onnx-offline-speaker-diarization`
- `libonnxruntime.1.27.0.dylib`

Re-run it when the pinned whisper.cpp or sherpa-onnx versions in that script change, or when `dist/helpers/` is missing or incomplete. Ordinary releases do **not** rebuild helpers: `./release.sh` never invokes the cache script, and fails fast if the cache is absent.

## Publish from a tag

After the intended commit is on the branch to release, a human creates and pushes an exact semantic-version tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

The tag's version without `v` becomes both `CFBundleShortVersionString` and `CFBundleVersion`. No branch push, scheduled job, local script, or manual Actions dispatch publishes a Release.

The workflow serializes release tags, prepares a draft Release, commits the matching version and SHA-256 to the personal tap, and only then publishes the Release. A failed run leaves the Release as a reusable draft, so rerunning the same tag can finish without leaving a public Release whose tap bump is missing. It refuses to move the tap backward to an older version. The published install command is:

```bash
brew install --cask flyngaa/tap/hover
```

## Build a local smoke DMG

On an Apple Silicon release Mac, from a clean checkout with the one-time setup and helper cache in place:

```bash
./release.sh
```

Success looks like exit status 0 and a final line of:

```text
dist/Hover.dmg
```

Then confirm the staple on the release Mac:

```bash
xcrun stapler validate dist/Hover.dmg
```

This output is for production-build smoke only; do not upload it as a Release. Share the tag workflow's DMG only after the second-Mac smoke below passes. A DMG that works on the machine that built it is not proof under Gatekeeper.

## Second-Mac Gatekeeper, first-launch, and Agent Mode smoke

Run this checklist manually after the human-triggered tag workflow is green. The workflow does not start this verification, and passing it does not create another tag or publish another build.

Use a second **Apple Silicon** Mac that has no Homebrew, no `diar-venv`, and no Hover model data under `~/Library/Application Support/Hover/`. Download that tag's `Hover.dmg` from GitHub Releases through a browser so macOS applies quarantine — that is the recipient's path.

Walk this checklist. Any workaround means an earlier release ticket failed; do **not** treat these as installation steps:

- right-click → Open
- `xattr -d com.apple.quarantine …`
- allowing a blocked app in System Settings → Privacy & Security

### Install and launch

- [ ] Download the green tag workflow's `Hover.dmg` from GitHub Releases onto the second Mac
- [ ] Double-click the DMG; it opens without a Gatekeeper block
- [ ] Drag Hover into Applications
- [ ] Launch Hover from Applications by double-clicking (no workaround)

### First-launch setup

- [ ] The setup screen appears and starts downloading on its own
- [ ] Setup downloads **model data only** (~600 MB) — no Homebrew, no Python, no pip, no new executables
- [ ] When setup finishes, the screen dismisses into the normal app (no extra Continue step)
- [ ] Choose Install CLI when Hover offers it and approve the administrator prompt
- [ ] Microphone and Screen Recording prompts appear with Hover’s own usage explanations, and are the only permission steps

### Agent Mode setup

Open a new Terminal window. These checks use the PATH `hover` installed by Install CLI; it must run Hover through the in-bundle wrapper so Install Layout continues to find the bundled Helpers. The Homebrew cask's PATH `hover` uses that same wrapper and is an equivalent entry point on a Mac installed through the personal tap.

- [ ] `command -v hover` reports `/usr/local/bin/hover` for the Install CLI path
- [ ] `hover setup --status` writes a short “ready” status to stderr, leaves stdout empty, and exits 0 without downloading
- [ ] `hover setup` also writes “ready” to stderr, leaves stdout empty, and exits 0 without opening Hover's window or showing a dock icon

To check the stream and exit-code contract explicitly, redirect stdout and stderr to separate temporary files. Both commands should leave the stdout file empty, put their status in the stderr file, and print `exit: 0`:

```bash
hover setup --status >/tmp/hover-setup.stdout 2>/tmp/hover-setup.stderr
echo "exit: $?"; wc -c /tmp/hover-setup.stdout; cat /tmp/hover-setup.stderr

hover setup >/tmp/hover-setup.stdout 2>/tmp/hover-setup.stderr
echo "exit: $?"; wc -c /tmp/hover-setup.stdout; cat /tmp/hover-setup.stderr
```

### Agent Mode Recording Permissions and recording

On this clean Mac, leave Screen Recording ungranted but allow Microphone access. Then record from both sources so Hover has to explain the missing Recording Permission and use its microphone fallback:

```bash
hover record --duration 10 --source both \
  >/tmp/hover-record.stdout 2>/tmp/hover-record.stderr
echo "exit: $?"; cat /tmp/hover-record.stderr; cat /tmp/hover-record.stdout
```

- [ ] The command opens no Hover window and shows no dock icon
- [ ] Stderr says Screen Recording permission is needed and that Hover is recording the microphone only
- [ ] After speaking during the ten-second run, the command exits 0 and stdout contains the transcript
- [ ] No Homebrew or `diar-venv` is installed or consulted; the run uses Hover.app's bundled Helpers

### GUI recording

- [ ] Record something with two voices and speaker tagging on
- [ ] The transcript has speaker labels (e.g. Speaker 1 / Speaker 2)
- [ ] That Mac still has no Homebrew and no `diar-venv`

### Returning launch

- [ ] Quit and relaunch Hover — setup does not appear
- [ ] With the network off, relaunch again — setup still does not appear; the app is usable offline

If every box above is checked, the release is shareable.
