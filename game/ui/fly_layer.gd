class_name WarCardFlyLayer
extends Control
##
## WarCardFlyLayer — a transient overlay that plays card-movement animations on top
## of the (already-correct) static table. It owns ONE tween and a list of ephemeral
## flying card nodes, and is force-cleared on every authoritative re-render so the
## static table.gd `_render` stays total + idempotent and a reconcile snap never
## leaves a stranded or duplicated card.
##
## The layer is mouse-transparent and sits ABOVE the table but BELOW the war/result
## overlays and the skip-catcher. It knows nothing about game rules — the view hands
## it source/dest screen rects and it tweens a card-back between them.

const CardVisual := preload("res://ui/card_visual.gd")

## One tween PER flight. Reusing a single tween for several flights fails — Godot
## 4 rejects appending a step to a tween that has already started ("Can't append to
## a Tween that has started"), which is exactly what two simultaneous fly_back calls
## (both players' draw-in, or a two-card win-sweep) would do.
var _tweens: Array = []
var _flights: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Kill every running tween and free every in-flight card. Idempotent and total —
## safe to call when idle, mid-flight, or already cleared. Called before every
## re-render (normal advance and reconcile snap) and at the start of each play.
func clear() -> void:
	for tw in _tweens:
		if tw != null and tw.is_valid():
			tw.kill()
	_tweens.clear()
	for n in _flights:
		if is_instance_valid(n):
			# Remove from the tree synchronously (queue_free is deferred) so no stranded
			# card lingers for a frame before the authoritative re-render.
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
	_flights.clear()


## Fly a face-down card from `from_rect` to `to_rect` over `dur` seconds (after an
## optional `delay`). Screen rects come from the static slots' get_global_rect();
## a degenerate (zero-size) rect means layout is not ready yet, so the flight is
## skipped (the static render is already correct).
func fly_back(from_rect: Rect2, to_rect: Rect2, dur: float, delay := 0.0) -> void:
	if from_rect.size == Vector2.ZERO or to_rect.size == Vector2.ZERO or dur <= 0.0:
		return
	var card := CardVisual.make_flying_back(from_rect.size)
	add_child(card)
	card.global_position = from_rect.position
	_flights.append(card)
	var tw := create_tween()
	_tweens.append(tw)
	var step := tw.tween_property(card, "global_position", to_rect.position, dur)
	step.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	if delay > 0.0:
		step.set_delay(delay)
	# Free just this card when its own flight finishes (the identical static card
	# underneath shows through). kill() from clear() does NOT emit finished.
	tw.finished.connect(_on_flight_finished.bind(card, tw))


func _on_flight_finished(card: Node, tw: Tween) -> void:
	if is_instance_valid(card):
		if card.get_parent() != null:
			card.get_parent().remove_child(card)
		card.queue_free()
	_flights.erase(card)
	_tweens.erase(tw)
