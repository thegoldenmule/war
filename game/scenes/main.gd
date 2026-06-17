extends Node
## Main — OPTIONAL direct-to-table debug scene (res://scenes/main.gd +
## scenes/main.tscn). NOT the project entry point: the real main scene is
## res://ui/boot.tscn (set in project.godot). This scene exists so a developer or
## a headless harness can jump straight onto the game table, skipping the lobby.
##
## It does the minimum the router normally relies on: ensures the UiRouter stage
## is parented under THIS scene, then routes directly to "table" (which starts a
## fresh match through WarMatch). Run it manually in the editor, or headless:
##   godot --headless --path game res://scenes/main.tscn
##
## HARD WALL: still pure presentation/bootstrap — it drives UiRouter and never
## re-implements rules or touches deterministic state directly.

func _ready() -> void:
	print("[Main] DEBUG entry — booting straight to the table (real entry is ui/boot.tscn)")
	# The autoloads (GameState, UiRouter, WarDebug) exist regardless of which
	# scene is the main scene, so we can drive the router immediately.
	UiRouter.ensure_stage(self)
	UiRouter.goto("table")
