# War validator — BYOSnap container image.
#
# Build context MUST be the validator/ workspace root (this directory) so that
# Bun can resolve the `workspace:*` deps that link src/validator -> src/logic.
# Build from repo root with:
#   docker build -f validator/Dockerfile validator/
#
# The deployed container listens on :8080 (HTTP) and :8081 (gRPC) and serves an
# UNPREFIXED /health endpoint (Snapser BYOSnap health probe; the base path
# /v1/byosnap-validator is added by the gateway, not by the health route).

# --- deps stage: install the full workspace so workspace:* resolves ---
FROM oven/bun:1 AS deps
WORKDIR /app

# Copy the manifests first for a cached install layer.
COPY package.json bun.lockb* ./
COPY src/logic/package.json ./src/logic/package.json
COPY src/validator/package.json ./src/validator/package.json

# Install across the whole workspace (links src/validator -> src/logic).
RUN bun install --frozen-lockfile || bun install

# --- build stage: bring in sources and produce the logic build ---
FROM deps AS build
WORKDIR /app
COPY . .
# Build the deterministic logic package (parity engine) used by the validator.
RUN bun run build

# --- runtime stage ---
FROM oven/bun:1 AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    HTTP_PORT=8080 \
    GRPC_PORT=8081

# Bring over the resolved workspace + built sources.
COPY --from=build /app /app

# HTTP gateway/health + Hermes WS on 8080; gRPC ValidatorService on 8081.
EXPOSE 8080
EXPOSE 8081

# BYOSnap health probe hits the unprefixed /health on the HTTP port.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD bun -e "fetch('http://127.0.0.1:'+(process.env.HTTP_PORT||8080)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Entrypoint = the validator service (src/validator owns the start script).
WORKDIR /app/src/validator
CMD ["bun", "run", "start"]
