@tool
class_name DotTimerZoneVolume2D
extends Node2D

## The 2D counterpart of [DotTimerZoneVolume3D].
##
## [b]The timer itself is dimension-agnostic[/b] — it works on [Vector3] positions and
## does not care what they mean — so a 2D game gets timers, tracks, stages, styles,
## records, replays and leaderboards from the same addon a surf server uses. This node
## is the whole of the 2D-specific part: it maps a rectangle in the XY plane onto a
## box that is unbounded on Z, so a sample of [code]Vector3(x, y, 0)[/code] falls
## inside it.
##
## Getting that third axis wrong is the single most likely way to draw a 2D zone that
## never fires, which is why it is done here once rather than at every call site. See
## [method DotTimerZone.flatten_for_2d].

@export var kind: DotTimerZone.Kind = DotTimerZone.Kind.START:
	set(value):
		kind = value
		queue_redraw()

@export_range(0, 8, 1) var track: int = DotTimerTrack.MAIN

## Size of the rectangle, in the host's own 2D units, centred on this node.
@export var size: Vector2 = Vector2(128.0, 128.0):
	set(value):
		size = value.abs().maxf(1.0)
		queue_redraw()

@export var number: float = 0.0

@export var destination: Node2D = null

@export var payload: Dictionary = {}

@export_multiline var comment: String = ""


## The zone this node describes, unbounded on Z.
func to_zone() -> DotTimerZone:
	var zone := DotTimerZone.make(kind, track)

	var centre := global_position
	var half := size * 0.5

	zone.set_box(
		Vector3(centre.x - half.x, centre.y - half.y, 0.0),
		Vector3(centre.x + half.x, centre.y + half.y, 0.0)
	)
	zone.flatten_for_2d()

	zone.number = number
	zone.payload = payload.duplicate()
	zone.comment = comment

	if destination != null:
		zone.destination = Vector3(
			destination.global_position.x, destination.global_position.y, 0.0
		)

	return zone


static func collect(root: Node, map_id: StringName) -> DotTimerZoneSet:
	var set := DotTimerZoneSet.new()
	set.map_id = map_id

	_collect_into(root, set)

	return set


static func _collect_into(node: Node, set: DotTimerZoneSet) -> void:
	if node is DotTimerZoneVolume2D:
		set.add((node as DotTimerZoneVolume2D).to_zone())

	for child in node.get_children():
		_collect_into(child, set)


func _draw() -> void:
	# Editor only. A zone is a rule, not scenery, and a game that wants to show one to
	# a player draws its own — this is deliberately not a renderer.
	if not Engine.is_editor_hint():
		return

	var rectangle := Rect2(-size * 0.5, size)
	var colour := DotTimerZoneVolume3D.colour_for(kind)

	draw_rect(rectangle, colour)
	draw_rect(rectangle, Color(colour, 1.0), false, 2.0)
