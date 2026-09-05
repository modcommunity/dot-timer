@tool
extends EditorPlugin

## Editor entry point for dot-timer. Registers inspector types only.
##
## No autoloads, for the family reason and for one of this addon's own: a dedicated
## server runs a timer per player, a replay viewer runs another over the same map, and
## a test harness runs thirty in one process. A singleton timer makes all three
## impossible.

const _ICON := "res://addons/dot_timer/icon_placeholder.svg"

const _TYPES := [
	[
		"DotTimerManager",
		"Node",
		"res://addons/dot_timer/runtime/dot_timer_manager.gd",
	],
	[
		"DotTimerZoneVolume3D",
		"Node3D",
		"res://addons/dot_timer/zones/dot_timer_zone_volume_3d.gd",
	],
	[
		"DotTimerZoneVolume2D",
		"Node2D",
		"res://addons/dot_timer/zones/dot_timer_zone_volume_2d.gd",
	],
	[
		"DotTimerHud",
		"Control",
		"res://addons/dot_timer/ui/dot_timer_hud.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
