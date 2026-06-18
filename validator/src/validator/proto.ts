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
import protobuf from "protobufjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Repo proto roots. From validator/src/validator/ the committed protos live at
 * validator/protos/ (../../protos).
 */
export const PROTO_ROOT = resolve(__dirname, "../../protos");

/** war.validator.v1.ValidatorService definition (imports the messages). */
export const VALIDATOR_PROTO_PATH = resolve(
  PROTO_ROOT,
  "war/validator/v1/validator.proto",
);

/**
 * war.validator.v1 request/response MESSAGES (standalone, no imports). The Hermes
 * codec loads this directly so protobufjs needs no import-resolution (it carries
 * the InitMatch/ValidateAction/CompleteMatch message types the wire serializes).
 */
export const VALIDATOR_MESSAGES_PROTO_PATH = resolve(
  PROTO_ROOT,
  "war/validator/v1/validator_messages.proto",
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
export async function loadHermesRoot(): Promise<protobuf.Root> {
  return protobuf.load(HERMES_PROTO_PATH);
}

// ---------------------------------------------------------------------------
// Hermes wire codec (binary protobuf). The client (godobuf) frames a
// ClientMessage whose snap-api-proxy payload is a serialized ValidatorService
// request; we decode it, route to the service, and frame a ServerMessage whose
// payload is the serialized response. State/actions ride as canonical-JSON
// strings inside those messages — this codec never parses the hash domain.
// ---------------------------------------------------------------------------

/** Short RPC name from either "InitMatch" or "pkg.Service/InitMatch". */
function shortMethod(method: string): string {
  return method.includes("/") ? (method.split("/").pop() ?? method) : method;
}

export interface HermesCodec {
  /** Decode an inbound ClientMessage frame -> correlation id, RPC name, request bytes. */
  decodeClient(bytes: Uint8Array): { requestId: string; method: string; payload: Uint8Array };
  /** Decode a request payload for `method` into a plain (snake_case) args object. */
  decodeRequestArgs(method: string, payload: Uint8Array): Record<string, unknown>;
  /** Encode a response object (snake_case fields) for `method` to proto bytes. */
  encodeResponse(method: string, data: Record<string, unknown>): Uint8Array;
  /** Frame a ServerMessage around a response payload (status_code 0 == OK). */
  encodeServer(requestId: string, statusCode: number, statusMessage: string, payload: Uint8Array): Uint8Array;
}

let codecPromise: Promise<HermesCodec> | null = null;

/** Load (once, cached) the protobufjs types for the Hermes envelope + ValidatorService. */
export function getHermesCodec(): Promise<HermesCodec> {
  if (!codecPromise) codecPromise = buildCodec();
  return codecPromise;
}

async function buildCodec(): Promise<HermesCodec> {
  // Load both protos into one root so envelope + RPC messages resolve together.
  // Use the standalone MESSAGES proto (no imports) to avoid protobufjs's
  // file-relative import resolution choking on the service def's root-relative import.
  //
  // keepCase MATTERS: protobufjs camelCases field names by default (api_proxy ->
  // apiProxy, request_id -> requestId). Our codec, routeRequest, and the godobuf
  // client all speak snake_case (the .proto names), and the gRPC proto-loader path
  // also sets keepCase — so we keep it here too, or every multi-word field reads
  // as undefined and "ClientMessage missing api_proxy body" is thrown.
  const root = new protobuf.Root();
  await root.load([HERMES_PROTO_PATH, VALIDATOR_MESSAGES_PROTO_PATH], { keepCase: true });
  const ClientMessage = root.lookupType("hermes.ClientMessage");
  const ServerMessage = root.lookupType("hermes.ServerMessage");
  const reqType: Record<string, protobuf.Type> = {
    InitMatch: root.lookupType("war.validator.v1.InitMatchRequest"),
    ValidateAction: root.lookupType("war.validator.v1.ValidateActionRequest"),
    CompleteMatch: root.lookupType("war.validator.v1.CompleteMatchRequest"),
  };
  const resType: Record<string, protobuf.Type> = {
    InitMatch: root.lookupType("war.validator.v1.InitMatchResponse"),
    ValidateAction: root.lookupType("war.validator.v1.ValidateActionResponse"),
    CompleteMatch: root.lookupType("war.validator.v1.CompleteMatchResponse"),
  };

  return {
    decodeClient(bytes) {
      const msg = ClientMessage.toObject(ClientMessage.decode(bytes), { defaults: true }) as Record<string, unknown>;
      const api = msg.api_proxy as Record<string, unknown> | undefined;
      if (!api) throw new Error("ClientMessage missing api_proxy body");
      return {
        requestId: String(api.request_id ?? ""),
        method: shortMethod(String(api.api_method ?? "")),
        payload: (api.payload as Uint8Array) ?? new Uint8Array(),
      };
    },
    decodeRequestArgs(method, payload) {
      const t = reqType[shortMethod(method)];
      if (!t) throw new Error(`unknown method: ${method}`);
      return t.toObject(t.decode(payload), { defaults: true }) as Record<string, unknown>;
    },
    encodeResponse(method, data) {
      const t = resType[shortMethod(method)];
      if (!t) throw new Error(`unknown method: ${method}`);
      const err = t.verify(data);
      if (err) throw new Error(`response verify failed for ${method}: ${err}`);
      return t.encode(t.create(data)).finish();
    },
    encodeServer(requestId, statusCode, statusMessage, payload) {
      const msg = ServerMessage.create({
        type: "snap-api-proxy",
        api_proxy: {
          request_id: requestId,
          status_code: statusCode,
          status_message: statusMessage,
          payload,
        },
      });
      return ServerMessage.encode(msg).finish();
    },
  };
}
