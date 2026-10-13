# Implementation plan — Core Play Loop

**Status:** ready

## Steps
- [x] Phase A — Fix the broken view->controller wiring (current bug) and lock the funnel surface. table.gd calls _call_match('start_new_game', ...) but WarMatch exposes new_game(seed) — it fails SILENTLY via has_method(), so no match deals today; and _on_action_pressed maps phase 'dealt' -> flip, which the engine rejects (flip is legal only in 'selected'). INVARIANT to preserve: WarMatch's input surface is new_game(seed) + submit_action(action) ONLY — route all sequencing through the Director; do NOT add per-action methods (flip/resolve/...) to WarMatch (that would leak pacing across the hard wall).
- [x] Phase A — Create the Round Director (game/ui/round_director.gd, class_name WarRoundDirector extends Node). On _ready: create a WarMatch child and connect state_changed -> _on_state (the single re-derive entry), event -> _on_event (buffer), action_rejected -> _on_rejected. Do NOT bind reconciled to _on_state (WarMatch's reconcile already re-emits state_changed; double-binding runs _on_state twice per snap). Offline-by-default: new_game(fresh_seed). Expose intents request_flip / request_special / request_declare_war / request_skip / request_play_again / request_quit and signals view_state(state) + beat(name, events, locked).
- [x] Phase A — Beat enum + pure beat_for_phase(phase): dealt->STAGING, selected->FLIP_MOMENT, flipped->REVEALING, war->WAR_PROMPT, player_win/cpu_win->GAME_OVER, _->BOOT. ROUND_RESULT / WAR_BANNER / WAR_REVEALING are transient (layered by timers), never returned by beat_for_phase.
- [x] Phase A — Single re-render entry _on_state(state): cancel the pending timer, read+clear the buffered _last_events, re-derive the resting beat, emit view_state(state), then EITHER hold a transient (next step) or enter the resting beat. This is the reconcile-safety core — a snap re-runs exactly this path.
- [x] Phase A — Event-gated transient holds (FIXES the tempo bug). Because WarMatch emits events BEFORE state_changed and an award/tie/decide returns phase to dealt/war in the same apply, gate the next auto-action behind the transient: award -> hold ROUND_RESULT for _dur('result'); tie -> hold WAR_BANNER for _dur('war_banner', depth); war_decide -> hold WAR_REVEALING for _dur('war_stake', depth); THEN enter the resting beat. A terminal award short-circuits to GAME_OVER (no stranded ROUND_RESULT). The single armed timer carries the hold (so skip/cancel are uniform).
- [x] Phase A — Auto-advance the resting beats: STAGING arms _dur('stage') then submits start_round; REVEALING arms _dur('flip')+_dur('read') then submits resolve. Re-entrancy: exactly one auto-action per resting entry (_arm cancels any prior timer; the resting beat is entered once per _on_state).
- [x] Phase A — Flip moment (FLIP_MOMENT / phase 'selected'): request_flip submits flip; request_special(id) submits play_special(id). CORRECTION vs the old draft: peek (the only pre-flip special) does NOT set pending_special — it clears it; the engine stays in 'selected', so the resulting state_changed re-derives FLIP_MOMENT and the Director keeps awaiting the flip. Do not advance the beat in _intent.
- [x] Phase A — WAR escalation: a tie routes the engine to phase 'war'; the Director holds WAR_BANNER (event-gated) then settles into WAR_PROMPT. request_declare_war submits ack_war; on the result, war_decide drives WAR_REVEALING, then a winner falls through to ROUND_RESULT or a re-tie loops WAR_BANNER/WAR_PROMPT at the higher war_depth. The forfeit (a side with < WAR_STAKE+1 = 4 cards) is resolved entirely by the engine (war_forfeit + game_over) -> route to GAME_OVER.
- [x] Phase A — _arm timer helper + tap-to-skip. Declare var _pending: SceneTreeTimer and var _pending_cb: Callable; _arm guards the disconnect (only when still connected), clears _pending_cb on the cancel/null path, then connects the new callback. request_skip() fires the armed callback NOW (submitting the pending auto-action) and is a no-op at FLIP_MOMENT/WAR_PROMPT/GAME_OVER — changes WHEN, never WHICH. (Replaces the draft's undeclared _pending_cb and time_left-only guard.)
- [x] Phase A — Tempo profile: TEMPO (stage 0.22 / flip 0.30 / read 0.35 / result 0.90 / war_banner 1.10 / war_stake 0.45 = Balanced), const SPEED, WAR_DECAY 0.6 / WAR_MIN_SCALE 0.30 / WAR_AUTO_DEPTH 3, war_scale(depth)=max(WAR_MIN_SCALE, WAR_DECAY^(depth-1)), and _dur(key, depth). Drive EVERY auto-beat through _dur (no STAGE_BEAT/REVEAL_BEAT literals; REVEAL = flip+read). Presentation-only — changes when, never which; never touches the hash.
- [x] Phase A — Deep-war auto-ack: at WAR_PROMPT, if war_depth > WAR_AUTO_DEPTH (3) AND can_auto_ack(), arm _dur('war_banner', depth) then auto-submit ack_war; else await request_declare_war. can_auto_ack() returns true in basic; keep it as the documented seam Special Cards overrides to defer while the player owns a relevant post-flip special. This is the acknowledged refinement of the brief's 'two decision points' constraint.
- [x] Phase A — Game over + replay: on player_win/cpu_win emit GAME_OVER (unlocked). request_play_again -> new_game(fresh_seed) (restarts at STAGING); request_quit -> GameState.record_match_played() + UiRouter.goto('home'). ADD a PLAY AGAIN button to the result overlay — today _build_result_overlay has only CONTINUE TO LOBBY, so the refit must ADD the button, not just rewire.
- [x] Phase A — Refit table.gd to view-only: own a WarRoundDirector (not a bare WarMatch); connect view_state -> _render and beat -> button/animation control; keep _render total + idempotent; forward button presses to the Director intents; remove the direct WarMatch calls and the illegal phase->action mapping. Drive button enable/label SOLELY from the beat(locked) payload — split this OUT of _render/_sync_actions so render(state) and beat(locked) cannot disagree mid-animation. Fix the special button's phase gating (enabled at 'dealt' today; the flip moment is 'selected').
- [x] Phase A — Tap-to-skip input plumbing: add a full-screen tap-catcher routed to request_skip during transient/locked beats (today table.gd's backdrop is mouse_filter = IGNORE, so nothing catches the tap, and the action buttons are disabled during those beats). No-op at decision beats.
- [x] Phase A — Verify offline end-to-end (headless SceneTree verifier): a full match plays deal -> repeated rounds -> terminal with NO manual start_round/resolve taps, including >=1 WAR and >=1 war forfeit, plus PLAY AGAIN. Assert a non-empty 'dealt' state actually renders (guards the silent no-deal bug). The Director uses SceneTreeTimers, so the verifier must add it to the tree and await frames/timers before quit() — not do all work in _init().
- [x] Phase A — Confirm headless driveability preserved: WarDebug plays a complete match via start_round/flip/resolve/ack_war with no Director (the deterministic loop must not depend on presentation). The engine verifiers remain the parity source of truth.
- [x] Phase A — Docs + parity guardrail: update game/ARCHITECTURE.md (new Round Director subsystem + view-only table), keep the Presentation & VFX / UI & Meta Shell architecture pages consistent, set the Round Director arch page status off 'current' until it is built, and record the commit on this brief. No game/logic change is expected (the Director is pure presentation); if any is needed, re-run the golden parity verifiers FIRST. Note: online seed-ordering edits land in match_controller.gd (the funnel), which is NOT game/logic/, so they do not trigger the parity verifiers.
- [x] Phase B — Generate + commit godobuf bindings (tools/gen-protos.sh -> game/net/proto/hermes_envelope_pb.gd + validator_pb.gd) and replace WarHermesClient's hand-rolled JSON frame with real Hermes ClientMessage/ServerMessage framing: the inner snap_api_request carries the RPC method name + the serialized ValidatorService request bytes, with state/actions as canonical-JSON strings inside. The current JSON frame does NOT round-trip (client encodes request_id/api_method/body; server reads method/requestId/args; replies under data). godobuf gotcha: rename proto fields that break codegen (a field named 'message'; a field whose generated has_method() collides with Object.has_method()) — names are not on the wire, so renames are safe. Model framing on moveborne game/net/hermes_client.gd.
- [x] Phase B — Thread match_id + player_id. Capture match_id (and player_id) from InitMatch, store on WarValidatorClient, and stamp them on EVERY ValidateAction and CompleteMatch. The stateful, player-bound server requires match_id (else MatchNotFoundError / PlayerBindingError). Model on moveborne: capture once at init_and_connect, reuse on every call — the gameplay layer never passes them per-call.
- [x] Phase B — Server-assigned seed (init-first online). Online, new_game/PLAY AGAIN calls InitMatch with an EMPTY seed; the server generates the seed and returns the authoritative t0 state; the client adopts state_json verbatim (its state.seed is the authority) and deals from it — it must NOT pre-deal before InitMatch returns. Offline self-generates a local seed and deals immediately. Requires the validator to ASSIGN a seed when none is supplied (Validator Client / Match State Store change). Rationale: War's outcome IS the deal, so the seed must not be client-shoppable.
- [x] Phase B — Align the reconcile reply contract end to end. Read authoritative_state_json (NOT state_json) on a ValidateAction mismatch; trust the server's hash_matched / ok; distinguish ok:false (illegal move, server kept its state) from a normal mismatch and snap on both. Surface events_json into WarMatch WITHOUT re-emitting the optimistic events already played (the Director buffers _last_events; a snap re-renders from state, it does not replay animations). Update the .proto + handlers + client to ONE field set (InitMatch returns {match_id, player_id, state_json, hash}; ValidateAction returns {ok, hash_matched, authoritative_state_json, hash, events_json}; CompleteMatch returns {match_id, final_phase, hash}).
- [x] Phase B — Wire the view/lifecycle (modeled on moveborne main.gd). Construct WarHermesClient + WarSnapserAuth + WarValidatorClient, call _match.set_validator(client), connect client_error. Flip a CONFIRMED-online flag true ONLY on the InitMatch ack (not merely is_online()==transport-present); hold input during the connect/InitMatch handshake; on client_error degrade to offline (never a locked board). The Director stays transport-agnostic.
- [x] Phase B — CompleteMatch on terminal. When WarMatch adopts a player_win/cpu_win state, fire complete_match(match_id, player_id) once (idempotent; the server also auto-completes on a terminal phase). Best-effort settlement/telemetry — do not block the GAME_OVER beat on it. (Today complete_match exists but is never called and sends the wrong fields.)
- [x] Phase B — Reconnect policy: on socket drop, briefly lock input then degrade to offline (the engine stays source of truth); to go back online, re-init the match (moveborne pattern — no read RPC). A GetMatchState(match_id, player_id) read RPC for true mid-match resume is OPTIONAL/later, not v1.
- [x] Phase B — Test seams (modeled on moveborne). Add (a) a SceneTree live-local verifier that runs the real validator (tools/run_validator.sh, idempotent on /health) and drives WarHermesClient through InitMatch/ValidateAction (honest hash -> ACK; tampered hash -> mismatch, assert the returned state re-hashes to local) with a create_timer watchdog; (b) a godobuf wire-golden round-trip verifier against a TS-emitted golden frame; (c) a dead-port (ws://127.0.0.1:9) test asserting the match stays offline. WarValidatorClient.setup(null, null) already injects a null transport for offline-only logic tests.
- [x] Phase B — Online end-to-end verify: a full match yields a matched ACK for every submitted action (start_round/flip/resolve/ack_war/play_special) with zero reconciles under parity; force a divergence and confirm the snap re-derives the beat with no double-apply; the server's appliedCount equals the client's submitted action count, in order. Determinism parity (identical 64-hex hashes both sides) is the load-bearing precondition — verify it holds for the server-assigned-seed t0 deal.

## Data models & interfaces
```gdscript
class_name WarRoundDirector
extends Node
## Presentation-tier play sequencer. Owns a WarMatch, paces the engine's legal
## transitions into beats, and pauses for the player at FLIP_MOMENT and WAR_PROMPT.
## Holds NO authoritative state - only the current beat, one armed timer, the last
## apply's events, and a render snapshot.

signal view_state(state: Dictionary)                 # re-render from this snapshot
signal beat(name: int, events: Array, locked: bool)  # animate + lock input

var _match: WarMatch
var _beat: int = Beat.BOOT

func _ready() -> void:
    _match = WarMatch.new()
    add_child(_match)
    # Connect state_changed ONCE as the re-derive entry. WarMatch's reconcile ALSO
    # emits state_changed, so do NOT bind reconciled to _on_state (that would run it
    # twice per snap); bind reconciled only for snap-specific UI if ever needed.
    _match.state_changed.connect(_on_state)
    _match.event.connect(_on_event)
    _match.action_rejected.connect(_on_rejected)
    _match.new_game(_fresh_seed())          # offline default; Phase B inits online first

# --- player intents (from the view) ---------------------------------------
func request_flip() -> void:              _intent(WarActions.flip(), Beat.FLIP_MOMENT)
func request_special(id: String) -> void: _intent(WarActions.play_special(id), Beat.FLIP_MOMENT)
func request_declare_war() -> void:       _intent(WarActions.ack_war(), Beat.WAR_PROMPT)
func request_play_again() -> void:        _match.new_game(_fresh_seed())
func request_quit() -> void:
    GameState.record_match_played()
    UiRouter.goto("home")
# request_skip() is defined with the driver below.

# Submit only when the intent matches the awaited beat. NOTE: play_special('peek')
# stays in phase 'selected' and does NOT set pending_special (peek clears it); the
# resulting state_changed re-derives FLIP_MOMENT, so the Director keeps awaiting the
# flip -- do NOT advance the beat here.
func _intent(action: Dictionary, awaited: int) -> void:
    if _beat == awaited:
        _match.submit_action(action)

func _on_rejected(action: Dictionary, error: String) -> void:
    push_warning("[Director] rejected %s: %s" % [action, error])  # state unchanged; stay put
```

```gdscript
# Reconcile-safe driver with event-GATED transient holds. WarMatch emits engine
# events BEFORE state_changed, and an award/tie/decide returns phase to dealt/war in
# the SAME apply -- so BUFFER the last apply's events and decide, in ONE place,
# whether to hold a transient before arming the next auto-action.
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

func _emit(b: int, events: Array, locked: bool) -> void:
    _beat = b
    beat.emit(b, events, locked)

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

```gdscript
# Tempo profile + deep-war pacing (presentation-only; never affects the hash).
# Drive EVERY auto-beat through _dur() -- no literal durations elsewhere. The reveal
# tail is _dur('flip') + _dur('read'); there is no separate REVEAL_BEAT/STAGE_BEAT.
const TEMPO := {
    "stage": 0.22, "flip": 0.30, "read": 0.35,
    "result": 0.90, "war_banner": 1.10, "war_stake": 0.45,
}
const SPEED := 1.0
const WAR_DECAY := 0.6
const WAR_MIN_SCALE := 0.30
const WAR_AUTO_DEPTH := 3

static func war_scale(depth: int) -> float:
    return max(WAR_MIN_SCALE, pow(WAR_DECAY, max(0, depth - 1)))

func _dur(key: String, depth := 0) -> float:
    var s := float(TEMPO[key]) * SPEED
    return s * war_scale(depth) if depth > 0 else s
```

## Open questions
_None._

## Resolved questions
_None._

## References
_None._

## Child pages
_None._
