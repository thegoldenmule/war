/**
 * routes/match.ts — read-only match history endpoints (Hono router).
 *
 *   GET /api/matches            -> list of match summaries
 *   GET /api/matches/:id        -> one match summary
 *   GET /api/matches/:id/state  -> authoritative canonical state JSON
 *
 * These are debug/observability reads over the authoritative store. They do NOT
 * mutate state and do NOT enforce player binding (they are local/operator
 * surfaces); mutation always goes through gRPC or the Hermes WS path, which do
 * enforce identity. Mounted at the app root in index.ts.
 */

import { Hono } from "hono";
import { validatorService } from "../service.ts";
import { MatchNotFoundError } from "../store/match-store.ts";

export const matchRouter = new Hono();

/** All known matches (summaries only). */
matchRouter.get("/api/matches", (c) => c.json({ matches: validatorService.listMatches() }));

/** One match summary. */
matchRouter.get("/api/matches/:id", (c) => {
  const id = c.req.param("id");
  try {
    return c.json(validatorService.getMatchSummary(id));
  } catch (e) {
    if (e instanceof MatchNotFoundError) return c.json({ error: e.message }, 404);
    throw e;
  }
});

/**
 * Authoritative canonical-JSON state for one match. Served as application/json
 * by re-parsing the canonical string so HTTP clients get a normal JSON body;
 * the canonical string itself remains the hash domain and is what crosses the
 * gRPC/WS wire.
 */
matchRouter.get("/api/matches/:id/state", (c) => {
  const id = c.req.param("id");
  try {
    const stateJson = validatorService.getMatchStateJson(id);
    return c.body(stateJson, 200, { "content-type": "application/json" });
  } catch (e) {
    if (e instanceof MatchNotFoundError) return c.json({ error: e.message }, 404);
    throw e;
  }
});
