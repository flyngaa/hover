# Cutting a Hover release

Day-to-day work stays on `./build.sh`. Releases are laptop-only for v1: credentials live in the release Mac’s Keychain, and the helper cache is local. Nothing secret belongs in git.

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

## Cut the DMG

On an Apple Silicon Mac, from a clean checkout with the one-time setup and helper cache in place:

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

Share only after the second-Mac smoke below passes. A DMG that works on the machine that built it is not proof under Gatekeeper.

## Second-Mac Gatekeeper and first-launch smoke

Use a second **Apple Silicon** Mac that has no Homebrew, no `diar-venv`, and no Hover model data under `~/Library/Application Support/Hover/`. Prefer a path that applies quarantine (AirDrop, browser download, or a copy that keeps the com.apple.quarantine attribute) — that is the recipient’s path.

Walk this checklist. Any workaround means an earlier release ticket failed; do **not** treat these as installation steps:

- right-click → Open
- `xattr -d com.apple.quarantine …`
- allowing a blocked app in System Settings → Privacy & Security

### Install and launch

- [ ] Copy or download `dist/Hover.dmg` onto the second Mac
- [ ] Double-click the DMG; it opens without a Gatekeeper block
- [ ] Drag Hover into Applications
- [ ] Launch Hover from Applications by double-clicking (no workaround)

### First-launch setup

- [ ] The setup screen appears and starts downloading on its own
- [ ] Setup downloads **model data only** (~600 MB) — no Homebrew, no Python, no pip, no new executables
- [ ] When setup finishes, the screen dismisses into the normal app (no extra Continue step)
- [ ] Microphone and Screen Recording prompts appear with Hover’s own usage explanations, and are the only permission steps

### Recording

- [ ] Record something with two voices and speaker tagging on
- [ ] The transcript has speaker labels (e.g. Speaker 1 / Speaker 2)
- [ ] That Mac still has no Homebrew and no `diar-venv`

### Returning launch

- [ ] Quit and relaunch Hover — setup does not appear
- [ ] With the network off, relaunch again — setup still does not appear; the app is usable offline

If every box above is checked, the release is shareable.
