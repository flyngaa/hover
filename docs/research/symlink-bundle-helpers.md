# Does `/usr/local/bin/hover` resolve bundled helpers?

**Ticket:** [#4](https://github.com/flyngaa/hover/issues/4) (map: [#3](https://github.com/flyngaa/hover/issues/3))  
**Question:** When `hover` is a symlink (or similar) from `/usr/local/bin/hover` to `Hover.app/Contents/MacOS/Hover`, does `Bundle.main` / `InstallLayout.current` still resolve `Contents/Helpers/` and app resources correctly on modern macOS? What shim form do shipping apps use if not?

**Verdict:** **No** for a direct symlink onto `Contents/MacOS/Hover`. That form makes `Bundle.main.bundleURL` resolve to the symlink’s parent directory (e.g. `/usr/local/bin`), so `InstallLayout.current` does not see `Contents/Helpers/…`. Shipping VS Code / Cursor CLIs avoid that by PATH-symlinking to a **shell wrapper** that `exec`s the real Mach-O at its absolute path inside the `.app`.

---

## How Hover resolves helpers today

`InstallLayout.current` takes the production bundle root from Foundation and appends fixed relative helper paths:

```67:72:Sources/InstallLayout.swift
    static var current: InstallLayout {
        resolve(
            bundleRoot: Bundle.main.bundleURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }
```

Relative paths (same file):

- `Contents/Helpers/whisper-cli`
- `Contents/Helpers/sherpa-onnx-offline-speaker-diarization`

Presence of those executables selects the release layout (Application Support models). If they are missing, resolution falls back to Homebrew `whisper-cli` and `diar-venv` Python — paths that the ship plan says end users must never need.

So the CLI PATH entry is only safe if `Bundle.main.bundleURL` is the `.app` root when the process runs.

---

## What Apple documents about the main bundle

### Main bundle = bundle that contains the running executable

Apple’s Bundle Programming Guide:

> The main bundle is the bundle that contains the code and resources for the running application.

Source: [Accessing a Bundle’s Contents](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html) (Bundle Programming Guide / CFBundles).

Foundation’s `Bundle.main` is described as returning “the bundle object that contains the current executable”

Source: [Bundle.main](https://developer.apple.com/documentation/foundation/bundle/main).

macOS application bundles use the modern layout with `Contents/MacOS/` for the executable and other `Contents/` subdirectories for supporting files

Source: [Bundle Structures](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html) (Bundle Programming Guide).

### Main-bundle discovery depends on the process executable path

The same CFBundles guide warns that main-bundle lookup can fail when the launcher does not provide a usable executable path:

> Bundles rely on either the path to the executable being in `argv[0]` or the presence of the executable's path in the `PATH` environment variable. If neither of these is present, the bundle routines might not be able to find the main bundle directory.

Source: [Accessing a Bundle’s Contents](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html).

### `_NSGetExecutablePath` may return a symlink path (not a real path)

Apple’s `dyld(3)` man page for `_NSGetExecutablePath`:

> Note that `_NSGetExecutablePath()` will return "a path" to the executable not a "real path" to the executable. That is, the path may be a symbolic link and not the real file.

Source: [dyld(3) — `_NSGetExecutablePath`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dyld.3.html) (also `man 3 dyld` on macOS).

### Core Foundation uses that path, then walks up looking for `MacOS` / `Contents`

Apple open-source Core Foundation (`apple-oss-distributions/CF`):

1. On macOS, `_CFProcessPath()` sets the process path from `_NSGetExecutablePath` (optionally overridden by `CFProcessPath`), **without** `realpath`/`readlink` resolution  
   Source: [`CFPlatform.c`](https://github.com/apple-oss-distributions/CF/blob/main/CFPlatform.c) (`_CFProcessPath` for `DEPLOYMENT_TARGET_MACOSX`).

2. `CFBundleGetMainBundle` builds the main bundle URL from that process path via `_CFBundleCopyBundleURLForExecutablePath`, which strips the executable name and, if the parent directory is a platform executables folder such as `MacOS`, walks up through `Contents` to the bundle root. If the path is `/usr/local/bin/hover`, that walk never sees `MacOS`/`Contents`, so the “bundle URL” collapses to `/usr/local/bin` (or whatever directory holds the symlink).  
   Source: [CFBundle.c — `_CFBundleCopyBundleURLForExecutablePath`](https://opensource.apple.com/source/CF/CF-550.42/CFBundle.c.auto.html) (same algorithm in later CF drops).

Implication for Hover: a PATH symlink **directly** onto `Hover.app/Contents/MacOS/Hover` feeds CF/Foundation a non-bundle path. `Bundle.main.bundleURL` is then wrong for appending `Contents/Helpers/…`.

---

## Empirical check on this Mac (macOS 26.5.2 / Darwin 25)

Throwaway probe: a minimal `HoverProbe.app` with `Contents/MacOS/HoverProbe` (Swift printing `Bundle.main` / `_NSGetExecutablePath`) and `Contents/Helpers/whisper-cli`.

| Invocation | `bundleURL` | helper under `bundleURL/Contents/Helpers/…` |
|---|---|---|
| Direct `…/HoverProbe.app/Contents/MacOS/HoverProbe` | `…/HoverProbe.app` | present |
| Symlink `…/hover-symlink` → that Mach-O | parent of the symlink (not the `.app`) | **missing** |
| PATH-style name for that symlink | same wrong parent | **missing** |
| VS Code-style: PATH symlink → bash wrapper under `Contents/Resources/app/bin/` that `exec`s absolute `Contents/MacOS/HoverProbe` | `…/HoverProbe.app` | present |

Observed when invoked via the direct symlink:

- `_NSGetExecutablePath` returned the **symlink** path (matches Apple’s dyld note).
- `Bundle.main.bundleURL` was the symlink’s directory, not the `.app`.
- `InstallLayout`-style `bundleRoot.appendingPathComponent("Contents/Helpers/whisper-cli")` therefore missed the helper.

Observed when the wrapper `exec`’d the absolute Mach-O path inside the `.app`:

- `_NSGetExecutablePath` / `Bundle.main` pointed at the real bundle again, and the helper path resolved.

---

## What VS Code and Cursor ship

They do **not** put `/usr/local/bin/code` (or `cursor`) as a symlink onto `Contents/MacOS/…`.

### Installed PATH entry (this machine)

```text
/usr/local/bin/code   -> /Applications/Visual Studio Code.app/Contents/Resources/app/bin/code
/usr/local/bin/cursor -> /Applications/Cursor.app/Contents/Resources/app/bin/code
```

Both targets are **bash scripts**, not the app Mach-O. (`file` reports “Bourne-Again shell script”.)

### First-party wrapper (VS Code)

[`resources/darwin/bin/code.sh`](https://github.com/microsoft/vscode/blob/main/resources/darwin/bin/code.sh) (ships as `Contents/Resources/app/bin/code`):

1. Walks symlinks from `BASH_SOURCE[0]` (`app_realpath`).
2. Derives the enclosing `*.app` path.
3. Runs `"$APP_PATH/Contents/MacOS/@@NAME@@"` with an absolute path (plus the CLI JS entry).

So the process that actually needs the app bundle is started with an executable path **inside** `Contents/MacOS/`, which is what CFBundle’s walk expects.

Official docs describe installing that CLI via Command Palette (“Shell Command: Install 'code' command in PATH”) or by adding `…/Contents/Resources/app/bin` to `PATH`

Source: [Installing VS Code on macOS — Launch from the command line](https://code.visualstudio.com/docs/setup/mac).

### Cursor

Cursor.app ships the same Electron/VS Code–lineage layout: `Contents/Resources/app/bin/cursor` (and `code`) are shell wrappers with the same `app_realpath` → absolute `Contents/MacOS/Cursor` pattern. The PATH install on this Mac is a symlink to that in-bundle script, not to `Contents/MacOS/Cursor`.

---

## Answer for the ship plan

| Shim form | `Bundle.main` / `InstallLayout.current` for bundled helpers |
|---|---|
| Symlink `/usr/local/bin/hover` → `Hover.app/Contents/MacOS/Hover` | **Fails** — main bundle root is wrong; helpers look absent; release layout falls through to Homebrew/`diar-venv`. |
| Symlink (or PATH entry) → small wrapper that resolves the `.app` and `exec`s absolute `Contents/MacOS/Hover` | **Works** — matches VS Code/Cursor; Foundation sees a real bundle executable path. |
| Add `Hover.app/Contents/…/bin` to `PATH` (wrapper lives in the bundle) | **Works** if that entry is a resolver wrapper, not a naked symlink to the Mach-O (VS Code’s manual PATH docs). |

**Recommendation for #3 (decision input only — not an implementation):** Install CLI should not be a bare symlink onto `Contents/MacOS/Hover`. Prefer a VS Code-style wrapper (or equivalent that `exec`s the absolute Mach-O path after resolving the app bundle) so `InstallLayout.current` keeps finding `Contents/Helpers/`.

---

## Sources

1. Apple — [Accessing a Bundle’s Contents](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/AccessingaBundlesContents/AccessingaBundlesContents.html)  
2. Apple — [Bundle Structures](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html)  
3. Apple — [Bundle.main](https://developer.apple.com/documentation/foundation/bundle/main)  
4. Apple — [dyld(3) / `_NSGetExecutablePath`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dyld.3.html)  
5. Apple open source — [`CFPlatform.c` `_CFProcessPath`](https://github.com/apple-oss-distributions/CF/blob/main/CFPlatform.c)  
6. Apple open source — [`CFBundle.c` `_CFBundleCopyBundleURLForExecutablePath`](https://opensource.apple.com/source/CF/CF-550.42/CFBundle.c.auto.html)  
7. This repo — `Sources/InstallLayout.swift`  
8. Microsoft VS Code — [`resources/darwin/bin/code.sh`](https://github.com/microsoft/vscode/blob/main/resources/darwin/bin/code.sh)  
9. Microsoft — [VS Code macOS setup — CLI PATH](https://code.visualstudio.com/docs/setup/mac)  
10. Local first-party install artifacts — `/usr/local/bin/{code,cursor}` → `*.app/Contents/Resources/app/bin/*` shell wrappers (Cursor.app / Visual Studio Code.app on this Mac)  
11. Local probe — macOS 26.5.2, Swift `Bundle.main` + `_NSGetExecutablePath` under direct symlink vs wrapper `exec` (reproducible steps above)
