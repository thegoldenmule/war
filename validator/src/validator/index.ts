/**
 * index.ts — @war/validator entry point.
 *
 * Boots the authoritative validation service:
 *   1. builds the Hono app (health, status, match history, MCP),
 *   2. starts the gRPC server for war.validator.v1.ValidatorService (best-effort
 *      during the skeleton phase — see grpc.ts / proto.ts TODOs),
 *   3. serves over Bun's HTTP+WebSocket server so the Hermes WS endpoint
 *      (/hermes/ws) and the Hono routes share ONE port (PORT).
 *
 * Run:  bun index.ts   (or `bun --watch index.ts` for dev).
 *
 * The whole service is a thin authoritative shell around @war/logic: it never
 * implements rules, it re-runs the shared deterministic engine and compares
 * hashes (see service.ts).
 */

import { Hono } from "hono";
import { config } from "./config.ts";
import { startGrpcServer } from "./grpc.ts";
import { handleMcpRequest } from "./mcp.ts";
import { makeHermesWebSocketHandlers, tryHermesUpgrade } from "./hermes-ws.ts";
import { getHermesCodec } from "./proto.ts";
import { healthRouter } from "./routes/health.ts";
import { matchRouter } from "./routes/match.ts";

/** Construct the Hono application with all HTTP routers mounted. */
export function buildApp(): Hono {
  const app = new Hono();

  app.route("/", healthRouter);
  app.route("/", matchRouter);

  // MCP JSON-RPC debug surface.
  app.post("/mcp", async (c) => {
    const body = await c.req.json().catch(() => null);
    if (!body || typeof body !== "object") {
      return c.json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } }, 400);
    }
    const res = handleMcpRequest(body as never);
    if (res === null) return c.body(null, 204); // notification, no response
    return c.json(res);
  });

  app.notFound((c) => c.json({ error: "not found" }, 404));

  return app;
}

/** Start the full service. Returns handles for graceful shutdown (tests/ops). */
export async function start() {
  const app = buildApp();
  // Preload the Hermes protobuf codec once so the (sync) WS message handler can
  // encode/decode binary frames without awaiting per message.
  const codec = await getHermesCodec();
  const hermesHandlers = makeHermesWebSocketHandlers(codec);

  // Bun's native server lets the Hermes WS upgrade and Hono coexist on one port.
  const server = Bun.serve({
    port: config.httpPort,
    fetch(req, srv) {
      // Hermes WS upgrade gets first crack at /hermes/ws.
      const upgraded = tryHermesUpgrade(req, srv);
      if (upgraded !== undefined) return upgraded;
      // Everything else -> Hono.
      return app.fetch(req, { server: srv } as never);
    },
    websocket: hermesHandlers,
  });

  // gRPC is best-effort while protos may be unlanded; never block HTTP boot.
  let grpcHandle: { stop: () => Promise<void> } | null = null;
  try {
    grpcHandle = await startGrpcServer(config.grpcPort);
    console.log(`[grpc]  war.validator.v1.ValidatorService on :${config.grpcPort}`);
  } catch (e) {
    console.warn(
      `[grpc]  not started (${(e as Error).message}). ` +
        "HTTP/WS/MCP are up; gRPC awaits the committed proto descriptor.",
    );
  }

  console.log(`[http]  @war/validator listening on :${config.httpPort} (${config.isLocal ? "local" : "gateway"} mode)`);
  console.log(`        GET  /health`);
  console.log(`        GET  /api/status`);
  console.log(`        GET  /api/matches            (history)`);
  console.log(`        GET  /api/matches/:id        (summary)`);
  console.log(`        GET  /api/matches/:id/state  (canonical state)`);
  console.log(`        POST /mcp                    (MCP debug)`);
  console.log(`        WS   /hermes/ws?token=<player-id>  (Hermes envelope)`);

  const shutdown = async () => {
    server.stop();
    if (grpcHandle) await grpcHandle.stop();
  };
  return { server, shutdown };
}

// Run when invoked directly (bun index.ts), not when imported by tests.
if (import.meta.main) {
  start().catch((e) => {
    console.error("[fatal] failed to start @war/validator:", e);
    process.exit(1);
  });
}
