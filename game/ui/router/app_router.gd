extends Node
## UiRouter — the screen router AUTOLOAD (res://ui/router/app_router.gd, registered
## as `UiRouter` in project.godot). Owns a single "stage" container and swaps the
## active screen into it.
##
## Flow: boot (or the debug scenes/main) calls `ensure_stage(host)` once to mount the
## stage, then `goto("home")`. Screens drive navigation with `goto(name)` (replace,
## clears history) or `push(name)` / `pop()` (modal-style back stack). Screen names
## map to packed scenes via SCREENS.
##
## HARD WALL: pure presentation/navigation — never touches deterministic match state.

## Emitted after the active screen changes (name is the new screen's key).
signal screen_changed(screen_name: String)

## Logical screen name -> packed scene. Add entries here as screens land.
const SCREENS := {
	"home": "res://ui/screens/home.tscn",
	"table": "res://ui/screens/table.tscn",
	# TODO(skeleton): "shop", "daily", "leaderboard", "collection".
}

## The container all screens mount into (full-rect, created by ensure_stage()).
var _stage: Control = null
## The currently mounted screen instance (freed on the next swap).
var _current: Control = null
var _current_name: String = ""
## Back stack for push()/pop().
var _history: Array[String] = []


## Create the stage under `host` (or reparent it there). Idempotent — safe to call
## from whichever scene becomes the entry point (ui/boot or scenes/main).
func ensure_stage(host: Node) -> void:
	if _stage != null and is_instance_valid(_stage):
		if _stage.get_parent() != host:
			_stage.get_parent().remove_child(_stage)
			host.add_child(_stage)
		return
	_stage = Control.new()
	_stage.name = "UiStage"
	_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(_stage)


## Replace the active screen (and clear the back stack).
func goto(screen_name: String) -> void:
	_history.clear()
	_swap(screen_name)


## Push a new screen, remembering the current one for pop().
func push(screen_name: String) -> void:
	if _current_name != "":
		_history.append(_current_name)
	_swap(screen_name)


## Return to the previous screen on the back stack (no-op if empty).
func pop() -> void:
	if _history.is_empty():
		return
	_swap(_history.pop_back())


func current_screen() -> String:
	return _current_name


# ── Internal ──────────────────────────────────────────────────────────────────-

func _swap(screen_name: String) -> void:
	if not SCREENS.has(screen_name):
		push_error("[UiRouter] unknown screen '%s'" % screen_name)
		return
	# Make sure we have somewhere to mount, even if ensure_stage() was skipped.
	if _stage == null or not is_instance_valid(_stage):
		var host: Node = get_tree().current_scene
		if host == null:
			host = get_tree().root
		ensure_stage(host)

	if _current != null and is_instance_valid(_current):
		_current.queue_free()
		_current = null

	var packed: Variant = load(SCREENS[screen_name])
	if packed == null or not (packed is PackedScene):
		push_error("[UiRouter] could not load scene for '%s'" % screen_name)
		return
	var inst: Node = (packed as PackedScene).instantiate()
	_stage.add_child(inst)
	_current = inst as Control
	_current_name = screen_name
	screen_changed.emit(screen_name)
