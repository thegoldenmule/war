/**
 * mcp.ts — Model Context Protocol debug surface at POST /mcp.
 *
 * Exposes the validator's authoritative state to MCP clients (e.g. the godot-ai
 * / agent tooling) for debugging matches without going through the game client.
 * Implements a minimal JSON-RPC 2.0 MCP server over a single POST endpoint:
 * `initialize`, `tools/list`, and `tools/call`.
 *
 * Tools:
 *   - list_matches()                      -> all match summaries
 *   - get_match_state({ match_id })       -> canonical state JSON for a match
 *   - simulate_action({ match_id, action_json }) -> dry-run engine verdict (no persist)
 *   - clear_match({ match_id })           -> delete a match
 *
 * These are read/debug oriented; simulate_action never mutates the authoritative
 * timeline (it delegates to ValidatorService.simulateAction).
 */

import { validatorService, type ValidatorService } from "./service.ts";

/** Minimal JSON-RPC 2.0 request shape. */
interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

/** MCP tool descriptor (input schema is JSON Schema). */
interface ToolDef {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

const SERVER_INFO = { name: "war-validator", version: "0.1.0" } as const;
const PROTOCOL_VERSION = "2024-11-05";

/** Declared tool catalog (returned by tools/list). */
const TOOLS: ToolDef[] = [
  {
    name: "list_matches",
    description: "List all live/known matches with phase, hash, and applied-action counts.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "get_match_state",
    description: "Return the authoritative canonical-JSON state for one match.",
    inputSchema: {
      type: "object",
      properties: { match_id: { type: "string" } },
      required: ["match_id"],
      additionalProperties: false,
    },
  },
  {
    name: "simulate_action",
    description:
      "Dry-run an action against a match's current state via @war/logic WITHOUT persisting. " +
      "Returns the engine verdict, resulting state JSON, and hash.",
    inputSchema: {
      type: "object",
      properties: {
        match_id: { type: "string" },
        action_json: { type: "string", description: "Canonical-JSON action { type, ...args }" },
      },
      required: ["match_id", "action_json"],
      additionalProperties: false,
    },
  },
  {
    name: "clear_match",
    description: "Delete a match from the store. Returns whether a match was removed.",
    inputSchema: {
      type: "object",
      properties: { match_id: { type: "string" } },
      required: ["match_id"],
      additionalProperties: false,
    },
  },
];

/** Wrap a value as an MCP text-content tool result. */
function textResult(value: unknown) {
  return {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
  };
}

/** Execute a named tool against the service. */
function callTool(
  name: string,
  args: Record<string, unknown>,
  svc: ValidatorService,
): unknown {
  switch (name) {
    case "list_matches":
      return textResult(svc.listMatches());
    case "get_match_state":
      return textResult(svc.getMatchStateJson(String(args.match_id ?? "")));
    case "simulate_action":
      return textResult(
        svc.simulateAction(String(args.match_id ?? ""), String(args.action_json ?? "")),
      );
    case "clear_match":
      return textResult({ removed: svc.clearMatch(String(args.match_id ?? "")) });
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

/**
 * Handle a single MCP JSON-RPC request. Pure-ish: returns the JSON-RPC response
 * object (or null for notifications). Used by the /mcp Hono route.
 */
export function handleMcpRequest(
  body: JsonRpcRequest,
  svc: ValidatorService = validatorService,
): Record<string, unknown> | null {
  const { id, method, params } = body;

  const ok = (result: unknown) => ({ jsonrpc: "2.0" as const, id: id ?? null, result });
  const err = (code: number, message: string) => ({
    jsonrpc: "2.0" as const,
    id: id ?? null,
    error: { code, message },
  });

  try {
    switch (method) {
      case "initialize":
        return ok({
          protocolVersion: PROTOCOL_VERSION,
          serverInfo: SERVER_INFO,
          capabilities: { tools: {} },
        });
      case "notifications/initialized":
        return null; // notification, no response
      case "tools/list":
        return ok({ tools: TOOLS });
      case "tools/call": {
        const name = String(params?.name ?? "");
        const args = (params?.arguments as Record<string, unknown>) ?? {};
        return ok(callTool(name, args, svc));
      }
      default:
        return err(-32601, `method not found: ${method}`);
    }
  } catch (e) {
    // -32603: internal error; surface as an MCP tool error result when possible.
    return err(-32603, (e as Error)?.message ?? "internal error");
  }
}

export { TOOLS as mcpTools };
