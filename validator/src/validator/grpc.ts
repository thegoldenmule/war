/**
 * grpc.ts — @grpc/grpc-js server for war.validator.v1.ValidatorService.
 *
 * Binds the three RPCs (InitMatch, ValidateAction, CompleteMatch) to the
 * authoritative ValidatorService (service.ts) on GRPC_PORT (:8081 local).
 * State + actions cross the wire as canonical-JSON strings per proto.ts.
 *
 * Wire mapping (expected proto field names; see validator.proto):
 *   InitMatch(InitMatchRequest{ seed, player_id })
 *     -> InitMatchResponse{ match_id, player_id, state_json, hash }
 *   ValidateAction(ValidateActionRequest{ match_id, player_id, action_json, predicted_hash })
 *     -> ValidateActionResponse{ ok, hash_matched, authoritative_state_json, hash, events_json, error }
 *   CompleteMatch(CompleteMatchRequest{ match_id, player_id })
 *     -> CompleteMatchResponse{ match_id, final_phase, hash }
 */

import { loadValidatorProto } from "./proto.ts";
import { ServiceError, validatorService, type ValidatorService } from "./service.ts";
import { PlayerBindingError, MatchNotFoundError } from "./store/match-store.ts";
import type { ValidateResult } from "./types.ts";

/** Map a thrown service/store error to a gRPC status code + message. */
function toGrpcError(err: unknown): { code: number; message: string } {
  // grpc.status numeric codes (avoid importing grpc just for the enum here):
  // INVALID_ARGUMENT=3, NOT_FOUND=5, PERMISSION_DENIED=7, FAILED_PRECONDITION=9, UNKNOWN=2
  if (err instanceof MatchNotFoundError) return { code: 5, message: err.message };
  if (err instanceof PlayerBindingError) return { code: 7, message: err.message };
  if (err instanceof ServiceError) {
    const map: Record<string, number> = {
      INVALID_ARGUMENT: 3,
      NOT_FOUND: 5,
      PERMISSION_DENIED: 7,
      FAILED_PRECONDITION: 9,
    };
    return { code: map[err.code] ?? 2, message: err.message };
  }
  return { code: 2, message: (err as Error)?.message ?? "internal error" };
}

/** Serialize a ValidateResult into the response proto's flat fields. */
function toValidateResponse(r: ValidateResult) {
  return {
    ok: r.ok,
    hash_matched: r.hashMatched,
    authoritative_state_json: r.authoritativeStateJson,
    hash: r.hash,
    events_json: JSON.stringify(r.events),
    error: r.error,
  };
}

/**
 * Build the gRPC handler object that proto-loader binds to the service.
 * Each handler is a thin adapter: read request fields, call the authoritative
 * ValidatorService, write response fields. No rules here.
 */
export function makeHandlers(svc: ValidatorService = validatorService) {
  // grpc callback signature: (call, callback) => void
  type Call = { request: Record<string, unknown> };
  type Cb = (err: unknown, value?: unknown) => void;

  return {
    InitMatch(call: Call, callback: Cb) {
      try {
        const seed = String(call.request.seed ?? "");
        const playerId = String(call.request.player_id ?? "");
        const res = svc.initMatch(seed, playerId);
        callback(null, {
          match_id: res.matchId,
          player_id: res.playerId,
          state_json: res.stateJson,
          hash: res.hash,
        });
      } catch (e) {
        callback(toGrpcError(e));
      }
    },

    ValidateAction(call: Call, callback: Cb) {
      try {
        const matchId = String(call.request.match_id ?? "");
        const playerId = String(call.request.player_id ?? "");
        const actionJson = String(call.request.action_json ?? "");
        const predictedHash = String(call.request.predicted_hash ?? "");
        const res = svc.validateAction(matchId, playerId, actionJson, predictedHash);
        callback(null, toValidateResponse(res));
      } catch (e) {
        callback(toGrpcError(e));
      }
    },

    CompleteMatch(call: Call, callback: Cb) {
      try {
        const matchId = String(call.request.match_id ?? "");
        const playerId = String(call.request.player_id ?? "");
        const res = svc.completeMatch(matchId, playerId);
        callback(null, {
          match_id: res.matchId,
          final_phase: res.finalPhase,
          hash: res.hash,
        });
      } catch (e) {
        callback(toGrpcError(e));
      }
    },
  };
}

/**
 * Start the gRPC server on `port`. Resolves once bound. Returns a stop fn.
 *
 * Loads the proto descriptor lazily (proto.ts); if the proto file is not yet
 * committed this throws — index.ts treats gRPC as optional during the skeleton
 * phase so the HTTP/MCP surfaces still come up. The handler wiring itself is
 * real and ready.
 */
export async function startGrpcServer(
  port: number,
  svc: ValidatorService = validatorService,
): Promise<{ stop: () => Promise<void> }> {
  const grpc = await import("@grpc/grpc-js");
  const loaded = (await loadValidatorProto()) as Record<string, unknown>;

  // Navigate war.validator.v1.ValidatorService from the loaded package.
  // TODO(skeleton): confirm the exact package path once validator.proto lands.
  const pkg = ((loaded.war as Record<string, unknown>)?.validator as Record<string, unknown>)
    ?.v1 as Record<string, unknown> | undefined;
  const ServiceDef = pkg?.ValidatorService as { service: unknown } | undefined;
  if (!ServiceDef) {
    throw new Error("war.validator.v1.ValidatorService not found in proto descriptor");
  }

  const server = new grpc.Server();
  server.addService(
    (ServiceDef as { service: grpc.ServiceDefinition }).service,
    makeHandlers(svc) as unknown as grpc.UntypedServiceImplementation,
  );

  await new Promise<void>((res, rej) => {
    server.bindAsync(`0.0.0.0:${port}`, grpc.ServerCredentials.createInsecure(), (err) => {
      if (err) rej(err);
      else res();
    });
  });

  return {
    stop: () =>
      new Promise<void>((resolveStop) => {
        server.tryShutdown(() => resolveStop());
      }),
  };
}
