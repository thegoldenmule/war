#!/usr/bin/env bash
#
# build.sh — export the War Godot client for one, several, or all platforms.
#
# This is a script-driven, multi-platform export skeleton. The export presets it
# drives live in the Godot project (game/export_presets.cfg) — the source of truth
# for output names, icons, and per-platform settings. Wiring this into CI is deferred
# (# TODO(skeleton): CI pipeline).
#
# Usage:
#   tools/build.sh <platform> [<platform> ...]   build the named platform(s)
#   tools/build.sh all                           build every platform
#   tools/build.sh --release <platform> ...      release export (default is debug)
#   tools/build.sh --list                        list platforms and exit
#
# Platforms: macos windows web ios android
#
# Examples:
#   tools/build.sh macos
#   tools/build.sh web windows
#   tools/build.sh --release all
#
# Notes:
#   - Godot has no "export all" flag; this script loops one export per platform.
#   - macos/windows/web build out of the box on a Mac host (templates installed).
#   - ios needs Xcode + an Apple signing identity; android needs JDK 17 + the Android
#     SDK and a keystore. Fill those into a gitignored .env (see below); until then
#     those two presets export unsigned / fail at the sign step.
#   - Override the engine with:  GODOT=/path/to/Godot tools/build.sh ...
#   - Secrets are read from <repo>/.env if present (never commit it), e.g.:
#       ANDROID_KEYSTORE=/abs/path/release.keystore
#       ANDROID_KEYSTORE_USER=...   ANDROID_KEYSTORE_PASS=...
#       APPLE_TEAM_ID=...           APPLE_SIGN_IDENTITY=...
#
# Make executable once:  chmod +x tools/build.sh
set -euo pipefail

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$REPO_DIR/game"
BUILD_DIR="$REPO_DIR/build"

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"

# load optional signing/secret config
[[ -f "$REPO_DIR/.env" ]] && { set -a; source "$REPO_DIR/.env"; set +a; }

# --- platform table ----------------------------------------------------------
# friendly | preset name (must match game/export_presets.cfg) | output (relative to build/)
ALL_PLATFORMS=(macos windows web ios android)

preset_name() {
  case "$1" in
    macos)   echo "macOS" ;;
    windows) echo "Windows Desktop" ;;
    web)     echo "Web" ;;
    ios)     echo "iOS" ;;
    android) echo "Android" ;;
    *) return 1 ;;
  esac
}

output_path() {
  case "$1" in
    macos)   echo "$BUILD_DIR/macos/War.zip" ;;
    windows) echo "$BUILD_DIR/windows/War.exe" ;;
    web)     echo "$BUILD_DIR/web/index.html" ;;
    ios)     echo "$BUILD_DIR/ios/War.ipa" ;;
    android) echo "$BUILD_DIR/android/War.apk" ;;
    *) return 1 ;;
  esac
}

# --- arg parsing -------------------------------------------------------------
MODE="debug"
TARGETS=()

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --release) MODE="release" ;;
    --debug)   MODE="debug" ;;
    --list)    printf '%s\n' "${ALL_PLATFORMS[@]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    all)       TARGETS=("${ALL_PLATFORMS[@]}") ;;
    macos|windows|web|ios|android) TARGETS+=("$arg") ;;
    *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "error: no platform given. Try: tools/build.sh all  (or --help)" >&2
  exit 2
fi

# --- preflight ---------------------------------------------------------------
if [[ ! -x "$GODOT" ]]; then
  echo "error: Godot editor binary not found/executable at: $GODOT" >&2
  echo "       set GODOT=/path/to/Godot and retry." >&2
  exit 1
fi
if [[ ! -f "$PROJECT_DIR/export_presets.cfg" ]]; then
  echo "error: $PROJECT_DIR/export_presets.cfg missing." >&2
  echo "       Define export presets in the Godot editor (Project > Export) first." >&2
  echo "       (# TODO(skeleton): commit export_presets.cfg once presets are authored.)" >&2
  exit 1
fi

EXPORT_FLAG="--export-debug"
[[ "$MODE" == "release" ]] && EXPORT_FLAG="--export-release"

echo "War build — mode=$MODE  godot=$("$GODOT" --version 2>/dev/null | head -1)"
echo "targets: ${TARGETS[*]}"
echo

# --- build loop --------------------------------------------------------------
declare -a OK=() FAIL=()

for p in "${TARGETS[@]}"; do
  preset="$(preset_name "$p")"
  out="$(output_path "$p")"
  mkdir -p "$(dirname "$out")"

  echo "──▶ $p  [$preset]  →  ${out#$REPO_DIR/}"
  if "$GODOT" --headless --path "$PROJECT_DIR" "$EXPORT_FLAG" "$preset" "$out"; then
    OK+=("$p")
    echo "   ✓ $p"
  else
    FAIL+=("$p")
    echo "   ✗ $p (export failed — see Godot output above)"
  fi
  echo
done

# --- summary -----------------------------------------------------------------
echo "──────── summary ────────"
[[ ${#OK[@]}   -gt 0 ]] && echo "  ok:     ${OK[*]}"
[[ ${#FAIL[@]} -gt 0 ]] && echo "  failed: ${FAIL[*]}"

if [[ " ${OK[*]} " == *" web "* ]]; then
  echo
  echo "  serve web locally:  (cd build/web && python3 -m http.server 8000)  →  http://localhost:8000"
fi

[[ ${#FAIL[@]} -gt 0 ]] && exit 1
exit 0
