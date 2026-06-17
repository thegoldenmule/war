/**
 * routes/health.ts — liveness + status Hono router.
 *
 *   GET /health      -> { status: "ok" }            (cheap liveness probe)
 *   GET /api/status  -> service identity, ports, match count, uptime
 *
 * Mounted at the app root in index.ts.
 */

import { Hono } from "hono";
import { config } from "../config.ts";
import { matchStore } from "../store/match-store.ts";

const startedAt = Date.now();

export const healthRouter = new Hono();

/** Liveness: returns 200 with a tiny body. Used by orchestration health checks. */
healthRouter.get("/health", (c) => c.json({ status: "ok" }));

/** Status: richer snapshot for dashboards / debugging. */
healthRouter.get("/api/status", (c) =>
  c.json({
    service: "@war/validator",
    version: "0.1.0",
    mode: config.isLocal ? "local" : "gateway",
    ports: { http: config.httpPort, grpc: config.grpcPort },
    matches: matchStore.size,
    uptimeMs: Date.now() - startedAt,
  }),
);
