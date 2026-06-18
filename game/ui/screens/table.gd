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
var _phase_label: Label = null
# Per player: draw pile, current card, win pile (Panel) + their content Labels +
# the draw/win count captions.
var _cpu_draw: Panel = null
var _cpu_draw_lbl: Label = null
var _cpu_draw_cap: Label = null
var _cpu_card: Panel = null
var _cpu_card_label: Label = null
var _cpu_win: Panel = null
var _cpu_win_lbl: Label = null
var _cpu_win_cap: Label = null
var _player_draw: Panel = null
var _player_draw_lbl: Label = null
var _player_draw_cap: Label = null
var _player_card: Panel = null
var _player_card_label: Label = null
var _player_win: Panel = null
var _player_win_lbl: Label = null
var _player_win_cap: Label = null
var _special_button: Button = null
var _action_button: Button = null
var _fly: Control = null
var _war_overlay: Control = null
var _result_overlay: Control = null
var _result_label: Label = null
var _skip_catcher: Button = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_start_director()


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

	# ── CPU row: draw | current | win ──────────────────────────────────────────
	var cpu_row := _three_pile_row()
	_cpu_draw = cpu_row["draw"]; _cpu_draw_lbl = cpu_row["draw_lbl"]; _cpu_draw_cap = cpu_row["draw_cap"]
	_cpu_card = cpu_row["card"]; _cpu_card_label = cpu_row["card_lbl"]
	_cpu_win = cpu_row["win"]; _cpu_win_lbl = cpu_row["win_lbl"]; _cpu_win_cap = cpu_row["win_cap"]
	col.add_child(_label("CPU", 20, WarPalette.INK))
	col.add_child(cpu_row["row"])

	var vs := Label.new()
	vs.text = "— vs —"
	vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs.add_theme_color_override("font_color", WarPalette.INK_DIM)
	col.add_child(vs)

	# ── Player row: draw | current | win ───────────────────────────────────────
	var you_row := _three_pile_row()
	_player_draw = you_row["draw"]; _player_draw_lbl = you_row["draw_lbl"]; _player_draw_cap = you_row["draw_cap"]
	_player_card = you_row["card"]; _player_card_label = you_row["card_lbl"]
	_player_win = you_row["win"]; _player_win_lbl = you_row["win_lbl"]; _player_win_cap = you_row["win_cap"]
	col.add_child(you_row["row"])
	col.add_child(_label("YOU", 20, WarPalette.INK))

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

	# ── Fly layer (above the table, below the overlays + skip-catcher) ─────────
	_fly = FlyLayer.new()
	add_child(_fly)

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


## Build one player's row of three cells (draw | current | win). Returns the row
## HBox plus refs to each slot Panel, its content Label, and the draw/win captions.
func _three_pile_row() -> Dictionary:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	var draw := _pile_cell("DRAW")
	var card := _pile_cell("")
	var win := _pile_cell("WIN")
	row.add_child(draw["cell"])
	row.add_child(card["cell"])
	row.add_child(win["cell"])
	return {
		"row": row,
		"draw": draw["slot"], "draw_lbl": draw["lbl"], "draw_cap": draw["cap"],
		"card": card["slot"], "card_lbl": card["lbl"],
		"win": win["slot"], "win_lbl": win["lbl"], "win_cap": win["cap"],
	}


## One cell: a card slot above a caption label (empty caption for the current-card
## cell keeps all three columns vertically aligned).
func _pile_cell(caption: String) -> Dictionary:
	var cell := VBoxContainer.new()
	cell.alignment = BoxContainer.ALIGNMENT_CENTER
	cell.add_theme_constant_override("separation", 6)
	var slot := CardVisual.make_slot()
	cell.add_child(slot)
	var cap := Label.new()
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_color_override("font_color", WarPalette.INK)
	cap.add_theme_font_size_override("font_size", 15)
	cap.text = caption
	cell.add_child(cap)
	return {"cell": cell, "slot": slot, "lbl": slot.get_child(0) as Label, "cap": cap}


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	return l


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
	_render(state)


## Render the entire table from a state dictionary. Idempotent and total: reads
## state + the clamped cosmetic win accumulator only; never touches the fly layer.
func _render(state: Dictionary) -> void:
	_state = state
	var phase := String(state.get("phase", "—"))

	# Reset the cosmetic win piles when a NEW match starts: the first render, or a
	# transition out of a terminal phase (PLAY AGAIN). The Director drops the
	# new_game event from its resting-beat payload, so detect the restart by phase.
	if (_prev_phase == "" or _is_terminal(_prev_phase)) and not _is_terminal(phase):
		_won = PileModel.empty()

	var pdeck: int = (state.get("player_deck", []) as Array).size()
	var cdeck: int = (state.get("cpu_deck", []) as Array).size()
	# Recycle write-back: pin the accumulator to what is actually held.
	_won = PileModel.clamp_to(_won, pdeck, cdeck)
	_paint_piles()

	# Current cards: the staked pot card (face-down until flipped). Empty between rounds.
	_render_current(_cpu_card, _cpu_card_label, state.get("cpu_pot", []))
	_render_current(_player_card, _player_card_label, state.get("player_pot", []))
	_apply_win_loss(state.get("cpu_pot", []), state.get("player_pot", []))

	_phase_label.text = _phase_caption(phase, int(state.get("war_depth", 0)))

	if phase == "player_win" or phase == "cpu_win":
		_result_label.text = "VICTORY" if phase == "player_win" else "DEFEAT"
		_result_label.add_theme_color_override(
			"font_color", WarPalette.WIN if phase == "player_win" else WarPalette.LOSE)

	_prev_phase = phase


## Paint the four pile slots (draw + win for each player) from the cosmetic counts.
func _paint_piles() -> void:
	var pdeck: int = (_state.get("player_deck", []) as Array).size()
	var cdeck: int = (_state.get("cpu_deck", []) as Array).size()
	var piles := PileModel.counts(_won, pdeck, cdeck)
	_paint_pile(_cpu_draw, _cpu_draw_lbl, _cpu_draw_cap, "DRAW", int(piles["cpu"]["draw"]))
	_paint_pile(_cpu_win, _cpu_win_lbl, _cpu_win_cap, "WIN", int(piles["cpu"]["win"]))
	_paint_pile(_player_draw, _player_draw_lbl, _player_draw_cap, "DRAW", int(piles["player"]["draw"]))
	_paint_pile(_player_win, _player_win_lbl, _player_win_cap, "WIN", int(piles["player"]["win"]))


## A pile slot: a face-down back when it holds cards, a dim placeholder when empty;
## the caption shows the role + count.
func _paint_pile(slot: Panel, label: Label, cap: Label, role: String, count: int) -> void:
	if count > 0:
		CardVisual.paint_back(slot, label)
	else:
		CardVisual.paint_empty(slot, label)
	cap.text = "%s %d" % [role, count]


## Paint a current-card slot from a pot: the staked top card (face-up if revealed),
## or empty when no card is staged.
func _render_current(slot: Panel, label: Label, pot: Variant) -> void:
	if not (pot is Array) or (pot as Array).is_empty():
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
		"dealt": return "DEALING…"
		"selected": return "FLIP MOMENT · play a special, or flip"
		"flipped": return "REVEALED"
		"war": return "WAR · depth %d" % war_depth
		"player_win": return "YOU WIN"
		"cpu_win": return "CPU WINS"
		_: return phase.to_upper()


func _is_terminal(phase: String) -> bool:
	return phase == "player_win" or phase == "cpu_win"


# ── Beat (driven by beat — input gating + animations) ──────────────────────────

func _on_beat(name: int, events: Array, locked: bool) -> void:
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

	_war_overlay.visible = (name == B.WAR_BANNER or name == B.WAR_REVEALING)
	_result_overlay.visible = (name == B.GAME_OVER)
	_skip_catcher.visible = locked

	# Accrue the cosmetic win pile EXACTLY ONCE per apply: only on the result/terminal
	# beat, never on WAR_REVEALING (a war win's award rides in both WAR_REVEALING and
	# ROUND_RESULT — accruing on both would double-count).
	if name == B.ROUND_RESULT or name == B.GAME_OVER:
		_won = PileModel.accrue(_won, events)
		var pdeck: int = (_state.get("player_deck", []) as Array).size()
		var cdeck: int = (_state.get("cpu_deck", []) as Array).size()
		_won = PileModel.clamp_to(_won, pdeck, cdeck)
		_paint_piles()

	_play_beat_animation(name, events)


## Animate the card movement for a beat. The static table is already correct (view_state
## fires before beat); flights are a cosmetic overlay torn down on the next re-render.
func _play_beat_animation(name: int, events: Array) -> void:
	if _fly == null:
		return
	var B := RoundDirector.Beat
	match name:
		B.STAGING:
			# Draw a card from each drawing deck to the current-card slot, both sides.
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


## Flight duration: a fraction of the owning beat's tempo (kept coupled to the
## Director's TEMPO/SPEED so a tempo change keeps flights finishing in time).
func _fly_dur(key: String) -> float:
	return float(RoundDirector.TEMPO[key]) * float(RoundDirector.SPEED) * FLY_FRACTION


# ── Input → Director intents ───────────────────────────────────────────────────

func _on_action_pressed() -> void:
	match _beat_name:
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


func _on_back_pressed() -> void:
	_director.request_quit()
