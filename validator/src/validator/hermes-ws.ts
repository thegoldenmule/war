/**
 * hermes-ws.ts — local Snapser Hermes-envelope WebSocket endpoint.
 *
 * The deployed client talks to Snapser's gateway, which forwards a
 * snap-api-proxy message wrapped in a Hermes envelope
 * (ClientMessage / ServerMessage from protos/hermes/hermes_envelope.proto).
 * Locally we serve the IDENTICAL envelope at:
 *
 *     ws://localhost:5555/hermes/ws?token=<player-id>
 *
 * so the Godot client has ONE codepath whether it runs against the gateway or
 * a dev validator. This module unwraps the envelope, routes the inner request
 * to the SAME ValidatorService methods the gRPC path uses, and wraps the reply.
 *
 * AUTH (local): the ?token query param is the self-stamped player id. In
 * production the gateway stamps a verified User-Id and Snapser binds it to the
 * player; our service then treats that id as authoritative. config.isLocal
 * selects between the two trust models.
 *
 * This file implements the connection lifecycle (Bun WebSocket handler shape)
 * with the envelope codec stubbed behind TODO(skeleton) until the Hermes
 * descriptor is wired via proto.ts.
 */

import type { Server, ServerWebSocket } from "bun";
import { config } from "./config.ts";
import { type HermesCodec } from "./proto.ts";
import { ServiceError, validatorService, type ValidatorService } from "./service.ts";
import { MatchNotFoundError, PlayerBindingError } from "./store/match-store.ts";

/** Per-socket context attached at upgrade. */
interface WsData {
  /** Resolved player id (from ?token= locally, gateway header in prod). */
  playerId: string;
  /** Connection id for logging. */
  connId: string;
}

/** A decoded inner request from the Hermes envelope (snap-api-proxy payload). */
interface InnerRequest {
  /** Logical method name: "InitMatch" | "ValidateAction" | "CompleteMatch". */
  method: string;
  /** Correlation id echoed back so the client can match replies. */
  requestId: string;
  /** Method args as a plain object (canonical-JSON strings inside). */
  args: Record<string, unknown>;
}

/** A reply to be wrapped back into a Hermes ServerMessage. */
interface InnerReply {
  requestId: string;
  ok: boolean;
  /** Method result payload (flat object; state/action remain JSON strings). */
  data?: Record<string, unknown>;
  error?: string;
}

/**
 * Extract the player id for an upgrade request.
 * Local: read ?token=. Production: read the gateway-stamped User-Id header and
 * verify against config.sharedSecret. Returns null to reject the upgrade.
 */
export function resolvePlayerId(req: Request): string | null {
  const url = new URL(req.url);
  if (config.isLocal) {
    const token = url.searchParams.get("token");
    return token && token.trim() !== "" ? token : null;
  }
  // TODO(skeleton): verify gateway User-Id against VALIDATOR_SHARED_SECRET.
  const userId = req.headers.get("User-Id");
  return userId && userId.trim() !== "" ? userId : null;
}

/**
 * Route a decoded request to the authoritative ValidatorService. This is the
 * SAME logical surface as grpc.ts — identical method names + semantics — so the
 * gateway and local paths are behaviorally one path.
 */
export function routeRequest(
  req: InnerRequest,
  playerId: string,
  svc: ValidatorService = validatorService,
): InnerReply {
  try {
    switch (req.method) {
      case "InitMatch": {
        const seed = String(req.args.seed ?? "");
        const res = svc.initMatch(seed, playerId);
        return {
          requestId: req.requestId,
          ok: true,
          data: {
            match_id: res.matchId,
            player_id: res.playerId,
            state_json: res.stateJson,
            hash: res.hash,
          },
        };
      }
      case "ValidateAction": {
        const res = svc.validateAction(
          String(req.args.match_id ?? ""),
          playerId,
          String(req.args.action_json ?? ""),
          String(req.args.predicted_hash ?? ""),
        );
        return {
          requestId: req.requestId,
          ok: true,
          data: {
            ok: res.ok,
            hash_matched: res.hashMatched,
            authoritative_state_json: res.authoritativeStateJson,
            hash: res.hash,
            events_json: JSON.stringify(res.events),
            error: res.error,
          },
        };
      }
      case "CompleteMatch": {
        const res = svc.completeMatch(String(req.args.match_id ?? ""), playerId);
        return {
          requestId: req.requestId,
          ok: true,
          data: { match_id: res.matchId, final_phase: res.finalPhase, hash: res.hash },
        };
      }
      default:
        return { requestId: req.requestId, ok: false, error: `unknown method: ${req.method}` };
    }
  } catch (e) {
    const msg =
      e instanceof ServiceError ||
      e instanceof MatchNotFoundError ||
      e instanceof PlayerBindingError
        ? e.message
        : ((e as Error)?.message ?? "internal error");
    return { requestId: req.requestId, ok: false, error: msg };
  }
}

/**
 * Bun WebSocket handlers for the Hermes endpoint. Wire these into the server's
 * `websocket` option (see index.ts), and perform the upgrade in `fetch` on the
 * /hermes/ws path. Kept as a factory so tests can inject a service.
 */
export function makeHermesWebSocketHandlers(
  codec: HermesCodec,
  svc: ValidatorService = validatorService,
) {
  return {
    open(ws: ServerWebSocket<WsData>) {
      console.log(`[hermes-ws] open conn=${ws.data.connId} player=${ws.data.playerId}`);
    },

    message(ws: ServerWebSocket<WsData>, raw: string | Buffer) {
      // Binary Hermes frames in, binary out. (A string frame is tolerated by
      // decoding its bytes — but the client always sends binary protobuf.)
      const bytes = typeof raw === "string" ? Buffer.from(raw) : raw;
      let out: Uint8Array;
      try {
        const { requestId, method, payload } = codec.decodeClient(bytes);
        let reply: InnerReply;
        try {
          const args = codec.decodeRequestArgs(method, payload);
          reply = routeRequest({ method, requestId, args }, ws.data.playerId, svc);
        } catch (e) {
          reply = { requestId, ok: false, error: (e as Error).message };
        }
        if (reply.ok) {
          out = codec.encodeServer(requestId, 0, "", codec.encodeResponse(method, reply.data ?? {}));
        } else {
          // Transport/routing failure (unknown method, malformed payload): status_code
          // != 0 with no body. (A domain rejection — illegal action — is ok:true here
          // with the rejection carried inside the response message's own `ok` field.)
          out = codec.encodeServer(requestId, 13, reply.error ?? "internal error", new Uint8Array());
        }
      } catch (e) {
        out = codec.encodeServer("", 13, `bad frame: ${(e as Error).message}`, new Uint8Array());
      }
      ws.send(out);
    },

    close(ws: ServerWebSocket<WsData>, code: number) {
      console.log(`[hermes-ws] close conn=${ws.data.connId} code=${code}`);
    },
  };
}

/**
 * Attempt to upgrade an incoming /hermes/ws request. Returns true if handled
 * (upgraded or rejected) so the HTTP layer can stop processing. Call from the
 * Bun server `fetch` before handing off to Hono.
 */
export function tryHermesUpgrade(req: Request, server: Server): Response | undefined {
  const url = new URL(req.url);
  if (url.pathname !== "/hermes/ws") return undefined;

  const playerId = resolvePlayerId(req);
  if (!playerId) {
    return new Response("missing or invalid token", { status: 401 });
  }

  const data: WsData = { playerId, connId: crypto.randomUUID().slice(0, 8) };
  const ok = server.upgrade(req, { data });
  if (ok) return undefined; // Bun sends the 101 itself; stop further handling.
  return new Response("websocket upgrade failed", { status: 400 });
}

export type { InnerReply, InnerRequest, WsData };
