# Spec — Core Play Loop

**Status:** sealed

## Overview
This spec defines the **basic gameplay implementation** for War: the Core Play Loop and its presentation-tier sequencer, the **Round Director**, delivered in two phases tracked in this brief — **Phase A (offline MVP)** and **Phase B (online wire to the validator)**. The rules engine (`WarEngine`) and the funnel (`WarMatch`) already exist and are validator-parity-correct; what is missing is the layer that paces the engine's discrete legal transitions into a playable match and exposes the player decision points: the flip moment and the WAR ack (with a deep-war auto-ack refinement). The north star: the Director adds *zero authority* — it only chooses which legal action to submit and when, so the validator re-runs an identical action stream and every existing determinism and reconcile guarantee carries over unchanged. Phase A is modeled on the reference prototype's UIState pacing (idle / animating / showing-result / war / game-over); Phase B is modeled on moveborne's proven optimistic-validator design and is *wiring rather than a rebuild*, because WarMatch already owns the optimistic-apply + reconcile core (with an `_apply_seq` stale-drop guard) and an injectable validator seam.

## Design
## Layering

Three layers, strictly one-way beneath the hard wall. The table view renders the latest state and forwards player intents. The Round Director (new) sequences the loop: it owns a WarMatch, auto-advances the mechanical actions on timed beats, and pauses for the player at the flip moment and the WAR ack. WarMatch is the unchanged funnel that applies each action optimistically and reconciles against the validator. The view never touches WarMatch or the engine directly; the Director never renders pixels. This keeps table.gd a pure renderer and WarMatch a pure funnel, and concentrates all pacing in one place.

```text
 player taps                       render(state) / beat(name, events)
      |                                    ^
      v                                    |
 +--------------------------------------------------+
 | table.gd  (VIEW)  - render-only, forwards intents |
 +--------------------------------------------------+
      | request_flip / request_special(id) /
      | request_declare_war / request_play_again / request_quit
      v
 +--------------------------------------------------+
 | RoundDirector (Node) - PRESENTATION-TIER SEQUENCER|
 |  - owns a WarMatch                                |
 |  - beat = beat_for_phase(state.phase) + timers    |
 |  - auto-submits start_round / resolve on beats    |
 |  - awaits the player at FLIP_MOMENT and WAR_PROMPT |
 +--------------------------------------------------+
      | submit_action(WarActions.*)      ^ state_changed / event / reconciled
      v                                  |
 +--------------------------------------------------+
 | WarMatch (FUNNEL) - optimistic apply + reconcile  |
 +--------------------------------------------------+
      | WarEngine.apply (pure)   <->   Validator (authoritative parity)
      v
 ================= HARD WALL ==================
```

## The beat machine

The Director holds a cosmetic beat that is distinct from, and derived from, the engine phase. The engine phase is the truth; the beat is pacing. The resting beat for any phase is a pure function, beat_for_phase(phase), so the loop can always be reconstructed from authoritative state. On top of that mapping the Director layers transient beats (the reveal, the result hold, the WAR banner, the war stake reveal) driven by short timers, plus a single input-locked flag that disables the action buttons while an animation is playing. The Director stores no card data, no deck, no hash — only the current beat, the timers, and a deep-copied snapshot of the last state it was handed for rendering.

```gdscript
# Cosmetic beats - pacing only. Distinct from the engine phase (the truth).
enum Beat {
    BOOT,
    STAGING,        # phase 'dealt'    - auto: submit start_round
    FLIP_MOMENT,    # phase 'selected' - await: request_flip / request_special
    REVEALING,      # phase 'flipped'  - auto: play reveal, then submit resolve
    ROUND_RESULT,   # transient        - hold winner highlight, then next round
    WAR_BANNER,     # transient        - 'I. DECLARE. WAR.' on entering a tie
    WAR_PROMPT,     # phase 'war'       - await: request_declare_war
    WAR_REVEALING,  # transient        - stake 3 down + 1 up, reveal deciders
    GAME_OVER,      # phase player_win / cpu_win
}

# Pure mapping: the RESTING beat implied by an engine phase. Transient beats are
# layered on by the Director, but it can always fall back to this from state.
static func beat_for_phase(phase: String) -> Beat:
    match phase:
        "dealt":                 return Beat.STAGING
        "selected":              return Beat.FLIP_MOMENT
        "flipped":               return Beat.REVEALING
        "war":                   return Beat.WAR_PROMPT
        "player_win", "cpu_win": return Beat.GAME_OVER
        _:                       return Beat.BOOT
```

## Round walkthrough

A round runs deal, flip moment, reveal, resolve, result, then loops. On new_game the engine deals and rests at phase 'dealt'. STAGING: the Director auto-submits start_round after a short stage beat; the engine stages the top card of each deck face-down into the pots and moves to 'selected'. FLIP_MOMENT: the Director waits. The view shows the two face-down cards, a FLIP button, and a USE SPECIAL button enabled only if the player owns an unstaged pre-flip special. The player taps FLIP (Director submits flip) or first taps USE SPECIAL (Director submits play_special, which stays in 'selected') and then FLIP. REVEALING: on phase 'flipped' the Director plays the reveal animation with input locked, then auto-submits resolve after the reveal duration. The engine awards both pots to the higher rank and returns to 'dealt'. ROUND_RESULT: the Director holds a brief result beat (winner card outlined green, loser red, deck-count delta) before advancing to the next STAGING. If the award emptied a deck, the engine instead reports a terminal phase and the Director routes to GAME_OVER.

## The WAR escalation

When the two revealed cards tie, the engine routes 'flip' straight to phase 'war' (war_depth becomes 1) instead of 'flipped'. The Director sees the tie event and plays the WAR_BANNER beat (the full-screen I-Declare-War overlay) before settling into WAR_PROMPT. WAR_PROMPT: the Director waits for request_declare_war; the view shows a DECLARE WAR button (and, once the Special Cards feature lands, an optional post-flip special). On the player's tap the Director submits ack_war: the engine stakes WAR_STAKE (3) cards face-down plus 1 face-up decider per side, increments war_depth, and compares the deciders. A winner returns to 'dealt' (ROUND_RESULT then loop); another tie stays in 'war' and the Director loops back through WAR_BANNER/WAR_PROMPT at the higher war_depth. The can-not-complete-a-war forfeit (a side with fewer than WAR_STAKE+1 = 4 cards) is resolved entirely by the engine, which emits war_forfeit + game_over; the Director simply routes to GAME_OVER. The detailed staking animation and war_depth pips are owned by the I-Declare-War Moment feature, which plugs into these beats.

## Game over and replay

On phase player_win or cpu_win the Director emits GAME_OVER and the view shows the result overlay (VICTORY green / DEFEAT red). PLAY AGAIN calls request_play_again, which submits new_game with a fresh seed and restarts the loop at STAGING. CONTINUE TO LOBBY calls request_quit, which records the played match via GameState.record_match_played() and routes home through UiRouter. The meta rewards screen (XP, multipliers) is part of the Meta and Monetization layer, not the basic loop.

## Action stream and validator alignment

The Director emits only canonical WarActions, only when legal, through the one WarMatch funnel. The player chooses flip, play_special, and ack_war; the Director auto-emits start_round (on entering 'dealt') and resolve (after the reveal beat). Because those auto actions are deterministic and phase-legal, the validator re-runs the identical stream: optimistic apply, predicted-hash ACK on match, snap on mismatch — unchanged from today. The loop is fully playable offline (the engine is the source of truth) and the same actions remain drivable headlessly through WarDebug, so the Director is never required for deterministic play.

```text
match    := new_game  round*
round    := start_round  special?  flip  ( resolve | war )
war      := ack_war  ( war )?            # repeats while the deciders keep tying
special  := play_special(id)             # flip-moment (pre_flip) only, in basic

# player-chosen :  flip, play_special, ack_war
# director-auto :  start_round (on entering 'dealt'), resolve (after reveal beat)
# note          :  'resolve' submitted in phase 'war' is treated by the engine
#                  exactly like ack_war, so a single primary button is enough
```

## Transient beats and event/state ordering

The transient beats (ROUND_RESULT, WAR_BANNER, WAR_REVEALING) are NOT engine phases, and they cannot be driven from _on_event, because WarMatch emits engine events BEFORE state_changed and an award/tie/decide returns the phase to dealt/war in the SAME apply — so emitting a transient in _on_event and then re-deriving in _on_state overwrites it the same frame (this was the original design's flaw: result/banner holds were specified but never actually held). The fix: the Director BUFFERS the last apply's events in _on_event and decides, in ONE place (_on_state), whether to hold a transient before arming the next auto-action. A single armed timer carries the transient hold, so tap-to-skip (fire the armed callback now) and reconcile-cancel work uniformly. This also DEFINES WAR_REVEALING: it is the transient layered on the ack_war result (the war_decide event) before a winner falls through to ROUND_RESULT or a re-tie loops back to WAR_BANNER/WAR_PROMPT at the higher depth. A terminal award short-circuits straight to GAME_OVER with no stranded ROUND_RESULT.

```gdscript
# Reconcile-safe driver with event-GATED transient holds. WarMatch emits engine
# events BEFORE state_changed, and an award/tie/decide returns the phase to
# dealt/war in the SAME apply -- so the Director BUFFERS the last apply's events
# and decides, in ONE place, whether to hold a transient beat before arming the
# next auto-action. A single armed timer carries every hold.
var _pending: SceneTreeTimer = null
var _pending_cb: Callable = Callable()
var _last_events: Array = []

func _on_event(ev: Dictionary) -> void:
    _last_events.append(ev)              # buffer only; never emit a beat here

func _on_state(state: Dictionary) -> void:
    _arm(null)                           # cancel any pending beat timer
    var events := _last_events
    _last_events = []
    var phase := String(state.get("phase", ""))
    var depth := int(state.get("war_depth", 0))
    var resting := beat_for_phase(phase)
    view_state.emit(state)
    if resting == Beat.GAME_OVER:        # terminal short-circuits any transient
        _emit(Beat.GAME_OVER, events, false); return
    if _has(events, "award") and resting == Beat.STAGING:
        _hold(Beat.ROUND_RESULT, events, _dur("result"), resting, depth)
    elif _has(events, "tie"):            # flip- or war-tie -> WAR_PROMPT resting
        _hold(Beat.WAR_BANNER, events, _dur("war_banner", depth), resting, depth)
    elif _has(events, "war_decide"):     # an ack_war that did not end the round
        _hold(Beat.WAR_REVEALING, events, _dur("war_stake", depth), resting, depth)
    else:
        _enter_resting(resting, depth)

func _hold(transient: int, events: Array, seconds: float, resting: int, depth: int) -> void:
    _emit(transient, events, true)       # show the transient, input locked
    _arm(seconds, func(): _enter_resting(resting, depth))

func _enter_resting(resting: int, depth: int) -> void:
    var locked := resting != Beat.FLIP_MOMENT and resting != Beat.WAR_PROMPT
    _emit(resting, [], locked)
    match resting:
        Beat.STAGING:   _arm(_dur("stage"),               func(): _match.submit_action(WarActions.start_round()))
        Beat.REVEALING: _arm(_dur("flip") + _dur("read"), func(): _match.submit_action(WarActions.resolve()))
        Beat.WAR_PROMPT:
            if depth > WAR_AUTO_DEPTH and can_auto_ack():    # runaway war auto-advances
                _arm(_dur("war_banner", depth), func(): _match.submit_action(WarActions.ack_war()))
            # else await request_declare_war()
        # FLIP_MOMENT / GAME_OVER: await a player intent.

func _arm(seconds, cb := Callable()) -> void:
    if _pending != null and _pending.time_left > 0.0 and _pending_cb.is_valid() \
       and _pending.timeout.is_connected(_pending_cb):
        _pending.timeout.disconnect(_pending_cb)
    _pending_cb = Callable()
    if seconds == null:
        _pending = null; return
    _pending = get_tree().create_timer(seconds)
    _pending_cb = cb
    _pending.timeout.connect(cb)

func request_skip() -> void:             # fire the armed transient/auto-action NOW
    if _pending_cb.is_valid() and _beat not in [Beat.FLIP_MOMENT, Beat.WAR_PROMPT, Beat.GAME_OVER]:
        var cb := _pending_cb
        _arm(null)
        cb.call()

func _has(events: Array, t: String) -> bool:
    for ev in events:
        if String(ev.get("type", "")) == t: return true
    return false

func can_auto_ack() -> bool: return true  # basic: always; Special Cards overrides to defer
```

## Reconcile behavior

Reconcile re-derives through the SAME single entry point (_on_state) as a normal apply. WarMatch._reconcile_from_json emits state_changed AND THEN reconciled for one snap, so the Director connects ONLY state_changed -> _on_state; binding reconciled to the same handler would run _on_state twice per snap (double-emitting view_state/beat and re-arming the timer). Connect reconciled separately only for snap-specific UI (e.g. suppress a tween from the now-discarded optimistic state). Because the beat is a pure function of phase and _on_state cancels the pending timer before re-deriving, a mid-animation snap cannot double-apply an action or strand a phantom beat — worst case is a skipped animation, after which the loop sits exactly where the authoritative state says. WarMatch already drops stale reconciles via its _apply_seq guard.

## Tempo and pacing

Beat durations are data-driven constants on the Director, not magic numbers scattered through the view. The default profile is Balanced: stage 0.22s, card flip 0.30s, read-after-flip 0.35s, round-result hold 0.90s, WAR banner 1.10s, war stake reveal 0.45s — roughly 1.8s of auto-beats per non-war round on top of the player's own tap. A single global SPEED multiplier scales the whole profile (a fast-mode / accessibility knob). Crucially, tempo lives entirely in presentation: these constants change only WHEN an auto-action is submitted, never WHICH action or in what order, so the validator action stream and the 64-hex hashes are identical regardless of tempo. The FLIP_MOMENT and (shallow) WAR_PROMPT beats have no duration — they wait for the player; tempo governs only the auto-advanced beats (stage, reveal tail, result, war banner, war stake).

```gdscript
# Presentation-only tempo. Changes WHEN an auto-action fires, never WHICH, so
# the hash/parity domain is untouched by any value here. Drive EVERY auto-beat
# through _dur(); the reveal tail is _dur('flip') + _dur('read').
const TEMPO := {
    "stage":      0.22,  # STAGING: deal/slide-in lock, ends by submitting start_round
    "flip":       0.30,  # REVEALING: card-flip animation
    "read":       0.35,  # REVEALING tail: dwell on revealed faces, then submit resolve
    "result":     0.90,  # ROUND_RESULT: winner highlight + deck-delta hold
    "war_banner": 1.10,  # WAR_BANNER: 'I. DECLARE. WAR.' before the prompt
    "war_stake":  0.45,  # WAR_REVEALING: stake 3-down + 1-up, then reveal deciders
}
const SPEED := 1.0       # global multiplier (fast mode / accessibility)

func _dur(key: String, depth := 0) -> float:
    var s := float(TEMPO[key]) * SPEED
    return s * war_scale(depth) if depth > 0 else s
```

## Tap-to-skip and deep-war auto-acceleration

Three pacing aids keep repeated wars from dragging, and all three touch only timing. First, tap-to-skip: a tap anywhere during a transient or locked beat (STAGING, REVEALING, ROUND_RESULT, WAR_BANNER, WAR_REVEALING) calls request_skip(), which fires the armed timer's callback immediately — submitting the pending auto-action now and letting the view snap the animation to its end. Because the callback submits the same action either way, skipping changes when, never which. Second, war-depth decay: war beats scale by war_scale(depth) = max(0.30, 0.6 ^ (depth - 1)), so the first war plays at full length and each re-tie is snappier (depth 1 = 1.00, 2 = 0.60, 3 = 0.36, 4+ clamped at 0.30). Third, the auto-ack threshold: past war_depth 3 the WAR_PROMPT stops waiting for a DECLARE WAR tap and the Director auto-submits ack_war after a quick banner. Depths 1 through 3 still prompt, preserving the signature 'I declare war' tap and its drama; only a runaway war auto-resolves. Note this means the WAR ack is a player decision point for shallow wars and an auto-beat for deep ones — a refinement of the two-decision-points rule. (Once post-flip Special Cards exist, can_auto_ack() defers while the player owns a relevant special.)

```gdscript
const WAR_DECAY := 0.6       # each extra war level multiplies war beats by this...
const WAR_MIN_SCALE := 0.30  # ...clamped so deep wars stay readable, not instant
const WAR_AUTO_DEPTH := 3    # war_depth > 3: stop prompting, auto-submit ack_war

static func war_scale(depth: int) -> float:
    return max(WAR_MIN_SCALE, pow(WAR_DECAY, max(0, depth - 1)))
# depth 1 -> 1.00,  2 -> 0.60,  3 -> 0.36,  4 -> 0.30 (clamped), ...

# At WAR_PROMPT:  if war_depth <= WAR_AUTO_DEPTH -> await request_declare_war()
#                else (and can_auto_ack()) -> arm (war_banner * war_scale) then submit ack_war()
# request_skip() during any transient beat fires its armed callback NOW.
```

## What basic deliberately excludes

Excluded from the basic loop and owned by adjacent features: the post-flip Special window and the Play Special picker drawer (Special Cards feature); CPU-played specials and any opponent AI; the WAR betting stub; full card-flip and stake VFX polish (Presentation & VFX); and the meta rewards/monetization screen (Meta & Monetization layer). NOTE (corrected): the deep-war fast-forward/skip control is IN scope here — tap-to-skip, war-depth decay, and deep-war auto-ack are all Phase A (it was previously mislabeled as excluded). The basic loop provides the beats the deferred features attach to, and nothing more.

## Seed authority: offline vs online

The match seed determines the deal, so who picks it is a trust question — and in War the deal IS the outcome (the basic loop has no player skill), so the seed is the highest-value thing to cheat. Offline, there is no authority and determinism is purely local: the Director self-generates a fresh seed per match (PLAY AGAIN reseeds). Online, the seed is assigned by the validator — the server is the seed authority, so a client cannot seed-shop for a favorable deal (anti-cheat). The online flow (init-first): starting a match asks the validator to create/initialize it with an EMPTY seed; the validator generates the seed and returns the authoritative t0 state/hash; the client adopts that state verbatim (its state.seed is the authority) and, by the determinism-parity contract, reproduces the byte-identical deal, then plays optimistically from there — it must not pre-deal before InitMatch returns. Implication: the validator's InitMatch must ASSIGN a seed when none is supplied (a Validator Client / Match State Store addition, Phase B), not a change to the deterministic engine.

## Online play: the validator wire (Phase B)

The loop is offline-first: with no validator attached the engine is the source of truth and the Director never knows the difference. Going online only adds confirmation and correction underneath. Below the Director the stack is Director to WarMatch to WarValidatorClient to WarHermesClient to a single WebSocket, terminating either at a local validator or, deployed, at the Snapser gateway that proxies to the same ValidatorService. The Director is transport-agnostic — it only calls submit_action; whether that action is also validated online is entirely WarMatch's concern.

The validator is STATEFUL. It keeps the authoritative state of each match in a MatchStore keyed by match_id and bound to a player_id, and ValidateAction advances that stored state one action at a time. Two consequences follow. First, the client must send the COMPLETE, ORDERED action stream — including the Director's auto-advanced start_round and resolve — because each is a real ValidateAction that moves the server's state forward; skipping or reordering any action diverges the server. Second, the client must remember the match_id the validator assigns at InitMatch and present it (with its player_id) on every later call. The mapping is one-to-one: new_game maps to InitMatch, every submitted action maps to one ValidateAction, and the terminal transition maps to CompleteMatch.

### What War already has — online is wiring, not a rebuild

Phase B is plumbing, not a rebuild — verified against the moveborne reference. War ALREADY has: WarMatch's optimistic-apply-then-reconcile core (submit_action commits locally, validates the predicted hash, snaps via _reconcile_from_json -> reconciled); an _apply_seq stale-reconcile guard that moveborne lacks; an injectable validator seam (set_validator / is_online, offline by default); the four-layer net stack (WarMatch -> WarValidatorClient -> WarHermesClient -> WarSnapserAuth) with request correlation + timeout; offline-safe degradation (validate_action returns matched=true when offline); and a server that already keys by match_id with player binding and terminal auto-complete. The remaining work is purely transport + lifecycle (the Phase B work items below). Do NOT rewrite the optimistic/reconcile core.

### Transport envelope (Hermes)

All three RPCs ride one persistent WebSocket as a Hermes snap-api-proxy envelope; the client multiplexes requests over the single socket and correlates replies by request_id. State and actions are never proto-modeled — they travel as canonical-JSON strings inside the RPC message string fields, and the envelope payload is opaque bytes, so the determinism hash is byte-identical on both sides. The type discriminator is the literal snap-api-proxy and method selects the RPC.

```protobuf
// hermes/hermes_envelope.proto  (transport only; payload is opaque bytes)
message ClientMessage { string type = 1; oneof body { SnapApiProxyRequest api_proxy = 2; } }
message ServerMessage { string type = 1; oneof body { SnapApiProxyResponse api_proxy = 2; } }

message SnapApiProxyRequest {
  string request_id = 1;                 // correlates the async reply
  string method     = 2;                 // "InitMatch" | "ValidateAction" | "CompleteMatch"
  bytes  payload    = 3;                 // serialized RPC request bytes (carry *_json strings)
  map<string,string> metadata = 4;       // trace ids, etc. (not hashed)
}
message SnapApiProxyResponse {
  string request_id     = 1;
  int32  status_code    = 2;             // gRPC-style; 0 == OK
  string status_message = 3;
  bytes  payload        = 4;             // serialized RPC response bytes
  map<string,string> metadata = 5;
}
```

### ValidatorService RPC messages (actual handler contract + Phase B target)

The authoritative surface is war.validator.v1.ValidatorService with three RPCs. Field NAMES below match the RUNNING handlers (hermes-ws.ts / grpc.ts) — align godobuf and WarValidatorClient to THESE (and update the .proto to match), not the earlier draft that used ack / a different InitMatch shape. Every *_json field is a canonical-JSON string (the hash domain); every hash is 64 lowercase hex; match_id + player_id are REQUIRED on every call (the store is stateful and player-bound).

```protobuf
// war/validator/v1 -- field names match the running handlers (Phase B target).
// *_json = canonical-JSON strings (the hash domain).

message InitMatchRequest  { string match_id=1; string player_id=2;
                            string seed=3;            // MAY be empty -> server assigns (anti seed-shop)
                            string predicted_state_json=4; string predicted_hash=5; }
message InitMatchResponse { string match_id=1; string player_id=2;
                            string state_json=3;      // authoritative t0; its state.seed is the authority
                            string hash=4; string error=5; }

message ValidateActionRequest  { string match_id=1; string player_id=2;
                                 string action_json=3;     // { "type":..., ...args }
                                 string predicted_hash=4; }
message ValidateActionResponse { bool ok=1;               // engine legality (false = illegal, state unchanged)
                                 bool hash_matched=2;      // predicted == authoritative (fast-path ACK)
                                 string authoritative_state_json=3; // present on mismatch -> snap
                                 string hash=4; string events_json=5; string error=6; }

message CompleteMatchRequest  { string match_id=1; string player_id=2; }
message CompleteMatchResponse { string match_id=1; string final_phase=2; string hash=3; string error=4; }

// (1) Client captures match_id + player_id at InitMatch and threads them on every call.
// (2) Server is stateful, so ValidateAction carries NO prior state_json.
// (3) Server-assigned seed: send seed=""; client adopts InitMatchResponse.state_json verbatim as t0.
```

### Transport: godobuf is the Phase B wire

The Phase B wire is generated godobuf bindings, not the hand-rolled JSON dev-frame. tools/gen-protos.sh emits game/net/proto/hermes_envelope_pb.gd + validator_pb.gd; the client builds a real Hermes ClientMessage (request_id-correlated, message_type = snap-api-proxy) whose inner snap_api_request carries the RPC method name + the serialized ValidatorService request bytes, with state/actions as canonical-JSON strings inside that inner message. The current JSON dev-frame is DEPRECATED and does not round-trip (client encodes request_id/api_method/body; server reads method/requestId/args and replies under data; plus state_json vs authoritative_state_json drift). godobuf gotcha (seen in moveborne): a proto field named 'message' fails to parse and generated has_method() collides with Object.has_method() — rename offending PROTO fields (e.g. message -> error_message), which is safe because field names are not on the wire.

### Reconcile reply alignment (Phase B)

Align WarValidatorClient to the handler reply above: on ValidateAction read authoritative_state_json (NOT state_json) for the snap, and trust the server's hash_matched / ok rather than only recomputing the hash; distinguish ok:false (illegal move — server kept its state) from a normal hash mismatch, snapping from authoritative_state_json on both. Surface events_json into WarMatch but do NOT re-emit the optimistic events already played for that action — the Director buffers _last_events per apply, and a reconcile snap re-renders from state, it does not replay animations.

### Mapping the play loop to the wire

```text
loop event (Director)         WarMatch call            wire RPC
--------------------------    ---------------------    --------------
new match / PLAY AGAIN        new_game(seed?)          InitMatch
auto: stage round            submit start_round       ValidateAction
player: flip                 submit flip              ValidateAction
player: play special         submit play_special      ValidateAction
auto: resolve                submit resolve           ValidateAction
player/auto: declare war     submit ack_war           ValidateAction
phase player_win / cpu_win   (on terminal)            CompleteMatch
```

```text
One non-war round online (happy path; H = predicted hash, server ACKs each):

Director STAGING     -> submit start_round
  apply (optimistic)   phase 'selected',  predicted_hash = H1
  ValidateAction{ match_id, action_json:"start_round", predicted_hash:H1 }
      <- { ok:true, hash_matched:true, hash:H1 }   # fast-path, no snap
player taps FLIP     -> submit flip
  apply (optimistic)   phase 'flipped',   predicted_hash = H2
  ValidateAction{ ..., action_json:"flip", predicted_hash:H2 }
      <- { ok:true, hash_matched:true, hash:H2 }
Director REVEALING   -> submit resolve
  apply (optimistic)   phase 'dealt',     predicted_hash = H3
  ValidateAction{ ..., action_json:"resolve", predicted_hash:H3 }
      <- { ok:true, hash_matched:true, hash:H3 }

# Mismatch -> { ok:true, hash_matched:false, authoritative_state_json } (or ok:false
# on an illegal action) -> WarMatch snaps from authoritative_state_json, emits
# reconciled(state), and the Director re-derives its beat. Stale replies are dropped
# by WarMatch's _apply_seq guard.
```

### Local vs remote validator

Local and remote are already ONE client codepath; only the base URL, the token source, and the server-side trust model differ. The client picks the URL (WarHermesClient.base_url) and the token (WarSnapserAuth); the server picks the trust model via config.isLocal. Everything above WarHermesClient — RPC shapes, correlation, the reconcile decision — is identical, so this is already accounted for and needs no per-environment branching in the loop.

```text
                local validator                       deployed (Snapser BYOSnap)
-------------   -----------------------------------   --------------------------------
endpoint        ws://localhost:5555/hermes/ws         wss gateway /hermes/ws
                  ?token=<player-id>                    (gateway-fronted)
identity        self-stamped ?token = local-<hex>     gateway-stamped User-Id header
trust (server)  config.isLocal = true (no secret)     verify User-Id vs SHARED_SECRET
RPC transport   Hermes snap-api-proxy over WS         same envelope -> BYOSnap gRPC
direct gRPC     :8081 (optional)                      :8081 (internal)
HTTP / health   :5555  /health                        :8080  /health (base /v1/byosnap-validator)
MCP debug       POST :5555/mcp                        POST /mcp
client knobs    base_url = LOCAL_HERMES_URL           base_url = PROD_HERMES_URL
                token = device-stable local id        token = Snapser session token
```

### Phase B work items (closing the wire gaps)

Spelling out the wire surfaces the concrete Phase B steps (detailed in the implementation plan): generate + commit godobuf bindings and replace the JSON frame; thread match_id/player_id captured at InitMatch onto every ValidateAction/CompleteMatch; make InitMatch assign a seed when none is supplied and adopt the returned authoritative state verbatim (init-first online); align the reconcile reply fields; fire CompleteMatch on a terminal phase; wire the view (construct + set_validator, flip a CONFIRMED-online flag only on the InitMatch ack, hold input during the handshake, degrade to offline on client_error — never a locked board); and add the live-local + wire-golden + dead-port test seams. Reconnect degrades to offline and re-inits; a GetMatchState read RPC is optional and later, not v1.

### Deferred: replay defense (future hardening)

Deferred (future determinism-contract ADR, NOT this feature): the server applies a ValidateAction to whatever state it holds and has no move-ordering guard, and War's _apply_seq is client-side only — so out-of-order or duplicated frames could advance the server incorrectly. moveborne defends this by rejecting any action whose index != the stored move counter. Adding an equivalent monotonic counter to War would change the HASHED state schema (breaking all golden hashes and requiring both engines + the parity vectors to update), so it is out of scope for the core loop and tracked separately.

## Decisions
Staging auto-advances. Entering phase 'dealt' (non-terminal) the Director submits start_round after a short stage beat, so the loop settles at 'selected' (the flip moment) with no separate deal tap. start_round is a deterministic, legal action, so the validator re-runs it identically and the action stream stays clean. Should staging auto-advance (dealt → selected with no tap) so the flip moment is the player's first interaction each round, rather than a separate 'deal' tap?

The basic loop auto-resolves the flipped phase after the reveal beat and exposes NO post-flip Special window. The post-flip interaction (rank_boost / steal_tie) is a presentation seam owned by the Special Cards feature, which inserts a pause at the REVEALING/WAR beats the Director already exposes. The engine already permits post-flip specials in 'flipped'/'war', so this is purely a UI deferral, keeping basic to a single Special window: the flip moment. In the BASIC loop, should the flipped phase expose a post-flip Special window (rank_boost / steal_tie), or auto-resolve and defer that interaction to the Special Cards feature?

No CPU specials in the basic loop. The opponent is purely the forced engine draw; specials.cpu stays empty and the Director never submits a CPU special. Because War gives the opponent no choices, the single deterministic engine plays both sides and there is no CPU AI to write. CPU specials are a later balance/AI hook layered on the spine, not part of it. Does the CPU ever play Special Cards in the basic loop, or is the basic opponent purely the forced engine draw with no specials?

Ship the Balanced tempo profile as the default (stage 0.22, flip 0.30, read 0.35, result 0.90, WAR banner 1.10, war stake 0.45), with a global SPEED multiplier and per-war-depth decay layered on. Values are data-driven, presentation-only constants (they change when an auto-action fires, never which), so they are freely retunable after playtest without touching parity. What are the exact beat durations (reveal, result hold, WAR banner, war stake reveal) for the right hypercasual game feel?

Yes, deep wars get a pacing control with three layers: tap-to-skip fast-forwards any transient beat by firing its armed auto-action immediately; war beats decay with depth (war_scale = max(0.30, 0.6^(depth-1))); and past war_depth 3 the DECLARE WAR prompt stops waiting and the Director auto-submits ack_war after a quick banner. Depths 1-3 still prompt. All three change only timing, never the action stream or hashes. For deep wars (high war_depth), is there a fast-forward / skip / auto-resolve control so pacing doesn't drag across repeated escalations?

Online, the match seed is assigned by the validator (server is the seed authority; clients cannot seed-shop). A new online match takes the validator-returned authoritative seed and deals from it, reproducing the byte-identical deal by the parity contract; offline, the client self-generates a fresh local seed. This likely requires extending the validator's init/create-match call to RETURN a seed instead of only accepting one — a Validator Client dependency, not an engine change. PLAY AGAIN reseed policy: a fresh local random seed each match offline is fine, but what is the seed source when online (client-proposed vs server-assigned)?

Transient beats hold via event-gating in ONE place. The Director buffers the last apply's engine events (WarMatch emits events before state_changed) and, in _on_state, holds the matching transient (award -> ROUND_RESULT, tie -> WAR_BANNER, war_decide -> WAR_REVEALING) on the single armed timer BEFORE arming the resting beat's auto-action. This fixes the original flaw where result/banner holds were specified but instantly overwritten, defines WAR_REVEALING's lifecycle, and keeps tap-to-skip (fire-now) and reconcile-cancel uniform. A terminal award short-circuits to GAME_OVER with no stranded ROUND_RESULT. See the 'Transient beats and event/state ordering' design section. How do the transient beats (ROUND_RESULT / WAR_BANNER / WAR_REVEALING) hold their duration, given WarMatch emits engine events before state_changed and an award/decide returns the phase to dealt/war in the same apply — so a naive 'emit beat in _on_event, re-derive in _on_state' overwrites the transient instantly?

Online is phased inside this feature (Phase A offline MVP, Phase B online wire) and transported over generated godobuf bindings, NOT the deprecated hand-rolled JSON dev-frame (which does not round-trip today). Phase B is plumbing on top of WarMatch's existing optimistic/reconcile core — thread match_id/player_id, adopt the server-assigned seed at InitMatch (init-first online), align the reconcile reply fields, fire CompleteMatch on a terminal phase — modeled on moveborne's validated client. See the 'Online play: the validator wire', 'Transport: godobuf', and 'What War already has' design sections. How is the online/validator workstream scoped and transported — split into the Validator Client feature, or phased inside this feature; and does the wire use the hand-rolled JSON dev-frame or generated godobuf bindings?

Reconnect (Phase B): on transport loss the loop degrades to offline (the local deterministic engine stays the source of truth) and re-inits the match to go back online — matching moveborne, which has no read RPC and recovers by re-registering current state. A GetMatchState(match_id, player_id) read RPC for true mid-match resume is an OPTIONAL later addition (the server still holds the match under match_id), not v1; action-log replay is rejected as unnecessary. On transport loss and reconnect mid-match, how should the client resync to the stateful server's authoritative state for match_id — add a GetMatchState read RPC (recommended), or replay the action log? No read RPC returns a match's current state today (Init/Validate/Complete don't), so this needs a validator contract decision.

## References
_None._

## Child pages
_None._
