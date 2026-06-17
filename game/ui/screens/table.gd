extends Control
## Table — the GAME TABLE screen (res://ui/screens/table.tscn). The only screen that
## touches a running match, and it does so ONLY through the runtime controller
## (WarMatch) / the WarDebug autoload — it NEVER re-implements rules.
##
## RENDERING MODEL (one-way data flow, per the contract):
##   input → WarMatch.<action> → WarEngine.apply (pure) → new state + hash →
##   WarMatch emits `state_changed(state)` → _render(state).
## The screen holds no authoritative state of its own; every visual is derived from
## the last `state` dictionary handed to _render(). Gameplay rendering is schematic
## (counts + flip slots + overlays) — see the "# TODO(skeleton)" markers.
##
## STATE SHAPE consumed (the synchronized, hashed game state):
##   { version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot,
##     rng:{seq}, specials:{player:[],cpu:[]}, pending_special, war_depth }
##   phase ∈ "dealt"|"selected"|"flipped"|"war"|"player_win"|"cpu_win".
##   Card = { rank:2..14, suit:"clubs"|..., face_up:bool }; deck index 0 = top.
##
## ACTIONS driven (unified player/CPU input schema { type, ...args }):
##   new_game{seed} · start_round · play_special{id} · flip · resolve · ack_war.
##
## Visual style is the shared WarPalette (the reference look): a gray table, steel-blue
## card backs, off-white faces with black ink, an orange primary action, and green/red
## win-loss outlines on revealed cards — with white modal banners for WAR and game over.

## Path to the runtime match controller (class_name WarMatch). Loaded lazily so a
## missing file degrades gracefully into "schematic only".
const MATCH_CONTROLLER_PATH := "res://game/match_controller.gd"

# ── Match wiring ────────────────────────────────────────────────────────────--

## The live match controller instance (a WarMatch). Null in schematic-degraded mode.
var _match: Object = null

## The most recently rendered state dictionary (empty until the first match).
var _state: Dictionary = {}

# ── Node refs (built in _ready) ───────────────────────────────────────────────
var _phase_label: Label = null
var _cpu_count: Label = null
var _player_count: Label = null
var _cpu_card: Panel = null
var _cpu_card_label: Label = null
var _player_card: Panel = null
var _player_card_label: Label = null
var _special_button: Button = null
var _action_button: Button = null
var _war_overlay: Control = null
var _result_overlay: Control = null
var _result_label: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_start_match()


# ── Match lifecycle ─────────────────────────────────────────────────────────--

func _start_match() -> void:
	var packed := load(MATCH_CONTROLLER_PATH)
	if packed != null and (packed is Script):
		_match = (packed as Script).new()
		if _match is Node:
			add_child(_match)
		if _match.has_signal("state_changed"):
			_match.state_changed.connect(_on_state_changed)
		_call_match("start_new_game", [_new_seed()])
	else:
		push_warning("[Table] WarMatch unavailable — rendering schematic empty table.")
		_render({})


## A deterministic-but-fresh seed string for a new match (the validator reseeds from it).
func _new_seed() -> String:
	return "match-%d" % Time.get_ticks_usec()


## Invoke a WarMatch helper by name iff it exists. Keeps the screen resilient to the
## controller's exact helper set.
func _call_match(method: String, args: Array = []) -> Variant:
	if _match != null and _match.has_method(method):
		return _match.callv(method, args)
	push_warning("[Table] WarMatch.%s() unavailable" % method)
	return null


# ── Layout ──────────────────────────────────────────────────────────────────--

func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = WarPalette.BG
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 24)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	margin.add_child(col)

	# ── Top bar: Back + phase ──────────────────────────────────────────────────
	var topbar := HBoxContainer.new()
	var back := WarPalette.button("‹ HOME", false, 16)
	back.pressed.connect(_on_back_pressed)
	topbar.add_child(back)
	_phase_label = Label.new()
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_phase_label.add_theme_color_override("font_color", WarPalette.INK)
	_phase_label.add_theme_font_size_override("font_size", 18)
	topbar.add_child(_phase_label)
	col.add_child(topbar)

	# ── CPU pile ───────────────────────────────────────────────────────────────
	_cpu_count = _make_pile_label("CPU")
	col.add_child(_cpu_count)
	_cpu_card = _make_card_slot()
	_cpu_card_label = _cpu_card.get_child(0)
	col.add_child(_center(_cpu_card))

	col.add_child(_spacer(4))

	var vs := Label.new()
	vs.text = "— vs —"
	vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs.add_theme_color_override("font_color", WarPalette.INK_DIM)
	col.add_child(vs)

	col.add_child(_spacer(4))

	# ── Player pile ─────────────────────────────────────────────────────────────
	_player_card = _make_card_slot()
	_player_card_label = _player_card.get_child(0)
	col.add_child(_center(_player_card))
	_player_count = _make_pile_label("YOU")
	col.add_child(_player_count)

	col.add_child(_spacer(8))

	# ── Action row: Use Special (the flip moment) + primary action ─────────────
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	_special_button = WarPalette.button("✦ USE SPECIAL", false, 18)
	_special_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_special_button.pressed.connect(_on_special_pressed)
	actions.add_child(_special_button)
	_action_button = WarPalette.button("FLIP CARD", true, 20)
	_action_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action_button.pressed.connect(_on_action_pressed)
	actions.add_child(_action_button)
	col.add_child(actions)

	# ── Overlays (built last so they layer on top) ─────────────────────────────
	_war_overlay = _build_war_overlay()
	add_child(_war_overlay)
	_result_overlay = _build_result_overlay()
	add_child(_result_overlay)


func _make_pile_label(prefix: String) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", WarPalette.INK)
	l.add_theme_font_size_override("font_size", 20)
	l.set_meta("prefix", prefix)
	l.text = "%s: --" % prefix
	return l


## A flip card slot — a bordered panel with a centered label. _render_card paints it
## as a blue back (face-down) or a light face (face-up) and may add a win/loss outline.
func _make_card_slot() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(140, 196)
	p.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL, WarPalette.INK_DIM))
	var l := Label.new()
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 40)
	l.add_theme_color_override("font_color", WarPalette.INK)
	p.add_child(l)
	return p


func _center(c: Control) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(c)
	return row


func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s


# ── Overlays ────────────────────────────────────────────────────────────────--

## The WAR overlay — a dim scrim with a white banner carrying the war cry, the orange
## accent underlining it. Shown while phase == "war". # TODO(skeleton): stake animation,
## war_depth pips, the 3-down/1-up reveal.
func _build_war_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	var dim := ColorRect.new()
	dim.color = WarPalette.SCRIM
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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


## Game-over overlay (player_win / cpu_win): a white banner with result text (green
## VICTORY / red DEFEAT) and a "continue to lobby" button — mirroring the reference.
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
	panel.custom_minimum_size = Vector2(320, 220)
	panel.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL_HI, WarPalette.INK, 3))
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	_result_label = Label.new()
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 48)
	vbox.add_child(_result_label)
	var to_lobby := WarPalette.button("CONTINUE TO LOBBY", true, 20)
	to_lobby.pressed.connect(_on_back_pressed)
	vbox.add_child(to_lobby)
	panel.add_child(vbox)
	overlay.add_child(panel)
	return overlay


# ── Render (single entry point, driven by state_changed) ──────────────────────

func _on_state_changed(state: Dictionary) -> void:
	_render(state)


## Render the entire table from a state dictionary. Idempotent and total: a {} state
## renders an empty/idle table. This is the ONLY place the screen reads match state.
func _render(state: Dictionary) -> void:
	_state = state
	var phase := String(state.get("phase", "—"))

	var pdeck: Array = state.get("player_deck", [])
	var cdeck: Array = state.get("cpu_deck", [])
	_cpu_count.text = "%s: %d cards" % [_cpu_count.get_meta("prefix"), cdeck.size()]
	_player_count.text = "%s: %d cards" % [_player_count.get_meta("prefix"), pdeck.size()]

	_phase_label.text = _phase_caption(phase, int(state.get("war_depth", 0)))

	# Flip slots: the staked top cards. Face-up reveals rank+suit; face-down shows the
	# blue back. Empty shows a dash.
	var cpu_card: Variant = _top_revealed(cdeck, state.get("cpu_pot", []))
	var player_card: Variant = _top_revealed(pdeck, state.get("player_pot", []))
	_render_card(_cpu_card, _cpu_card_label, cpu_card)
	_render_card(_player_card, _player_card_label, player_card)
	# When both are revealed, outline the higher rank green and the lower red (the
	# reference's win/loss read). A tie leaves both neutral (it goes to WAR).
	_apply_win_loss(cpu_card, player_card)

	_war_overlay.visible = (phase == "war")
	var over := (phase == "player_win" or phase == "cpu_win")
	_result_overlay.visible = over
	if over:
		_result_label.text = "VICTORY" if phase == "player_win" else "DEFEAT"
		_result_label.add_theme_color_override(
			"font_color", WarPalette.WIN if phase == "player_win" else WarPalette.LOSE)

	_sync_actions(phase, state)


## The card to display in a flip slot: prefer the staked face-up pot card, else the top
## of the deck. Returns null when empty.
func _top_revealed(deck: Array, pot: Array) -> Variant:
	if pot is Array and not pot.is_empty():
		return pot.back()
	if deck is Array and not deck.is_empty():
		return deck.front()
	return null


## Paint a card slot from a Card dict (or null). Null / face-down shows the blue back;
## face-up shows rank + suit glyph on a light face (red suits tinted).
func _render_card(slot: Panel, label: Label, card: Variant) -> void:
	if card == null:
		label.text = "—"
		label.add_theme_color_override("font_color", WarPalette.INK_DIM)
		slot.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.PANEL, WarPalette.INK_DIM))
		return
	var c: Dictionary = card
	if not bool(c.get("face_up", false)):
		# Steel-blue back for a face-down card (the flip moment lives here).
		label.text = "✦"
		label.add_theme_color_override("font_color", WarPalette.ON_DARK)
		slot.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_BACK, WarPalette.CARD_BACK_BORDER))
		return
	var rank := int(c.get("rank", 0))
	var suit := String(c.get("suit", ""))
	var glyph := String(WarPalette.SUIT_GLYPH.get(suit, "?"))
	var rank_txt := String(WarPalette.RANK_LABEL.get(rank, str(rank)))
	label.text = "%s\n%s" % [rank_txt, glyph]
	var red := (suit == "hearts" or suit == "diamonds")
	label.add_theme_color_override("font_color", WarPalette.RED_SUIT if red else WarPalette.INK)
	slot.add_theme_stylebox_override("panel", WarPalette.box(WarPalette.CARD_FACE, WarPalette.INK))


## When both staked cards are face-up, outline the winner green and the loser red.
func _apply_win_loss(cpu_card: Variant, player_card: Variant) -> void:
	if cpu_card == null or player_card == null:
		return
	var cc: Dictionary = cpu_card
	var pc: Dictionary = player_card
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


## Human-readable phase caption for the banner.
func _phase_caption(phase: String, war_depth: int) -> String:
	match phase:
		"dealt": return "DEALT · play a special, or flip"
		"selected": return "SPECIAL STAGED · flip"
		"flipped": return "FLIPPED · resolve"
		"war": return "WAR · depth %d" % war_depth
		"player_win": return "YOU WIN"
		"cpu_win": return "CPU WINS"
		_: return phase.to_upper()


## Enable/label the action + special buttons to match the legal next action.
func _sync_actions(phase: String, state: Dictionary) -> void:
	var owned_specials: Array = state.get("specials", {}).get("player", [])
	var has_pending := state.get("pending_special", null) != null
	var over := (phase == "player_win" or phase == "cpu_win")

	# Special: legal only at the flip moment (face-down, pre-reveal) with an owned,
	# unstaged special.
	_special_button.disabled = over or phase != "dealt" or has_pending or owned_specials.is_empty()

	match phase:
		"dealt", "selected":
			_action_button.text = "FLIP CARD"
			_action_button.disabled = false
		"flipped":
			_action_button.text = "RESOLVE"
			_action_button.disabled = false
		"war":
			_action_button.text = "DECLARE WAR"
			_action_button.disabled = false
		_:
			_action_button.text = "—"
			_action_button.disabled = true


# ── Input → actions ───────────────────────────────────────────────────────────

func _on_action_pressed() -> void:
	match String(_state.get("phase", "")):
		"dealt", "selected":
			_call_match("flip")
		"flipped":
			_call_match("resolve")
		"war":
			_call_match("ack_war")
		_:
			_call_match("start_round")


func _on_special_pressed() -> void:
	# THE FLIP MOMENT: stake the first owned special before revealing. A real UI opens
	# a picker; the skeleton plays the first owned id.
	# TODO(skeleton): special-card picker drawer (the monetization surface).
	var owned: Array = _state.get("specials", {}).get("player", [])
	if owned.is_empty():
		return
	_call_match("play_special", [String(owned.front())])


func _on_back_pressed() -> void:
	GameState.record_match_played()
	UiRouter.goto("home")
