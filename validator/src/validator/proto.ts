/**
 * proto.ts — protobuf descriptor loading + the canonical-JSON-in-string rule.
 *
 * THE HASH-DOMAIN RULE (do not violate):
 *   Game state and actions are NEVER modeled as structured proto messages.
 *   They travel as canonical-JSON STRINGS inside proto `string` fields, because
 *   the determinism hash is computed over that exact canonical string. If we
 *   re-modeled them as proto messages, proto's field ordering / default-value
 *   elision / number formatting would diverge from canonical_stringify and the
 *   GDScript<->TS parity would break. So: state/action stay strings end-to-end.
 *
 * What this module owns:
 *   - resolving proto file paths under validator/protos/,
 *   - loading them with @grpc/proto-loader for the gRPC server (grpc.ts),
 *   - exposing a protobufjs Root for the Hermes envelope (hermes-ws.ts),
 *   when those descriptors are generated/committed.
 */

import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Repo proto roots. From validator/src/validator/ the committed protos live at
 * validator/protos/ (../../protos).
 */
export const PROTO_ROOT = resolve(__dirname, "../../protos");

/** war.validator.v1.ValidatorService definition. */
export const VALIDATOR_PROTO_PATH = resolve(
  PROTO_ROOT,
  "war/validator/v1/validator.proto",
);

/** Snapser Hermes envelope (ClientMessage / ServerMessage). */
export const HERMES_PROTO_PATH = resolve(PROTO_ROOT, "hermes/hermes_envelope.proto");

/** Standard include dirs handed to proto-loader so imports resolve. */
export const PROTO_INCLUDE_DIRS = [PROTO_ROOT];

/**
 * proto-loader options shared by the gRPC binding. `longs: String` keeps
 * 64-bit ints lossless; we keep `keepCase` so the .proto field names match the
 * wire/JSON the rest of the system uses.
 */
export const PROTO_LOADER_OPTIONS = {
  keepCase: true,
  longs: String,
  enums: String,
  defaults: true,
  oneofs: true,
  includeDirs: PROTO_INCLUDE_DIRS,
} as const;

/**
 * Load the ValidatorService package definition for @grpc/grpc-js.
 *
 * TODO(skeleton): this requires validator/protos/war/validator/v1/validator.proto
 * to be committed (authored by the proto/contract agent). When present, grpc.ts
 * calls this and binds the service. We import @grpc/proto-loader lazily so the
 * service can boot (HTTP/MCP/health) even before the proto lands.
 */
export async function loadValidatorProto(): Promise<unknown> {
  const protoLoader = await import("@grpc/proto-loader");
  const grpc = await import("@grpc/grpc-js");
  const packageDefinition = protoLoader.loadSync(VALIDATOR_PROTO_PATH, PROTO_LOADER_OPTIONS);
  return grpc.loadPackageDefinition(packageDefinition);
}

/**
 * Load the Hermes envelope descriptor as a protobufjs Root for encode/decode in
 * hermes-ws.ts.
 *
 * TODO(skeleton): point at the committed protos/hermes/hermes_envelope.proto
 * (or a generated descriptor) once available.
 */
export async function loadHermesRoot(): Promise<unknown> {
  const protobuf = await import("protobufjs");
  return protobuf.load(HERMES_PROTO_PATH);
}
