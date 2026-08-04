# Agent instructions

## No keychain or sensitive credential commands

Never run commands that touch the Keychain, signing identities, notary credentials, or other secrets. On this machine they can trigger IT security rules that lock the computer down.

Forbidden examples (non-exhaustive):

- `security` (including `security find-identity`, `security find-generic-password`, `security unlock-keychain`, etc.)
- `codesign` / `notarytool` / `stapler` when they would prompt for or read Keychain credentials
- Reading or printing `.p8`, `.p12`, API keys, notary profiles, or similar credential files
- Any script whose documented path is to look up Developer ID or notary credentials from the Keychain (e.g. do not run `./build.sh` or `./release.sh` solely for their signing steps if that invokes `security`)

If a task needs signing, notarization, or credentials, stop and tell the human what to run locally instead of invoking it yourself.
