extends Control
## Table — the GAME TABLE screen (res://ui/screens/table.tscn). A render-ONLY view:
## it owns a WarRoundDirector (the presentation-tier sequencer), renders whatever
## snapshot the Director hands it, and forwards player taps as Director INTENTS. It
## never touches WarMatch or the engine directly and never re-implements rules.
##
## RENDERING MODEL (one-way data flow, per the hard-wall contract):
##   tap → Director.request_* → WarMatch.submit_action → WarEngine.apply (pure) →
##   WarMatch emits state_changed → Director._on_state →
##     view_state(state) → _on_view_state: clear the fly layer, then _render(state)
##     beat(name, events, locked) → _on_beat: gate input, accrue the cosmetic win
##       pile, and play the card-movement animation for the beat.
## _render(state) is TOTAL + IDEMPOTENT and reads state (+ the clamped cosmetic win
## accumulator) only; animations live entirely on the transient _fly layer, which is
## force-cleared before every re-render — so a snap/reconcile re-renders cleanly.
##
## THREE PILES PER PLAYER (the visible model):
##   DRAWING DECK (the deck you draw from)  |  CURRENT CARD (the staked/revealed pot
##   card)  |  WIN DECK (cards you've won). The win deck is COSMETIC (see WarPileModel):
##   the engine recycles won cards to the bottom of the draw deck, so the win pile is a
##   clamped accumulator and draw + win always equals the deck (on-screen total = 52).
##
## STATE SHAPE consumed (the synchronized, hashed game state):
##   { version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot, rng:{seq},
##     specials:{player:[],cpu:[]}, pending_special, war_depth }.

const RoundDirector := preload("res://ui/round_director.gd")
const PileModel := preload("res://ui/pile_model.gd")
const CardVisual := preload("res://ui/card_visual.gd")
const FlyLayer := preload("res://ui/fly_layer.gd")
const TopBar := preload("res://ui/shell/top_bar.gd")
const AdBanner := preload("res://ui/shell/ad_banner.gd")
const MenuPanel := preload("res://ui/shell/menu_panel.gd")
const SafeArea := preload("res://ui/shell/safe_area.gd")
const HermesClient := preload("res://net/hermes_client.gd")
const SnapserAuth := preload("res://net/snapser_auth.gd")
const ValidatorClient := preload("res://net/validator_client.gd")

# ── Board card footprints (the central flip cards dominate; counts are mini badges) ──
const BIG_CARD_MIN := Vector2(200, 280)   # floor; the card grows to fill via AspectRatio
const BIG_CARD_FONT := 96
const BADGE_SIZE := Vector2(88, 118)
const BADGE_FONT := 40
const CARD_ASPECT := 0.72                  # ~5:7 playing-card ratio
const ACTION_BTN_HEIGHT := 132             # chunky primary CTAs (the mockup's tall buttons)
const ACTION_BTN_BOTTOM_GAP := 48          # gap below the buttons so they aren't flush to the edge

## Local validator Hermes endpoint reached by pressing V (dev affordance). The
## deployed build would point this at the Snapser gateway.
const LOCAL_VALIDATOR_WS := "ws://localhost:5555/hermes/ws"

## Flight durations are this fraction of the owning beat's tempo, so a card lands
## before the Director's auto-action fires the next state change.
const FLY_FRACTION := 0.82

# ── Sequencer + view state ─────────────────────────────────────────────────────
var _director: Node = null
var _state: Dictionary = {}
var _beat_name: int = RoundDirector.Beat.BOOT
## Cosmetic win-pile accumulator (NOT hashed state). Reset on a new match; clamped
## to the live deck sizes on every render (the recycle write-back).
var _won: Dictionary = {"player": 0, "cpu": 0}
var _prev_phase: String = ""

# ── Node refs (built in _ready) ───────────────────────────────────────────────
# Slim status line (the phase caption / guidance), kept below the board.
var _phase_label: Label = null
# Persistent chrome (reusable shell components) + the safe-area spacer bands.
var _top_bar: TopBar = null
var _ad_banner: AdBanner = null
var _menu: MenuPanel = null
var _safe_top: Control = null
var _safe_bottom: Control = null
# Per player: one BIG central flip card + small count badges. The win pile is cosmetic
# (won cards recycle into the draw deck), so CPU shows a SINGLE badge = its whole deck
# and `_cpu_win` aliases `_cpu_draw`; YOU show separate draw + win badges (the literal
# wireframe asymmetry). All six refs are kept so the fly layer's flights still resolve
# to real on-screen rects.
var _cpu_draw: Panel = null
var _cpu_draw_lbl: Label = null
var _cpu_card: Panel = null
var _cpu_card_label: Label = null
var _cpu_win: Panel = null          # aliases _cpu_draw (consolidated deck badge)
var _cpu_win_lbl: Label = null
var _player_draw: Panel = null
var _player_draw_lbl: Label = null
var _player_card: Panel = null
var _player_card_label: Label = null
var _player_win: Panel = null
var _player_win_lbl: Label = null
var _special_button: Button = null
var _action_button: Button = null
var _fly: Control = null
var _war_overlay: Control = null
var _result_overlay: Control = null
var _result_label: Label = null
var _skip_catcher: Button = null

# ── Online transport (built lazily on the first connect) ───────────────────────
var _validator: Node = null
var _online_requested: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_start_director()
	# Apply the device safe-area insets once layout has settled (a full-screen takeover
	# owns the raw viewport, so it insets its own header/footer — layout gate rule 5).
	# Re-run on rotation/resize since aspect=expand changes the surface per device.
	get_viewport().size_changed.connect(_sync_chrome_offsets)
	call_deferred("_sync_chrome_offsets")


## Dev affordance: press V to (re)connect this table to the local validator and
## play the rest online. Idempotent — a second press while connecting is ignored.
## The board is never frozen: the Director holds input only through the handshake
## and degrades to offline on any transport failure.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		_connect_online()


func _connect_online() -> void:
	if _online_requested:
		return
	_online_requested = true
	# Build the transport stack once and add it to the tree (the socket pump and
	# the client's frame-poll both need to process). Local mode self-stamps the
	# player id as the ?token= query param.
	var auth := SnapserAuth.new()
	auth.mode = SnapserAuth.Mode.LOCAL
	var hermes := HermesClient.new()
	hermes.base_url = LOCAL_VALIDATOR_WS
	_validator = ValidatorClient.new()
	add_child(auth)
	add_child(hermes)
	add_child(_validator)
	_validator.setup(hermes, auth)
	# A terminal client failure re-arms the affordance so the player can retry.
	_validator.client_error.connect(func(_reason): _online_requested = false)
	_director.connect_online(_validator)


func _start_director() -> void:
	_director = RoundDirector.new()
	_director.view_state.connect(_on_view_state)
	_director.beat.connect(_on_beat)
	add_child(_director)


# ── Layout ──────────────────────────────────────────────────────────────────--

func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = WarPalette.BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	# Root column: chrome bands (full width) + a padded board that takes the slack +
	# the action row, bracketed by the safe-area spacer bands. No outer margin — the
	# bands are edge-to-edge; only the board/actions are side-padded.
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 0)
	add_child(col)

	# Top safe-area inset (notch / status bar) — height set in _sync_chrome_offsets.
	_safe_top = _spacer(0)
	col.add_child(_safe_top)

	# ── Persistent chrome: top bar + ad banner ─────────────────────────────────
	_top_bar = TopBar.new()
	_top_bar.shop_pressed.connect(_on_shop_pressed)
	_top_bar.menu_pressed.connect(_on_menu_pressed)
	col.add_child(_top_bar)

	_ad_banner = AdBanner.new()
	col.add_child(_ad_banner)

	# ── Board: the central flip cards dominate the real estate ─────────────────
	var board_pad := MarginContainer.new()
	board_pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_pad.add_theme_constant_override("margin_left", 24)
	board_pad.add_theme_constant_override("margin_right", 24)
	board_pad.add_theme_constant_override("margin_top", 16)
	board_pad.add_theme_constant_override("margin_bottom", 8)
	col.add_child(board_pad)

	var board := VBoxContainer.new()
	board.add_theme_constant_override("separation", 16)
	board_pad.add_child(board)

	# CPU row: [deck badge] [BIG card] [spacer] — one badge (left), card centered.
	var cpu_row := _board_row(false)
	_cpu_draw = cpu_row["draw"]; _cpu_draw_lbl = cpu_row["draw_lbl"]
	_cpu_card = cpu_row["card"]; _cpu_card_label = cpu_row["card_lbl"]
	# CPU's win pile aliases its single deck badge (consolidated; see the ref comments).
	_cpu_win = _cpu_draw; _cpu_win_lbl = _cpu_draw_lbl
	board.add_child(cpu_row["row"])

	# YOU row: [draw badge] [BIG card] [win badge] — both badges, card centered.
	var you_row := _board_row(true)
	_player_draw = you_row["draw"]; _player_draw_lbl = you_row["draw_lbl"]
	_player_card = you_row["card"]; _player_card_label = you_row["card_lbl"]
	_player_win = you_row["win"]; _player_win_lbl = you_row["win_lbl"]
	board.add_child(you_row["row"])

	# ── Slim status line (phase caption / guidance) ────────────────────────────
	_phase_label = Label.new()
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_label.add_theme_color_override("font_color", WarPalette.INK)
	_phase_label.add_theme_font_size_override("font_size", 20)
	col.add_child(_phase_label)
	col.add_child(_spacer(8))

	# ── Action row: Use Special (the flip moment) + primary action ─────────────
	var actions_pad := MarginContainer.new()
	actions_pad.add_theme_constant_override("margin_left", 24)
	actions_pad.add_theme_constant_override("margin_right", 24)
	# Lift the buttons off the bottom edge (the mockup shows a clear gap below them). This
	# sits on top of the bottom safe inset, so on a device they clear the gesture bar too.
	actions_pad.add_theme_constant_override("margin_bottom", ACTION_BTN_BOTTOM_GAP)
	col.add_child(actions_pad)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	actions_pad.add_child(actions)
	_special_button = WarPalette.button("✦ USE SPECIAL", false, 26)
	_special_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_special_button.custom_minimum_size = Vector2(0, ACTION_BTN_HEIGHT)
	_special_button.pressed.connect(_on_special_pressed)
	actions.add_child(_special_button)
	_action_button = WarPalette.button("FLIP CARD", true, 30)
	_action_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action_button.custom_minimum_size = Vector2(0, ACTION_BTN_HEIGHT)
	_action_button.pressed.connect(_on_action_pressed)
	actions.add_child(_action_button)

	# Bottom safe-area inset (home indicator / gesture bar).
	_safe_bottom = _spacer(0)
	col.add_child(_safe_bottom)

	# ── Fly layer (above the table, below the overlays + skip-catcher) ─────────
	_fly = FlyLayer.new()
	add_child(_fly)

	# ── Hamburger dropdown (above the board, below the war/result overlays) ────
	_menu = MenuPanel.new()
	_menu.exit_pressed.connect(_on_exit_pressed)
	add_child(_menu)

	# ── Overlays + tap-catcher (top-most) ──────────────────────────────────────
	_war_overlay = _build_war_overlay()
	add_child(_war_overlay)
	_result_overlay = _build_result_overlay()
	add_child(_result_overlay)
	_skip_catcher = Button.new()
	_skip_catcher.flat = true
	_skip_catcher.focus_mode = Control.FOCUS_NONE
	_skip_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_skip_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_skip_catcher.visible = false
	_skip_catcher.pressed.connect(_on_skip_pressed)
	add_child(_skip_catcher)


## Build one player's board row: a small count badge, then the BIG central flip card
## (kept to a playing-card aspect by an AspectRatioContainer so it grows to fill the
## row height without distorting), then — for the player (`has_win`) — a second badge.
## The CPU row gets a fixed spacer in the win slot instead, so its single badge sits to
## the left while the big card stays screen-centered (the literal wireframe). Returns
## the row plus refs to the badge/card slots and their content Labels.
func _board_row(has_win: bool) -> Dictionary:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 16)

	var draw := CardVisual.make_slot(BADGE_SIZE, BADGE_FONT)
	draw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(draw)

	var arc := AspectRatioContainer.new()
	arc.ratio = CARD_ASPECT
	arc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var card := CardVisual.make_slot(BIG_CARD_MIN, BIG_CARD_FONT)
	arc.add_child(card)
	row.add_child(arc)

	var result := {
		"row": row,
		"draw": draw, "draw_lbl": draw.get_child(0) as Label,
		"card": card, "card_lbl": card.get_child(0) as Label,
	}

	if has_win:
		var win := CardVisual.make_slot(BADGE_SIZE, BADGE_FONT)
		win.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(win)
		result["win"] = win
		result["win_lbl"] = win.get_child(0) as Label
	else:
		# Balance the lone left badge so the big card stays centered.
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(BADGE_SIZE.x, 0)
		row.add_child(pad)

	return result


func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s


# ── Overlays ────────────────────────────────────────────────────────────────--

func _build_war_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	var dim := ColorRect.new()
	dim.color = WarPalette.SCRIM
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var banner := Panel.new()
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	banner.custom_minimum_size = Vector2(300, 120)
	banner.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL_HI, WarPalette.ACCENT, 4))
	var cry := Label.new()
	cry.text = "I. DECLARE. WAR."
	cry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cry.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cry.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cry.add_theme_color_override("font_color", WarPalette.ACCENT_DEEP)
	cry.add_theme_font_size_override("font_size", 38)
	banner.add_child(cry)
	overlay.add_child(banner)
	return overlay


func _build_result_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	var dim := ColorRect.new()
	dim.color = WarPalette.SCRIM
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var panel := Panel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(320, 260)
	panel.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL_HI, WarPalette.INK, 3))
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 18)
	_result_label = Label.new()
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 48)
	vbox.add_child(_result_label)
	var play_again := WarPalette.button("PLAY AGAIN", true, 22)
	play_again.pressed.connect(_on_play_again_pressed)
	vbox.add_child(play_again)
	var to_lobby := WarPalette.button("CONTINUE TO LOBBY", false, 18)
	to_lobby.pressed.connect(_on_continue_pressed)
	vbox.add_child(to_lobby)
	panel.add_child(vbox)
	overlay.add_child(panel)
	return overlay


# ── Render (driven by view_state — WHAT is on the table) ───────────────────────

func _on_view_state(state: Dictionary) -> void:
	# Tear down any in-flight animation BEFORE re-rendering: a fresh authoritative
	# state (normal advance or reconcile snap) must never leave a stranded card.
	if _fly != null:
		_fly.clear()
	var phase := String(state.get("phase", ""))
	var pdeck: int = (state.get("player_deck", []) as Array).size()
	var cdeck: int = (state.get("cpu_deck", []) as Array).size()
	# A new match resets the cosmetic accumulator BEFORE we look for a recycle, so a
	# fresh deal never reads as a spurious win->draw flip. (The Director drops the
	# new_game event from resting beats, so detect the restart by phase transition.)
	if (_prev_phase == "" or _is_terminal(_prev_phase)) and not _is_terminal(phase):
		_won = PileModel.empty()
	# A win->draw RECYCLE is a won-pile SATURATION going into this render — almost always
	# a draw (start_round/ack_war) that emptied the draw pile, which lands here, not on a
	# result beat (an award grows the deck AND the win pile equally, so it never saturates).
	# Detect it BEFORE _render's write-back resets the accumulator, render, then play the
	# reshuffle sweep — once, since the reset makes a re-render of the same state
	# non-saturated (idempotent / reconcile-safe).
	var recycled := PileModel.recycled_sides(_won, pdeck, cdeck)
	_render(state)
	if bool(recycled["player"]):
		_queue_recycle_anim("player")
	if bool(recycled["cpu"]):
		_queue_recycle_anim("cpu")


## Render the entire table from a state dictionary. Idempotent and total: reads
## state + the clamped cosmetic win accumulator only; never touches the fly layer.
func _render(state: Dictionary) -> void:
	_state = state
	var phase := String(state.get("phase", "—"))

	var pdeck: int = (state.get("player_deck", []) as Array).size()
	var cdeck: int = (state.get("cpu_deck", []) as Array).size()
	# Recycle write-back: pin the accumulator to what is actually held, flipping a
	# saturated win pile back to the draw pile (recycle is pure + idempotent). The new-
	# match reset and the recycle-animation edge-detection live in _on_view_state.
	_won = PileModel.recycle(_won, pdeck, cdeck)
	_paint_piles()

	# Current cards: the staked pot card (face-down until flipped). Between rounds the pot
	# is empty, so the big slot shows the deck back (the next card to flip) while any card
	# remains — the dominant "BACK OF CARD" at rest — and only goes empty at a drained deck.
	_render_current(_cpu_card, _cpu_card_label, state.get("cpu_pot", []), cdeck)
	_render_current(_player_card, _player_card_label, state.get("player_pot", []), pdeck)
	_apply_win_loss(state.get("cpu_pot", []), state.get("player_pot", []))

	_phase_label.text = _phase_caption(phase, int(state.get("war_depth", 0)))

	if phase == "player_win" or phase == "cpu_win":
		_result_label.text = "VICTORY" if phase == "player_win" else "DEFEAT"
		_result_label.add_theme_color_override(
			"font_color", WarPalette.WIN if phase == "player_win" else WarPalette.LOSE)

	_prev_phase = phase


## Paint the count badges from the cosmetic counts. CPU gets a SINGLE badge showing its
## whole deck (draw + win — won cards recycle into the draw deck, so the split is moot
## on that side); YOU get separate draw + win badges (the literal wireframe layout).
func _paint_piles() -> void:
	var pdeck: int = (_state.get("player_deck", []) as Array).size()
	var cdeck: int = (_state.get("cpu_deck", []) as Array).size()
	var piles := PileModel.counts(_won, pdeck, cdeck)
	CardVisual.paint_count(_cpu_draw, _cpu_draw_lbl, cdeck)
	CardVisual.paint_count(_player_draw, _player_draw_lbl, int(piles["player"]["draw"]))
	CardVisual.paint_count(_player_win, _player_win_lbl, int(piles["player"]["win"]))


## Paint a current-card slot from a pot: the staked top card (face-up if revealed). With
## no card staged, show the deck back while `deck_count` cards remain (the resting "BACK
## OF CARD"), or an empty placeholder once the deck is drained.
func _render_current(slot: Panel, label: Label, pot: Variant, deck_count: int) -> void:
	if not (pot is Array) or (pot as Array).is_empty():
		if deck_count > 0:
			CardVisual.paint_back(slot, label)
		else:
			CardVisual.paint_empty(slot, label)
		return
	var card: Dictionary = (pot as Array).back()
	if bool(card.get("face_up", false)):
		CardVisual.paint_face(slot, label, card)
	else:
		CardVisual.paint_back(slot, label)


## When both current cards are face-up, outline the higher rank green and lower red.
func _apply_win_loss(cpu_pot: Variant, player_pot: Variant) -> void:
	if not (cpu_pot is Array) or not (player_pot is Array):
		return
	if (cpu_pot as Array).is_empty() or (player_pot as Array).is_empty():
		return
	var cc: Dictionary = (cpu_pot as Array).back()
	var pc: Dictionary = (player_pot as Array).back()
	if not bool(cc.get("face_up", false)) or not bool(pc.get("face_up", false)):
		return
	var cr := int(cc.get("rank", 0))
	var pr := int(pc.get("rank", 0))
	if cr == pr:
		return  # tie → WAR; leave both neutral
	var cpu_color: Color = WarPalette.WIN if cr > pr else WarPalette.LOSE
	var player_color: Color = WarPalette.WIN if pr > cr else WarPalette.LOSE
	_cpu_card.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_FACE, cpu_color, 4))
	_player_card.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_FACE, player_color, 4))


func _phase_caption(phase: String, war_depth: int) -> String:
	match phase:
		"dealt": return "YOUR DRAW · tap FLIP to draw & reveal"
		"selected": return "DRAWING…"
		"flipped": return "REVEALED"
		"war": return "WAR · depth %d" % war_depth
		"player_win": return "YOU WIN"
		"cpu_win": return "CPU WINS"
		_: return phase.to_upper()


func _is_terminal(phase: String) -> bool:
	return phase == "player_win" or phase == "cpu_win"


# ── Beat (driven by beat — input gating + animations) ──────────────────────────

func _on_beat(beat_id: int, events: Array, locked: bool) -> void:
	_beat_name = beat_id
	var B := RoundDirector.Beat

	# Primary action button: "FLIP CARD" at the DEAL_PROMPT draw moment (and on the
	# special-window FLIP_MOMENT, which arrives unlocked); "DECLARE WAR" at the war
	# prompt; disabled on every auto/locked beat.
	match beat_id:
		B.DEAL_PROMPT:
			_action_button.text = "FLIP CARD"
			_action_button.disabled = false
		B.FLIP_MOMENT:
			_action_button.text = "FLIP CARD"
			_action_button.disabled = locked   # enabled only on the special-window path
		B.WAR_PROMPT:
			_action_button.text = "DECLARE WAR"
			_action_button.disabled = locked   # a runaway (deep) war auto-acks: button off
		_:
			_action_button.text = "—"
			_action_button.disabled = true

	# USE SPECIAL — legal only at the flip moment with an owned, unstaged special (so
	# only when FLIP_MOMENT arrives unlocked; owned.is_empty() keeps it off in basic).
	var owned: Array = _state.get("specials", {}).get("player", [])
	var has_pending := _state.get("pending_special", null) != null
	_special_button.disabled = beat_id != B.FLIP_MOMENT or has_pending or owned.is_empty()

	_war_overlay.visible = (beat_id == B.WAR_BANNER or beat_id == B.WAR_REVEALING)
	_result_overlay.visible = (beat_id == B.GAME_OVER)
	_skip_catcher.visible = locked

	# Accrue the cosmetic win pile EXACTLY ONCE per apply: only on the result/terminal
	# beat, never on WAR_REVEALING (a war win's award rides in both WAR_REVEALING and
	# ROUND_RESULT — accruing on both would double-count). The recycle write-back + paint
	# keep the counts honest; the recycle ANIMATION is detected in _on_view_state (an
	# award grows deck and win equally, so it never saturates — recycles come from draws).
	if beat_id == B.ROUND_RESULT or beat_id == B.GAME_OVER:
		var pdeck: int = (_state.get("player_deck", []) as Array).size()
		var cdeck: int = (_state.get("cpu_deck", []) as Array).size()
		_won = PileModel.accrue(_won, events)
		_won = PileModel.recycle(_won, pdeck, cdeck)
		_paint_piles()

	_play_beat_animation(beat_id, events)


## Animate the card movement for a beat. The static table is already correct (view_state
## fires before beat); flights are a cosmetic overlay torn down on the next re-render.
func _play_beat_animation(beat_id: int, events: Array) -> void:
	if _fly == null:
		return
	var B := RoundDirector.Beat
	match beat_id:
		B.DRAWING:
			# The tap drew a card: it flies from each drawing deck into the current slot,
			# both sides, just before the auto-flip reveals them.
			_fly.fly_back(_cpu_draw.get_global_rect(), _cpu_card.get_global_rect(), _fly_dur("stage"))
			_fly.fly_back(_player_draw.get_global_rect(), _player_card.get_global_rect(), _fly_dur("stage"))
		B.WAR_REVEALING:
			# War stake: more cards move from the draw decks into the current area.
			_fly.fly_back(_cpu_draw.get_global_rect(), _cpu_card.get_global_rect(), _fly_dur("war_stake"))
			_fly.fly_back(_player_draw.get_global_rect(), _player_card.get_global_rect(), _fly_dur("war_stake"))
		B.ROUND_RESULT:
			# Win-sweep: BOTH current cards move into the winner's win deck.
			var winner := _award_winner(events)
			if winner != "":
				var dest: Panel = _player_win if winner == "player" else _cpu_win
				var dur := _fly_dur("result")
				_fly.fly_back(_cpu_card.get_global_rect(), dest.get_global_rect(), dur)
				_fly.fly_back(_player_card.get_global_rect(), dest.get_global_rect(), dur, 0.05)


## The winner named by an award event in this apply (or "" if none).
func _award_winner(events: Array) -> String:
	for ev in events:
		if String((ev as Dictionary).get("type", "")) == "award":
			return String((ev as Dictionary).get("winner", ""))
	return ""


## Recycle flourish: when a side's win deck flips to become its new drawing deck, sweep
## a couple of cards from the win slot onto the draw slot. Cosmetic; the static counts
## are already correct (counts() applies the recycle), so a skipped flight is harmless.
func _queue_recycle_anim(who: String) -> void:
	if _fly == null:
		return
	var win_slot: Panel = _player_win if who == "player" else _cpu_win
	var draw_slot: Panel = _player_draw if who == "player" else _cpu_draw
	# CPU consolidates win+draw into one badge, so a recycle sweep would fly in place —
	# nothing to show.
	if win_slot == draw_slot:
		return
	var from := win_slot.get_global_rect()
	var to := draw_slot.get_global_rect()
	# A short flurry of staggered card-backs reads as the win pile flipping over into the
	# draw pile. Kept within the draw-in window (the 'stage' tempo) so it isn't clipped by
	# the auto-flip that follows the same tap.
	var dur := _fly_dur("stage")
	for i in range(4):
		_fly.fly_back(from, to, dur, i * 0.03)


## Flight duration: a fraction of the owning beat's tempo (kept coupled to the
## Director's TEMPO/SPEED so a tempo change keeps flights finishing in time).
func _fly_dur(key: String) -> float:
	return float(RoundDirector.TEMPO[key]) * float(RoundDirector.SPEED) * FLY_FRACTION


# ── Input → Director intents ───────────────────────────────────────────────────

func _on_action_pressed() -> void:
	match _beat_name:
		RoundDirector.Beat.DEAL_PROMPT:
			_director.request_deal_and_flip()
		RoundDirector.Beat.FLIP_MOMENT:
			_director.request_flip()
		RoundDirector.Beat.WAR_PROMPT:
			_director.request_declare_war()


func _on_special_pressed() -> void:
	var owned: Array = _state.get("specials", {}).get("player", [])
	if owned.is_empty():
		return
	_director.request_special(String(owned.front()))


func _on_skip_pressed() -> void:
	_director.request_skip()


func _on_play_again_pressed() -> void:
	_director.request_play_again()


func _on_continue_pressed() -> void:
	_director.request_quit()


# ── Chrome (top bar + hamburger menu) ──────────────────────────────────────────

func _on_shop_pressed() -> void:
	# TODO(skeleton): push("shop") once the store screen lands.
	print("[Table] shop tapped (placeholder)")


func _on_menu_pressed() -> void:
	if _menu != null:
		_menu.toggle()


## EXIT GAME from the hamburger menu — leave the match back to the lobby (the old
## back button's behavior).
func _on_exit_pressed() -> void:
	_director.request_quit()


## Push the device safe-area insets into the spacer bands and drop the menu below the
## top bar. Idempotent; re-run on resize/rotation (insets are 0 on desktop/editor).
func _sync_chrome_offsets() -> void:
	var insets := SafeArea.insets(self)
	if _safe_top != null:
		_safe_top.custom_minimum_size = Vector2(0, float(insets["top"]))
	if _safe_bottom != null:
		_safe_bottom.custom_minimum_size = Vector2(0, float(insets["bottom"]))
	if _menu != null and _top_bar != null:
		_menu.top_inset = float(insets["top"]) + _top_bar.size.y
		_menu._reposition()
