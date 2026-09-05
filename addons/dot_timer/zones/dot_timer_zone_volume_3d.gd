@tool
class_name DotTimerZoneVolume3D
extends Node3D

## A zone drawn in the 3D editor instead of in a JSON file.
##
## [b]Both ways of authoring a zone are needed, and they are not alternatives.[/b] A
## mapper building a level in Godot wants to place a start line the way they place
## everything else: a node, in the scene, moved with the gizmo. A server operator
## adding a bonus to somebody else's map has no scene to open and needs
## [DotTimerZonePainter] and a console. So this node exists to be [i]exported[/i] into
## the same [DotTimerZoneSet] the painter writes — one format, two ways in.
##
## [codeblock]
## # in the map's own script
## var set := DotTimerZoneVolume3D.collect(self, &"surf_beginner")
## timer_manager.set_zones(set)
## [/codeblock]
##
## Draws itself in the editor and does nothing at runtime.

## What the zone is. See [enum DotTimerZone.Kind].
@export var kind: DotTimerZone.Kind = DotTimerZone.Kind.START:
	set(value):
		kind = value
		update_gizmos()
		notify_property_list_changed()

@export_range(0, 8, 1) var track: int = DotTimerTrack.MAIN

## Size of the box, in metres, centred on this node.
##
## [b]A size rather than two corners[/b] so the node can be moved and rotated in the
## editor like anything else. The exported zone is axis-aligned — see
## [method to_zone] — because zone tests happen a hundred thousand times a second and
## an oriented box costs a matrix multiply each time.
@export var size: Vector3 = Vector3(4.0, 4.0, 4.0):
	set(value):
		size = value.abs().maxf(0.01)
		update_gizmos()

## The kind's number: a stage index, a speed cap, a gravity multiplier.
@export var number: float = 0.0

## Where [constant DotTimerZone.Kind.TELEPORT] and [constant DotTimerZone.Kind.SPAWN]
## send the player. A node so it can be dragged; resolved to a point on export.
@export var destination: Node3D = null

@export var direction: Vector3 = Vector3.ZERO

@export var payload: Dictionary = {}

@export_multiline var comment: String = ""


## The zone this node describes, in world space.
##
## [b]Axis-aligned, from the node's world-space bounds.[/b] A rotated node produces
## the box that contains it, which is larger than what was drawn — so a rotated start
## line begins the run slightly early. That is a deliberate trade against making every
## zone test an oriented-box test: the alternative is a per-tick matrix multiply per
## player per zone, and every timer in this genre has used axis-aligned boxes for
## twenty years. Rotate the geometry, not the zone.
func to_zone() -> DotTimerZone:
	var zone := DotTimerZone.make(kind, track)

	var half := size * 0.5
	var centre := global_position

	if global_basis.is_equal_approx(Basis.IDENTITY):
		zone.set_box(centre - half, centre + half)
	else:
		# The world-space extent of a rotated box: the rotated half-extents summed
		# per axis, which is the standard AABB-of-an-OBB.
		var b := global_basis
		var extent := Vector3(
			absf(b.x.x) * half.x + absf(b.y.x) * half.y + absf(b.z.x) * half.z,
			absf(b.x.y) * half.x + absf(b.y.y) * half.y + absf(b.z.y) * half.z,
			absf(b.x.z) * half.x + absf(b.y.z) * half.y + absf(b.z.z) * half.z
		)
		zone.set_box(centre - extent, centre + extent)

	zone.number = number
	zone.direction = direction
	zone.payload = payload.duplicate()
	zone.comment = comment

	if destination != null:
		zone.destination = destination.global_position
		zone.destination_yaw = rad_to_deg(destination.global_rotation.y)

	return zone


## Builds a zone set from every [DotTimerZoneVolume3D] under [param root].
##
## Order is the tree's, so the ids a set is built with are stable as long as the scene
## is — which matters because a replay's crossing marks name zones by id.
static func collect(root: Node, map_id: StringName) -> DotTimerZoneSet:
	var set := DotTimerZoneSet.new()
	set.map_id = map_id

	_collect_into(root, set)

	return set


static func _collect_into(node: Node, set: DotTimerZoneSet) -> void:
	if node is DotTimerZoneVolume3D:
		set.add((node as DotTimerZoneVolume3D).to_zone())

	for child in node.get_children():
		_collect_into(child, set)


# --- Editor drawing --------------------------------------------------------

## A colour per kind, so a map full of zones is readable at a glance.
##
## Green starts, red finishes, yellow stages: the convention every timer's zone editor
## has used, and worth matching rather than inventing — a mapper who has drawn zones
## before already knows it.
static func colour_for(k: DotTimerZone.Kind) -> Color:
	match k:
		DotTimerZone.Kind.START:
			return Color(0.2, 0.9, 0.3, 0.35)
		DotTimerZone.Kind.END:
			return Color(0.95, 0.25, 0.25, 0.35)
		DotTimerZone.Kind.STAGE:
			return Color(0.95, 0.85, 0.2, 0.35)
		DotTimerZone.Kind.CHECKPOINT:
			return Color(0.3, 0.6, 1.0, 0.35)
		DotTimerZone.Kind.TELEPORT, DotTimerZone.Kind.RESPAWN:
			return Color(0.7, 0.4, 1.0, 0.35)
		DotTimerZone.Kind.SLAY, DotTimerZone.Kind.STOP:
			return Color(0.9, 0.4, 0.1, 0.35)
		_:
			return Color(0.6, 0.6, 0.6, 0.25)


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()

	if kind == DotTimerZone.Kind.STAGE and int(number) < 1:
		out.append("A stage zone's `number` is the stage, counted from 1.")

	if (
		kind in [DotTimerZone.Kind.TELEPORT, DotTimerZone.Kind.SPAWN]
		and destination == null
	):
		out.append("This kind needs a `destination` node to send the player to.")

	# The thin-zone warning, here as well as in the set, because this is where it can
	# actually be fixed. At 128 Hz a player at 30 m/s crosses 23 cm in one tick.
	if size.x < 0.25 or size.y < 0.25 or size.z < 0.25:
		out.append(
			"Thinner than a fast player moves in one tick — they will pass through "
			+ "it without ever being sampled inside."
		)

	return out
