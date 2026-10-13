# Testing plan — Core Play Loop

**Status:** ready

## Planned
_None._

## Passed
- [Phase A / logic verifier] beat_for_phase mapping: dealt/selected/flipped/war/(player_win|cpu_win) -> STAGING/FLIP_MOMENT/REVEALING/WAR_PROMPT/GAME_OVER, and ''/unknown -> BOOT. Pure function, assert directly.
- [Phase A / SceneTree verifier] Full match auto-advances: from new_game the match plays to a terminal win with the player only tapping FLIP (+ DECLARE WAR on shallow ties) — no manual start_round/resolve; staging and award fire on their beats. (Frame-advancing verifier: add the Director to the tree and await timers; do NOT do all work in _init().)
- [Phase A / SceneTree verifier] Transient beats actually hold (guards the event-before-state clobber bug). Assert the BEAT SEQUENCE, not wall-clock: after an award, beat(ROUND_RESULT) is emitted and the start_round submit does NOT fire until the result timer elapses; after a tie, WAR_BANNER precedes WAR_PROMPT; after a non-terminal ack_war, WAR_REVEALING precedes the result/next beat.
- [Phase A / SceneTree verifier] Terminal award -> GAME_OVER directly: a match-ending award routes to GAME_OVER with NO stranded ROUND_RESULT auto-advance; the result overlay shows VICTORY (player_win) / DEFEAT (cpu_win).
- [Phase A / SceneTree verifier] Flip-moment gating: request_flip at FLIP_MOMENT submits exactly one flip; request_flip while locked (REVEALING/STAGING/ROUND_RESULT/WAR_BANNER) submits nothing.
- [Phase A / SceneTree verifier] Pre-flip special seam (CORRECTED): request_special('peek') at the flip moment submits play_special; the engine stays in phase 'selected' and pending_special remains NULL (peek clears it — assert null, NOT set); the Director re-derives FLIP_MOMENT and still awaits the flip; the following flip proceeds. No special-specific code in the Director.
- [Phase A / SceneTree verifier] Tie -> WAR loop: a forced tie routes to phase 'war'; WAR_BANNER then WAR_PROMPT; DECLARE WAR stakes 3 down + 1 up and awards to the higher decider; a second forced tie increments war_depth and loops the WAR beats (WAR_BANNER / WAR_REVEALING / WAR_PROMPT).
- [Phase A / SceneTree verifier] War forfeit: a side with < 4 cards (WAR_STAKE+1) at a declared war ends the match immediately with the correct winner; war_forfeit + game_over surface and the Director routes straight to GAME_OVER.
- [Phase A / SceneTree verifier] Per-beat input-lock: beat(locked) is true for STAGING/REVEALING/ROUND_RESULT/WAR_BANNER/WAR_REVEALING and false for FLIP_MOMENT/WAR_PROMPT/GAME_OVER (assert GAME_OVER is UNLOCKED so PLAY AGAIN/CONTINUE work). The view drives button enable solely from this flag.
- [Phase A / SceneTree verifier] Tap-to-skip is a NO-OP at decision beats: request_skip at FLIP_MOMENT/WAR_PROMPT/GAME_OVER submits nothing (never auto-flips away the player's only decision); request_skip during a transient/auto beat fires the armed action immediately.
- [Phase A / logic verifier] Tap-to-skip is determinism-neutral: a match spamming request_skip on every transient beat yields the SAME action stream and SAME 64-hex hashes, round for round, as one at full tempo — skip changes when, never which.
- [Phase A / logic verifier] Tempo algebra (not wall-clock): assert _dur('flip')+_dur('read') == 0.65, _dur('result') == 0.90, SPEED scales all proportionally, and war_scale(1..5) == [1.00, 0.60, 0.36, 0.30, 0.30]. (Replaces the flaky '~0.65s after a flip' wall-clock assertion.)
- [Phase A / SceneTree verifier] Deep-war auto-acceleration: a forced 5-deep war prompts DECLARE WAR for depths 1-3, then auto-advances (no tap) for depths 4-5 with shorter banners (war_scale 1.00/0.60/0.36/0.30/0.30) and resolves to the correct winner; can_auto_ack()==false suppresses the auto-ack (the Special Cards seam).
- [Phase A / SceneTree verifier] Reconcile safety + no double-invoke: inject a reconciled snap mid-beat; the Director cancels its pending timer and re-derives from the snapped phase via _on_state ONCE (reconciled is not separately bound to _on_state); no duplicate/zombie action submits, no double view_state/beat emit; the loop ends exactly where the authoritative state says.
- [Phase A / logic verifier] Stale-reconcile drop: a late validator reply for a superseded action is dropped by WarMatch._apply_seq; the Director never regresses past fresher optimistic state.
- [Phase A / logic verifier, golden] Offline determinism (parity): the same seed + same intent sequence yields identical 64-hex state hashes across two runs (and equals the TS-dist golden); the Director adds no nondeterminism — timers affect when an action fires, never which.
- [Phase A / SceneTree verifier] action_rejected paths are distinct (CORRECTED): request_declare_war at FLIP_MOMENT is DROPPED by the Director's beat-guard and never reaches WarMatch (no action_rejected); request_special with an UNOWNED id at FLIP_MOMENT IS beat-legal, so it reaches WarMatch and the ENGINE rejects it (action_rejected fires, state unchanged). The loop continues in both cases.
- [Phase A / SceneTree verifier] Game over + replay: PLAY AGAIN (the newly-added result-overlay button) deals a fresh match (new seed, back to STAGING); CONTINUE TO LOBBY calls GameState.record_match_played() exactly once and routes home via UiRouter.
- [Phase A / SceneTree verifier] View-wiring regression: table.gd no longer calls WarMatch directly, and a fresh deal STAGES (start_round) before any flip is possible (guards the fixed start_new_game / dealt->flip bug); a non-empty 'dealt' state renders.
- [Phase A / logic verifier] Headless driveability preserved: WarDebug plays a complete match via start_round/flip/resolve/ack_war with no Director and no presentation — the deterministic loop does not depend on the Director.
- [Phase B / wire-golden verifier] godobuf round-trip: a Hermes ClientMessage/ServerMessage carrying each ValidatorService request/response round-trips byte-identically against a TS-emitted golden frame; the inner *_json fields survive verbatim (the hash domain). Guards the field-name drift that breaks the current hand-rolled JSON frame.
- [Phase B / live-local verifier] Online ACK path: with the real validator attached, a normal match yields a matched ACK (hash_matched) for every submitted action (start_round/flip/resolve/ack_war/play_special) and triggers zero reconciles. Use a create_timer watchdog.
- [Phase B / live-local verifier] match_id/player_id threading: match_id + player_id captured at InitMatch are echoed on every ValidateAction and CompleteMatch; a ValidateAction with a missing/wrong match_id is NOT_FOUND and one from a non-bound player is PlayerBindingError.
- [Phase B / live-local verifier] Server-assigned seed (merged): an online InitMatch with an EMPTY seed returns an authoritative state whose state.seed the client adopts verbatim; the client's t0 deal hash equals the server's (parity); the client does NOT pre-deal before InitMatch returns; offline still self-generates a fresh local seed and plays unchanged.
- [Phase B / live-local verifier] Reconcile reply alignment: on a forced divergence the client reads authoritative_state_json (NOT state_json) and snaps, and the snapped state re-hashes to the server's hash; ok:false on an illegal action is distinguished from a hash mismatch; server events_json is surfaced WITHOUT double-emitting the optimistic events already played for that action.
- [Phase B / live-local verifier] CompleteMatch on terminal: reaching player_win/cpu_win fires complete_match(match_id, player_id) exactly once; the server's stored match closes (idempotent with its terminal auto-complete); the GAME_OVER beat does not block on the reply.
- [Phase B / live-local verifier] Confirmed-online handshake + one codepath: the online flag flips true ONLY after the InitMatch ack; moves are held during the handshake so the registered starting state is the one the server replays from; local (ws://localhost:5555) and a mocked gateway path differ only by base_url + token — RPC shapes, correlation, and reconcile behavior are byte-identical.
- [Phase B / SceneTree verifier] Offline degradation (dead port): pointing at ws://127.0.0.1:9, or dropping the socket mid-match, keeps the match fully playable offline — input is never permanently locked, the online flag goes false, and the engine stays the source of truth.
- [Phase B / live-local verifier] Reconnect degrade + re-init: dropping the socket mid-match degrades to offline; re-initing goes back online with no double-applied action and the loop resumes at the correct phase. (A GetMatchState resume RPC is out of scope for v1.)

## Failed
_None._

## References
_None._

## Child pages
_None._
