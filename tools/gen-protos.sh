#!/usr/bin/env bash
#
# gen-protos.sh — regenerate everything derived from the protobuf source of truth
# (validator/protos/). Run this whenever a .proto changes:
#
#   1. JS descriptor  — the compiled protobufjs JSON descriptor the validator loads
#                       at runtime (validator/src/validator/proto-gen/validator-descriptor.json)
#   2. GDScript SDK   — godobuf bindings for the game client, written into
#                       game/net/proto/ (hermes_envelope_pb.gd, validator_pb.gd)
#
# The protos:
#   validator/protos/war/validator/v1/   — the war.validator.v1.ValidatorService messages
#                                          (InitMatch / ValidateAction / CompleteMatch).
#   validator/protos/hermes/             — hermes_envelope.proto (ClientMessage/ServerMessage).
# Game state + actions stay canonical-JSON strings inside proto string fields — the wire
# format never re-models the hash domain, so these protos describe envelopes, not game state.
#
# Usage:
#   tools/gen-protos.sh                  # regenerate the JS descriptor + GDScript bindings
#   tools/gen-protos.sh --skip-gdscript  # JS descriptor only (no Godot needed)
#   GODOT=/path/to/Godot tools/gen-protos.sh
#   BUN=/path/to/bun     tools/gen-protos.sh
#
# (# TODO(skeleton): emit validator/swagger.json for the Snapser BYOSnap publish once a
#  swagger generator exists in validator/.)
#
# Make executable once:  chmod +x tools/gen-protos.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$ROOT/validator/protos"
VALIDATOR_DESCRIPTOR="$ROOT/validator/src/validator/proto-gen/validator-descriptor.json"

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
BUN="${BUN:-bun}"

SKIP_GDSCRIPT=0
[ "${1:-}" = "--skip-gdscript" ] && SKIP_GDSCRIPT=1

HERMES_PROTO="$PROTO_DIR/hermes/hermes_envelope.proto"
VALIDATOR_PROTO="$PROTO_DIR/war/validator/v1/validator_messages.proto"

for p in "$HERMES_PROTO" "$VALIDATOR_PROTO"; do
  if [ ! -f "$p" ]; then
    echo "error: proto not found: $p" >&2
    echo "       (# TODO(skeleton): author the protos under validator/protos/ first.)" >&2
    exit 1
  fi
done

echo "→ [1/2] JS descriptor (protobufjs) → ${VALIDATOR_DESCRIPTOR#$ROOT/}"
mkdir -p "$(dirname "$VALIDATOR_DESCRIPTOR")"
( cd "$ROOT/validator" && "$BUN" x pbjs -t json --keep-case \
    -o "$VALIDATOR_DESCRIPTOR" \
    "$HERMES_PROTO" "$VALIDATOR_PROTO" )
echo "  ✓ ${VALIDATOR_DESCRIPTOR#$ROOT/}"

if [ "$SKIP_GDSCRIPT" = "1" ]; then
  echo "→ [2/2] GDScript bindings — SKIPPED (--skip-gdscript)"
  echo "✓ JS descriptor regenerated."
  exit 0
fi

if [ ! -x "$GODOT" ]; then
  echo "→ [2/2] GDScript bindings — SKIPPED: Godot not found at '$GODOT'"
  echo "  Set GODOT=/path/to/Godot and re-run, or pass --skip-gdscript."
  exit 0
fi

echo "→ [2/2] GDScript bindings (godobuf) → game/net/proto/"
# godobuf's --input must be an OS path (not res://); --output is res://.
# Codegen can exit 0 even on failure, so assert the success line per file.
gen_gd() {
  local proto="$1" out="$2"
  local log
  log="$("$GODOT" --headless --path "$ROOT/game" -s res://addons/godobuf/godobuf_cmdln.gd \
    --input="$proto" --output="$out" 2>&1)"
  if ! grep -q "Compiled .* to '$out'" <<<"$log"; then
    echo "$log" | grep -iE "error|failed" || echo "$log" | tail -5
    echo "✗ godobuf failed for $proto"
    exit 1
  fi
  echo "  ✓ $out"
}
gen_gd "$HERMES_PROTO"    "res://net/proto/hermes_envelope_pb.gd"
gen_gd "$VALIDATOR_PROTO" "res://net/proto/validator_pb.gd"

echo "✓ JS descriptor and GDScript bindings regenerated."
echo "  Next: re-run the parity/wire verifier:"
echo "    godot --headless --path game --script res://tools/verify_hermes_proto.gd"
