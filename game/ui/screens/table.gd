extends Control
## Table — the GAME TABLE screen (res://ui/screens/table.tscn). The only screen
## that touches a running match, and it does so ONLY through the runtime
## controller (WarMatch) / the WarDebug autoload — it NEVER re-implements rules.
##
## RENDERING MODEL (one-way data flow, per the contract):
##   input → WarMatch.<action> → WarEngine.apply (pure) → new state + hash →
##   WarMatch emits `state_changed(state)` → _render(state).
## The screen holds no authoritative state of its own; every visual is derived
## from the last `state` dictionary handed to _render(). Gameplay rendering here
## is intentionally schematic (counts + a flip slot + overlays) — see the
## "# TODO(skeleton)" markers for the polish passes.
##
## STATE SHAPE consumed (the synchronized, hashed game state):
##   { version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot,
##     rng:{seq}, specials:{player:[],cpu:[]}, pending_special, war_depth }
##   phase ∈ "dealt"|"selected"|"flipped"|"war"|"player_win"|"cpu_win".
##   Card = { rank:2..14, suit:"clubs"|..., face_up:bool }; deck index 0 = top.
##
## ACTIONS driven (unified player/CPU input schema { type, ...args }):
##   new_game{seed} · start_round · play_special{id} · flip · resolve · ack_war.
## We call them via thin WarMatch helpers (start_new_game/start_round/...), each
## guarded so the screen still loads while WarMatch is mid-authoring.
##
## Occult-arcade styling, mirroring the editor_tool_kit palette.

# ── Palette ───────────────────────────────────────────────────────────────────
const VIOLET := Color("b400ff")
const VIOLET_HOVER := Color("d24bff")
const VIOLET_DEEP := Color("43005d")
const GREEN_SEL := Color("44ff88")
const BG := Color("13111c")
const PANEL_BG := Color(0.078, 0.078, 0.110)
const PANEL_HI := Color(0.137, 0.125, 0.227)
const TEXT := Color(0.925, 0.925, 0.957)
const TEXT_DIM := Color(0.55, 0.5, 0.6)
const EMPHASIS := Color(1, 1, 1)

## Path to the runtime match controller (class_name WarMatch). Loaded lazily so a
## missing file (parallel authoring) degrades gracefully into "schematic only".
const MATCH_CONTROLLER_PATH := "res://game/match_controller.gd"

## Suit → glyph for the schematic card face.
const SUIT_GLYPH := {
	"clubs": "♣",
	"diamonds": "♦",
	"hearts": "♥",
	"spades": "♠",
}
## Rank → label for face cards / ace.
const RANK_LABEL := {11: "J", 12: "Q", 13: "K", 14: "A"}

# ── Match wiring ────────────────────────────────────────────────────────────--

## The live match controller instance (a WarMatch). Null when the controller
## script is unavailable (skeleton-degraded mode).
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

## Instantiate the WarMatch controller (if available), connect its state signal,
## and deal a fresh match. Falls back to schematic-empty when the controller
## script can't be loaded yet.
func _start_match() -> void:
	var packed := load(MATCH_CONTROLLER_PATH)
	if packed != null and (packed is Script):
		_match = (packed as Script).new()
		if _match is Node:
			add_child(_match)
		# WarMatch emits `state_changed(state: Dictionary)` after every applied
		# action — our single render entry point.
		if _match.has_signal("state_changed"):
			_match.state_changed.connect(_on_state_changed)
		_call_match("start_new_game", [_new_seed()])
	else:
		push_warning("[Table] WarMatch unavailable — rendering schematic empty table.")
		_render({})


## Pick a deterministic-but-fresh seed string for a new match. The validator
## reseeds from this; the same seed reproduces the same shuffle on both sides.
func _new_seed() -> String:
	return "match-%d" % Time.get_ticks_usec()


## Invoke a WarMatch helper by name iff it exists, returning its result (or null).
## Keeps the screen resilient to the controller's exact helper set while it is
## being authored in parallel.
func _call_match(method: String, args: Array = []) -> Variant:
	if _match != null and _match.has_method(method):
		return _match.callv(method, args)
	push_warning("[Table] WarMatch.%s() unavailable" % method)
	return null


# ── Layout ──────────────────────────────────────────────────────────────────--

func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = BG
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
	var back := _make_button("‹ HOME", false)
	back.pressed.connect(_on_back_pressed)
	topbar.add_child(back)
	_phase_label = Label.new()
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_phase_label.add_theme_color_override("font_color", VIOLET_HOVER)
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

	# ── Center: VS divider ─────────────────────────────────────────────────────
	var vs := Label.new()
	vs.text = "— vs —"
	vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs.add_theme_color_override("font_color", TEXT_DIM)
	col.add_child(vs)

	col.add_child(_spacer(4))

	# ── Player pile ─────────────────────────────────────────────────────────────
	_player_card = _make_card_slot()
	_player_card_label = _player_card.get_child(0)
	col.add_child(_center(_player_card))
	_player_count = _make_pile_label("YOU")
	col.add_child(_player_count)

	col.add_child(_spacer(8))

	# ── Action row: Play Special (the flip moment) + primary action ────────────
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	_special_button = _make_button("✦ PLAY SPECIAL", false)
	_special_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_special_button.pressed.connect(_on_special_pressed)
	actions.add_child(_special_button)
	_action_button = _make_button("FLIP", true)
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
	l.add_theme_color_override("font_color", TEXT)
	l.add_theme_font_size_override("font_size", 20)
	l.set_meta("prefix", prefix)
	l.text = "%s: --" % prefix
	return l


## A face-down/flip card slot — a bordered violet panel with a centered label
## that shows the rank+suit when face_up, or the arcane back when face-down.
func _make_card_slot() -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(140, 196)
	p.add_theme_stylebox_override("panel", _box(PANEL_HI, VIOLET))
	var l := Label.new()
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 40)
	l.add_theme_color_override("font_color", EMPHASIS)
	p.add_child(l)
	return p


## Wrap a control so it is horizontally centered within a full-width row.
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

## The WAR overlay placeholder — full-screen violet wash with the war cry. Shown
## while phase == "war". # TODO(skeleton): stake animation, war_depth pips, the
## 3-down/1-up reveal.
func _build_war_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	var dim := ColorRect.new()
	dim.color = Color(VIOLET_DEEP.r, VIOLET_DEEP.g, VIOLET_DEEP.b, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var cry := Label.new()
	cry.text = "I. DECLARE. WAR."
	cry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cry.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cry.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cry.add_theme_color_override("font_color", EMPHASIS)
	cry.add_theme_font_size_override("font_size", 48)
	overlay.add_child(cry)
	return overlay


## Game-over overlay (player_win / cpu_win): result text + a "to lobby" button.
func _build_result_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	var dim := ColorRect.new()
	dim.color = Color(BG.r, BG.g, BG.b, 0.92)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	_result_label = Label.new()
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 52)
	vbox.add_child(_result_label)
	var to_lobby := _make_button("TO LOBBY", true)
	to_lobby.pressed.connect(_on_back_pressed)
	vbox.add_child(to_lobby)
	overlay.add_child(vbox)
	return overlay


# ── Render (single entry point, driven by state_changed) ──────────────────────

func _on_state_changed(state: Dictionary) -> void:
	_render(state)


## Render the entire table from a state dictionary. Idempotent and total: a {}
## state renders an empty/idle table. This is the ONLY place the screen reads
## match state.
func _render(state: Dictionary) -> void:
	_state = state
	var phase := String(state.get("phase", "—"))

	# Deck counts (top labels). Index 0 = top of each deck.
	var pdeck: Array = state.get("player_deck", [])
	var cdeck: Array = state.get("cpu_deck", [])
	_cpu_count.text = "%s: %d cards" % [_cpu_count.get_meta("prefix"), cdeck.size()]
	_player_count.text = "%s: %d cards" % [_player_count.get_meta("prefix"), pdeck.size()]

	# Phase banner.
	_phase_label.text = _phase_caption(phase, int(state.get("war_depth", 0)))

	# Flip slots: show the staged top cards. Face-up reveals rank+suit; face-down
	# shows the arcane back. Empty state shows a dash.
	_render_card(_cpu_card, _cpu_card_label, _top_revealed(cdeck, state.get("cpu_pot", [])))
	_render_card(_player_card, _player_card_label, _top_revealed(pdeck, state.get("player_pot", [])))

	# Overlays.
	_war_overlay.visible = (phase == "war")
	var over := (phase == "player_win" or phase == "cpu_win")
	_result_overlay.visible = over
	if over:
		_result_label.text = "VICTORY" if phase == "player_win" else "DEFEAT"
		_result_label.add_theme_color_override(
			"font_color", GREEN_SEL if phase == "player_win" else VIOLET_HOVER)

	# Action buttons reflect the legal next move for this phase.
	_sync_actions(phase, state)


## The card to display in a flip slot: prefer the most recently revealed pot card
## (the staked face-up card), else the top of the deck. Returns null when empty.
func _top_revealed(deck: Array, pot: Array) -> Variant:
	if pot is Array and not pot.is_empty():
		return pot.back()
	if deck is Array and not deck.is_empty():
		return deck.front()
	return null


## Paint a card slot from a Card dict (or null). Face-down or null shows the back.
func _render_card(slot: Panel, label: Label, card: Variant) -> void:
	if card == null:
		label.text = "—"
		slot.add_theme_stylebox_override("panel", _box(PANEL_BG, VIOLET_DEEP))
		return
	var c: Dictionary = card
	if not bool(c.get("face_up", false)):
		# Arcane back for a face-down card (the flip moment lives here).
		label.text = "✶"
		label.add_theme_color_override("font_color", VIOLET_HOVER)
		slot.add_theme_stylebox_override("panel", _box(VIOLET_DEEP, VIOLET))
		return
	var rank := int(c.get("rank", 0))
	var suit := String(c.get("suit", ""))
	var glyph := String(SUIT_GLYPH.get(suit, "?"))
	var rank_txt := String(RANK_LABEL.get(rank, str(rank)))
	label.text = "%s\n%s" % [rank_txt, glyph]
	var red := (suit == "hearts" or suit == "diamonds")
	label.add_theme_color_override("font_color", VIOLET_HOVER if red else EMPHASIS)
	slot.add_theme_stylebox_override("panel", _box(PANEL_HI, VIOLET_HOVER))


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


## Enable/label the action + special buttons to match the legal next action for
## the current phase. The single primary button cycles flip → resolve →
## start_round; the special button is only live before the flip.
func _sync_actions(phase: String, state: Dictionary) -> void:
	var owned_specials: Array = state.get("specials", {}).get("player", [])
	var has_pending := state.get("pending_special", null) != null
	var over := (phase == "player_win" or phase == "cpu_win")

	# Special: legal only at the flip moment (face-down, pre-reveal) and when the
	# player still owns at least one and none is already staged.
	_special_button.disabled = over or phase != "dealt" or has_pending or owned_specials.is_empty()

	# Primary action follows the phase: dealt/selected → FLIP, flipped → RESOLVE,
	# war → DECLARE WAR (ack), win/loss → disabled (overlay drives the exit).
	match phase:
		"dealt", "selected":
			_action_button.text = "FLIP"
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
	# Map the primary button to the right action for the current phase.
	match String(_state.get("phase", "")):
		"dealt", "selected":
			_call_match("flip")
		"flipped":
			_call_match("resolve")
		"war":
			_call_match("ack_war")
		_:
			# No match yet (schematic) or terminal phase: deal a fresh round.
			_call_match("start_round")


func _on_special_pressed() -> void:
	# THE FLIP MOMENT: stake the first owned special before revealing. A real UI
	# would open a picker; the skeleton plays the first owned id.
	# TODO(skeleton): special-card picker drawer (the monetization surface).
	var owned: Array = _state.get("specials", {}).get("player", [])
	if owned.is_empty():
		return
	_call_match("play_special", [String(owned.front())])


func _on_back_pressed() -> void:
	# Returning to the lobby ends this match instance.
	GameState.record_match_played()
	UiRouter.goto("home")


# ── Styling helpers (shared idiom with home.gd) ───────────────────────────────

func _make_button(text: String, primary: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	var fill := VIOLET if primary else PANEL_BG
	var hover := VIOLET_HOVER if primary else PANEL_HI
	b.add_theme_stylebox_override("normal", _box(fill, VIOLET))
	b.add_theme_stylebox_override("hover", _box(hover, VIOLET_HOVER))
	b.add_theme_stylebox_override("pressed", _box(VIOLET_DEEP, VIOLET_HOVER))
	b.add_theme_stylebox_override("disabled", _box(PANEL_BG.darkened(0.3), VIOLET_DEEP))
	b.add_theme_stylebox_override("focus", _box(Color(0, 0, 0, 0), VIOLET_HOVER))
	b.add_theme_color_override("font_color", EMPHASIS if primary else TEXT)
	b.add_theme_color_override("font_hover_color", EMPHASIS)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	b.add_theme_font_size_override("font_size", 20 if primary else 16)
	return b


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(2)
	sb.border_color = border
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb
