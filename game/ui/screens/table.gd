extends Control
## Table — the GAME TABLE screen (res://ui/screens/table.tscn). A render-ONLY view:
## it owns a WarRoundDirector (the presentation-tier sequencer), renders whatever
## snapshot the Director hands it, and forwards player taps as Director INTENTS. It
## never touches WarMatch or the engine directly and never re-implements rules.
##
## RENDERING MODEL (one-way data flow, per the hard-wall contract):
##   tap → Director.request_* → WarMatch.submit_action → WarEngine.apply (pure) →
##   WarMatch emits state_changed → Director._on_state →
##     view_state(state) → _render(state)            # WHAT is on the table
##     beat(name, events, locked) → _on_beat(...)    # WHEN/whether to allow input
## Crucially, button enable/label lives in _on_beat (driven by the beat + its
## `locked` flag), NOT in _render — so the render of a state and the input gate for
## a beat can never disagree mid-animation.
##
## STATE SHAPE consumed (the synchronized, hashed game state):
##   { version, seed, phase, player_deck, cpu_deck, player_pot, cpu_pot,
##     rng:{seq}, specials:{player:[],cpu:[]}, pending_special, war_depth }
##   Card = { rank:2..14, suit:"clubs"|..., face_up:bool }; deck index 0 = top.
##
## Visual style is the shared WarPalette (the reference look): a gray table, steel-blue
## card backs, off-white faces with black ink, an orange primary action, green/red
## win-loss outlines, and white modal banners for WAR and game over.

## The presentation-tier sequencer. Preloaded (not the class_name global) so this
## screen loads even before an editor scan has registered WarRoundDirector.
const RoundDirector := preload("res://ui/round_director.gd")

# ── Sequencer + last snapshot ─────────────────────────────────────────────────

## The live Round Director instance. Null only before _ready.
var _director: Node = null
## The most recently rendered state dictionary (empty until the first deal).
var _state: Dictionary = {}
## The most recent beat + its input-lock flag (set by _on_beat, read by taps).
var _beat_name: int = RoundDirector.Beat.BOOT

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
## Full-screen transparent tap-catcher: routes a tap to request_skip during
## transient/locked beats. Hidden (pass-through) at decision beats and game over.
var _skip_catcher: Button = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_start_director()


# ── Sequencer lifecycle ───────────────────────────────────────────────────────

func _start_director() -> void:
	_director = RoundDirector.new()
	# Connect BEFORE add_child: the Director deals in its own _ready (fired by
	# add_child) and emits the first view_state/beat synchronously.
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

	# ── Overlays (built last so they layer on top of the table) ────────────────
	_war_overlay = _build_war_overlay()
	add_child(_war_overlay)
	_result_overlay = _build_result_overlay()
	add_child(_result_overlay)

	# ── Tap-catcher (TOP-MOST): visible only on locked beats, so a tap anywhere
	# fast-forwards the armed auto-action. Hidden at decision beats / game over so
	# the buttons beneath (and the result overlay) receive taps normally.
	_skip_catcher = Button.new()
	_skip_catcher.flat = true
	_skip_catcher.focus_mode = Control.FOCUS_NONE
	_skip_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_skip_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_skip_catcher.visible = false
	_skip_catcher.pressed.connect(_on_skip_pressed)
	add_child(_skip_catcher)


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
## accent underlining it. Shown during the WAR_BANNER / WAR_REVEALING transient beats.
## (The detailed stake animation + war_depth pips belong to the I-Declare-War feature,
## which plugs into these beats.)
func _build_war_overlay() -> Control:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE  # the skip-catcher handles taps
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


## Game-over overlay (the GAME_OVER beat): a white banner with result text (green
## VICTORY / red DEFEAT) plus PLAY AGAIN (deal a fresh match) and CONTINUE TO LOBBY.
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
	_render(state)


## Render the entire table from a state dictionary. Idempotent and total: a {} state
## renders an empty/idle table. Reads state ONLY — never touches button enable/label
## or overlay visibility (those follow the beat in _on_beat).
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
	# When both are revealed, outline the higher rank green and the lower red. A tie
	# leaves both neutral (it goes to WAR).
	_apply_win_loss(cpu_card, player_card)

	# Result text follows the terminal phase; the overlay's VISIBILITY is the beat's job.
	if phase == "player_win" or phase == "cpu_win":
		_result_label.text = "VICTORY" if phase == "player_win" else "DEFEAT"
		_result_label.add_theme_color_override(
			"font_color", WarPalette.WIN if phase == "player_win" else WarPalette.LOSE)


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
		"dealt": return "DEALING…"
		"selected": return "FLIP MOMENT · play a special, or flip"
		"flipped": return "REVEALED"
		"war": return "WAR · depth %d" % war_depth
		"player_win": return "YOU WIN"
		"cpu_win": return "CPU WINS"
		_: return phase.to_upper()


# ── Beat (driven by beat — WHEN/whether input is allowed) ──────────────────────

## React to a beat change: set button enable/label, overlay visibility, and whether
## the tap-catcher is active. This is the SOLE owner of input gating, so it can never
## disagree with _render mid-animation.
func _on_beat(name: int, _events: Array, locked: bool) -> void:
	_beat_name = name
	var B := RoundDirector.Beat

	# Primary action button — enabled only at the two decision beats.
	match name:
		B.FLIP_MOMENT:
			_action_button.text = "FLIP CARD"
			_action_button.disabled = false
		B.WAR_PROMPT:
			_action_button.text = "DECLARE WAR"
			_action_button.disabled = false
		_:
			_action_button.text = "—"
			_action_button.disabled = true

	# USE SPECIAL — legal only at the flip moment with an owned, unstaged special.
	var owned: Array = _state.get("specials", {}).get("player", [])
	var has_pending := _state.get("pending_special", null) != null
	_special_button.disabled = name != B.FLIP_MOMENT or has_pending or owned.is_empty()

	# Overlays + tap-catcher follow the beat.
	_war_overlay.visible = (name == B.WAR_BANNER or name == B.WAR_REVEALING)
	_result_overlay.visible = (name == B.GAME_OVER)
	_skip_catcher.visible = locked


# ── Input → Director intents ───────────────────────────────────────────────────

func _on_action_pressed() -> void:
	match _beat_name:
		RoundDirector.Beat.FLIP_MOMENT:
			_director.request_flip()
		RoundDirector.Beat.WAR_PROMPT:
			_director.request_declare_war()


func _on_special_pressed() -> void:
	# THE FLIP MOMENT: stake the first owned special before revealing. A full UI opens
	# a picker; the basic loop plays the first owned id. (specials.player is empty in
	# the basic loop, so this button is disabled — the Special Cards feature fills it.)
	var owned: Array = _state.get("specials", {}).get("player", [])
	if owned.is_empty():
		return
	_director.request_special(String(owned.front()))


func _on_skip_pressed() -> void:
	# Tap anywhere during a transient/locked beat fast-forwards the armed auto-action.
	# request_skip is itself a no-op at decision beats, so this is always safe.
	_director.request_skip()


func _on_play_again_pressed() -> void:
	_director.request_play_again()


func _on_continue_pressed() -> void:
	_director.request_quit()


func _on_back_pressed() -> void:
	_director.request_quit()
