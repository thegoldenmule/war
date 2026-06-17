# Build & Distribution

**Status:** current

## Kind
component

## Summary
A *script-driven, multi-platform export* pipeline for the War Godot client. A single committed shell script, `tools/build.sh`, drives headless Godot exports for web and native targets (macOS, Windows, Web, iOS, Android), reading per-platform settings from the project's `export_presets.cfg`. The authoritative validator is *not* part of this client build — it ships separately as a Snapser BYOSnap (Docker image).

## Purpose
To make producing a distributable build of the client a *one-command, reproducible* operation that works on a developer's machine today, without depending on a CI system. The script wraps Godot's per-platform export (the engine has no "export all" flag) in a single loop with consistent output paths, debug/release modes, and a pass/fail summary, while keeping the *source of truth* for output names, icons, and signing in the Godot export presets. Wiring this into CI is deliberately *deferred* — the skeleton is shaped so a CI job can later call the same script unchanged.

## Design notes
Current skeleton state: tools/build.sh is committed and complete, but game/export_presets.cfg is NOT yet committed. build.sh has an explicit preflight that errors out with a TODO(skeleton) message when the presets file is missing, instructing the developer to author presets in the Godot editor (Project > Export) first. Until the presets exist, no platform can be exported.

Platform support tiers on a Mac host: macos, windows, and web build out of the box once the export templates are installed. ios requires Xcode plus an Apple signing identity; android requires JDK 17, the Android SDK, and a keystore. Until those toolchains and secrets are configured in the gitignored .env, the ios and android presets export unsigned or fail at the signing step.

Usage: tools/build.sh <platform> [<platform> ...] builds the named platforms; tools/build.sh all builds every platform; --release switches from the default debug export; --list prints the platform names and exits. The engine is overridable with GODOT=/path/to/Godot. After a successful web build the script prints a hint to serve it locally via python3 -m http.server from build/web.

CI is deferred by design. The script is shaped as a CI-ready skeleton (carries a TODO(skeleton): CI pipeline marker) so that a future pipeline can call the exact same entrypoint per platform without restructuring; there is currently no committed CI workflow.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- `tools/build.sh`
- `game/export_presets.cfg`
- `validator/Dockerfile`
- `validator/snapser-byosnap-profile.json`

## Data model
The build is parameterized by a small platform table baked into `build.sh`: each friendly platform name (`macos`, `windows`, `web`, `ios`, `android`) maps to a Godot preset name (e.g. `macos` -> `macOS`, `windows` -> `Windows Desktop`) and an output path under `build/` (e.g. `build/web/index.html`, `build/macos/War.zip`, `build/windows/War.exe`). Mode is `debug` (default) or `release`, selecting `--export-debug` vs `--export-release`. The engine binary is overridable via the `GODOT` env var. Optional signing/secret config (Android keystore, Apple team/identity) is sourced from a gitignored `<repo>/.env`. The per-platform export settings themselves — output filenames, icons, signing flags — live in `game/export_presets.cfg`, the authored Godot project file, not in the script.

## Usage
_None._

## Invariants & constraints
- `game/export_presets.cfg` is the single source of truth for per-platform export settings (output names, icons, signing); `build.sh` only selects a preset by name and an output path, and must never duplicate those settings.
- Preset names referenced in `build.sh`'s platform table (e.g. `macOS`, `Windows Desktop`, `Web`, `iOS`, `Android`) must match the preset names in `export_presets.cfg` exactly, or the headless export fails.
- The validator is built and shipped independently of the client export, as a Snapser BYOSnap (its own Dockerfile + snapser-byosnap-profile.json); `build.sh` produces only client artifacts and never touches the validator.
- The build runs Godot headless and is non-interactive: it preflights the engine binary and the presets file, exits non-zero on any platform failure, and is safe to invoke unchanged from a future CI job.

## Synced commit
_None._
