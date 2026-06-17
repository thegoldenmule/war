extends Node
## Boot — the project entry point (res://ui/boot.tscn is the main scene set in
## project.godot). It mounts the UiRouter stage under itself and routes to the home
## screen. Everything visual lives in the screens; this node is just the bootstrap.
##
## The three autoloads (GameState, UiRouter, WarDebug) are already alive before this
## runs; Boot only needs to give the router a place to mount screens and kick off the
## first navigation.
##
## HARD WALL: pure bootstrap/presentation — never touches deterministic match state.

func _ready() -> void:
	print("[Boot] War — entering lobby")
	UiRouter.ensure_stage(self)
	UiRouter.goto("home")
