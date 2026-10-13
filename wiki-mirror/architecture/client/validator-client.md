# Validator Client

**Status:** current

## Kind
component

## Summary
The client side of the validation protocol: a three-layer stack (WarValidatorClient over WarHermesClient over WarSnapserAuth) that lets the optimistic in-game match reconcile against the authoritative validator. It exposes the validator's gRPC surface as friendly async methods, multiplexes them over a single Hermes protobuf-envelope WebSocket, and supplies the player identity that names actions on the wire.

## Purpose
It is the client's bridge to authority. The match plays *optimistically* — applying each action locally for instant feedback and computing a predicted state hash — then submits that action and predicted hash to the validator and *reconciles* against the verdict. This component carries that contract end to end: it establishes the server's starting state for a seed (init_match), gets the authoritative verdict for each action (validate_action), and reports terminal results (complete_match), all while keeping a single codepath across local emulation and the production Snapser gateway and degrading gracefully to optimistic-only when no transport is attached.

## Design notes
Layering and dependency direction: WarMatch sits above WarValidatorClient (RPC semantics + reconcile decision), which sits above WarHermesClient (envelope framing + socket lifecycle), which sits above WebSocketPeer. WarSnapserAuth is a thin identity provider consumed by the validator client to configure the transport's token. WarValidatorClient.setup injects the transport and auth; either may be null. Both null means permanent offline optimistic-only mode (ideal for tests); when provided, connect_validator authenticates first (awaiting the authenticated signal) and then opens the socket.

Validator RPC surface routed through the Hermes snap-api-proxy: war.validator.v1.ValidatorService { InitMatch, ValidateAction, CompleteMatch }. WarValidatorClient sends each as an envelope via WarHermesClient.send_envelope, which returns a request id; _rpc then awaits the correlated envelope_received, ignoring replies for other in-flight requests. Pending requests time out after REQUEST_TIMEOUT_SEC (10s).

Auth modes: in production, login_anonymous performs an anonymous login against the Snapser auth snap and receives { session_token, user_id, expires_at }; Snapser's gateway validates the token per request and stamps a trusted User-Id the validator binds to player_id, so the client never sets User-Id itself. Locally there is no real auth — login_anonymous synthesizes a device-stable id of the form local-<8 hex> (persisted in project settings under war/device_id) and uses it as BOTH player id and token, passed as ?token=<player-id> on the Hermes URL, which the local validator treats as the untrusted caller identity. Local tokens never expire; remote tokens age out and the transport refreshes on reconnect via is_expired.

Skeleton scope: RPC names, request/response shapes, request correlation, reconcile decision logic, the socket lifecycle, the poll pump, and request timeout are all real and working at the framing level. The protobuf (de)serialization is stubbed behind TODO(skeleton) markers in WarHermesClient._encode_client_message and _decode_server_message — until the godobuf bindings land, the transport frames a JSON envelope that mirrors the proto fields one-for-one so the lifecycle is exercisable headless and swapping in godobuf is a drop-in. REMOTE auth is likewise stubbed and fails loudly rather than silently behaving like LOCAL.

godobuf bindings: the generated GDScript protobuf bindings live in game/net/proto/ as *_pb.gd and must not be hand-edited. They are produced by tools/gen-protos.sh (godobuf over the validator-repo protos: war/validator/v1 for the three RPCs and hermes/hermes_envelope.proto for ClientMessage / ServerMessage) and regenerated whenever those .proto sources change, then committed alongside the proto change so client and validator stay in lockstep.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- class `WarValidatorClient` in `game/net/validator_client.gd`
- function `validate_action` in `game/net/validator_client.gd`
- function `init_match` in `game/net/validator_client.gd`
- class `WarHermesClient` in `game/net/hermes_client.gd`
- function `send_envelope` in `game/net/hermes_client.gd`
- class `WarSnapserAuth` in `game/net/snapser_auth.gd`
- function `login_anonymous` in `game/net/snapser_auth.gd`
- `game/net/proto/README.md`

## Data model
The component never re-models hashed game state as protobuf. Game *state* and *actions* always cross the wire as canonical-JSON STRINGS carried inside proto string fields — that JSON string IS the hash domain shared with the TypeScript validator. The protos carry only envelope metadata (request id, RPC routing) plus those opaque JSON strings. WarValidatorClient's async methods return result Dictionaries that form the reconcile contract WarMatch consumes: init_match returns { ok, state_json, hash, error }; validate_action returns { ok, matched, authoritative_state, authoritative_hash, error } where matched means predicted_hash equals the authoritative hash (fast-path ACK) and the full authoritative_state is carried only on the slow mismatch path to save bytes. WarHermesClient holds the socket lifecycle as a small FSM (State { CLOSED, CONNECTING, OPEN, CLOSING }), a monotonic request-id counter, and a _pending map of in-flight requests for correlation and timeout. WarSnapserAuth caches { player_id, token, expires_at }; locally the token is the self-stamped device-stable player id used verbatim, and in production it is a Snapser session token.

## Usage
_None._

## Invariants & constraints
- State and actions cross the wire only as canonical-JSON strings inside proto string fields — they are never modeled as protobuf messages, because re-modeling would break byte-for-byte hash parity with the TypeScript validator.
- Authority is expressed purely as a 64-hex state hash: validate_action reports matched = (server_hash == predicted_hash), and the client snaps to the authoritative state only on mismatch.
- Local emulation and the production Snapser gateway share ONE codepath; the transport never branches on environment beyond the base URL and the token placed in the ?token= query parameter.
- With no transport attached the client runs OFFLINE optimistic-only: validate_action always ACKs the predicted hash and init_match returns error "offline", so WarMatch (and headless logic tests) keep working without a server.

## Synced commit
_None._
