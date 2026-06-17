/**
 * config.ts — environment loading + validation for @war/validator.
 *
 * Loaded once at process start (see index.ts). Reads from `process.env`
 * (Bun auto-loads a sibling `.env`; see .env.example for the contract).
 * Any structural problem (non-numeric port, out-of-range) throws here so the
 * service fails fast at boot rather than at first request.
 */

/** Fully-resolved, validated runtime configuration. Immutable after load. */
export interface ValidatorConfig {
  /** HTTP port for the Hono app (health / status / MCP / Hermes WS upgrade). */
  readonly httpPort: number;
  /** gRPC port for war.validator.v1.ValidatorService. */
  readonly grpcPort: number;
  /**
   * Shared secret used to verify gateway-stamped identity in production.
   * Empty string => local "trusted token" mode (?token=<player-id>).
   */
  readonly sharedSecret: string;
  /** True when no shared secret is configured (local dev convenience). */
  readonly isLocal: boolean;
}

/** Parse a port-like env var, enforcing the 1..65535 range. */
function parsePort(name: string, raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > 65535) {
    throw new Error(`config: ${name} must be an integer in 1..65535, got "${raw}"`);
  }
  return n;
}

/**
 * Build the config from a raw env bag (defaults to `process.env`).
 * Pass an explicit bag in tests to avoid mutating the real environment.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): ValidatorConfig {
  const httpPort = parsePort("PORT", env.PORT, 5555);
  const grpcPort = parsePort("GRPC_PORT", env.GRPC_PORT, 8081);
  const sharedSecret = (env.VALIDATOR_SHARED_SECRET ?? "").trim();

  if (httpPort === grpcPort) {
    throw new Error(`config: PORT and GRPC_PORT must differ (both ${httpPort})`);
  }

  return Object.freeze({
    httpPort,
    grpcPort,
    sharedSecret,
    isLocal: sharedSecret === "",
  });
}

/** Process-wide singleton, resolved at import time. */
export const config: ValidatorConfig = loadConfig();
