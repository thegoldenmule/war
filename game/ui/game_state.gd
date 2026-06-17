extends Node
## GameState — the cross-screen meta-state AUTOLOAD (res://ui/game_state.gd,
## registered as `GameState` in project.godot). Holds the player-facing meta layer
## that lives OUTSIDE a match: soft currency (Gems), a thin profile, and a settings
## mirror. Screens read these and listen to the change signals.
##
## HARD WALL: this is META state, not the deterministic match state. It never holds
## or mutates the synchronized game state (that is WarMatch/WarEngine's domain). In
## the full game these values are server-authoritative (Snapser Inventory/Profile);
## here they are a local skeleton. # TODO(skeleton): back gems/profile with Snapser.

## Gem wallet changed; payload is the new total.
signal gems_changed(amount: int)
## Profile counters changed (matches played, xp, ...).
signal profile_changed()

## Starter wallet for the skeleton so the HUD shows something.
const STARTER_GEMS := 100

## Soft currency. Server-authoritative in production; never minted client-side then.
var gems: int = 0
## Lifetime matches entered (drives daily challenges / profile later).
var matches_played: int = 0
## Local settings mirror (audio toggles, etc.). # TODO(skeleton): persist + sync.
var settings: Dictionary = {"sfx": true, "music": true}


func _ready() -> void:
	gems = STARTER_GEMS
	gems_changed.emit(gems)


## Credit gems (e.g. a match reward or daily bonus). Authoritative grants flow
## through here after the server confirms them.
func add_gems(amount: int) -> void:
	if amount == 0:
		return
	gems += amount
	gems_changed.emit(gems)


## Attempt to spend gems; returns false (and changes nothing) if the wallet is short.
func spend_gems(amount: int) -> bool:
	if amount <= 0 or gems < amount:
		return false
	gems -= amount
	gems_changed.emit(gems)
	return true


## Record that a match was entered/finished (called by the table on exit).
func record_match_played() -> void:
	matches_played += 1
	profile_changed.emit()
