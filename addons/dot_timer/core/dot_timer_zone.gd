@tool
class_name DotTimerZone
extends Resource

## One volume in a map that the timer reacts to: a start line, a finish, a stage split, a teleport, a speed limit.
## Data, not a node, and dimension-agnostic: an AABB or sphere in [Vector3]; a 2D game uses [code]Vector3(x, y, 0)[/code].

## What the timer does about a zone. A superset of what the timer handles itself: other kinds are reported to the host, not dropped.
## Numbering follows the community timers' where kinds correspond; renumbering silently corrupts traded zone files.
enum Kind {
	## Starts the run. Timing begins as the player LEAVES it — see [DotTimer].
	START,
	## Ends the run.
	END,
	## Teleports the player back to the track's spawn.
	RESPAWN,
	## Stops the run without finishing it.
	STOP,
	## Kills the player.
	SLAY,
	## Style key restrictions do not apply inside. A "freestyle" zone.
	FREESTYLE,
	## Caps horizontal speed inside. [member number] is the cap, in m/s.
	SPEED_LIMIT,
	## Teleports to [member destination].
	TELEPORT,
	## Not a volume: where a track's players spawn. [member destination] is the point.
	SPAWN,
	## Forces easy bunny-hopping inside, whatever the style says.
	EASY_BHOP,
	## Lets the player slide instead of sticking, for map sections that need it.
	SLIDE,
	## Overrides air acceleration inside. [member number] is the value.
	AIR_ACCELERATE,
	## Splits the run. [member number] is the stage, counted from 1.
	STAGE,
	## Overrides gravity inside. [member number] is a multiplier.
	GRAVITY,
	## Pushes the player. [member direction] is the acceleration, in m/s².
	PUSH,
	## Blocks jumping inside.
	NO_JUMP,
	## Forces auto-hop inside, whatever the style says.
	AUTO_HOP,
	## A checkpoint for practice mode. Not part of a timed run.
	CHECKPOINT,
	## Anything the game invented. [member payload] carries it.
	CUSTOM,
	## Marks the player as having passed a point on the route. [member number] pairs it with the [constant CHECKER]s it satisfies.
	## Appended, never inserted: a re-numbering silently corrupts files that kept the integer.
	VALIDATOR,
	## A point a skip would reach: entering it without having passed its [constant VALIDATOR] (same [member number]) disqualifies the run
	## and asks the host to send the player to the track's spawn ([signal DotTimer.effect_requested]).
	CHECKER,
}

## How the volume is described.
enum Shape {
	## An axis-aligned box between [member from] and [member to].
	BOX,
	## A sphere centred on [member from] with radius [member number].
	## For a round finish pad or a 2D start point, where a box would start runs early at its corners.
	SPHERE,
}

## Kinds that do not describe a volume at all.
## [constant Kind.SPAWN] is a point, but is authored, saved and listed with the same tool, so it is a kind rather than a second concept.
const POINT_KINDS: Array[Kind] = [Kind.SPAWN]

@export var kind: Kind = Kind.START

## Which track this zone belongs to. See [DotTimerTrack].
@export_range(0, 8, 1) var track: int = DotTimerTrack.MAIN

@export var shape: Shape = Shape.BOX

## One corner of the box, or the centre of the sphere.
@export var from: Vector3 = Vector3.ZERO

## The opposite corner. Unused for a sphere.
@export var to: Vector3 = Vector3.ZERO

## The kind's number: a stage index, a speed cap, a gravity multiplier, a radius; see each [enum Kind] member.
## One field, not one per kind: a zone is a database row and eighteen mostly-null columns is an unreadable schema.
@export var number: float = 0.0

## Where [constant Kind.TELEPORT] and [constant Kind.SPAWN] send the player.
@export var destination: Vector3 = Vector3.ZERO

## The yaw the player faces after being sent to [member destination], in degrees.
@export var destination_yaw: float = 0.0

## A direction for the kinds that need one — [constant Kind.PUSH], above all.
@export var direction: Vector3 = Vector3.ZERO

## Anything a game's own [constant Kind.CUSTOM] zone needs.
##
## Plain types only: this is serialised to JSON and may cross a network.
@export var payload: Dictionary = {}

## A mapper's note. Never read by anything.
@export var comment: String = ""

## Stable id within a [DotTimerZoneSet], assigned by the set.
## Records name stages by number, not this; a replay's crossing marks and an editor's "delete that one" need a zone that has not moved.
@export var id: int = 0


static func make(p_kind: Kind, p_track: int = DotTimerTrack.MAIN) -> DotTimerZone:
	var zone := DotTimerZone.new()
	zone.kind = p_kind
	zone.track = p_track
	return zone


## Sets a box from any two opposite corners, in either order.
func set_box(a: Vector3, b: Vector3) -> DotTimerZone:
	shape = Shape.BOX
	from = Vector3(minf(a.x, b.x), minf(a.y, b.y), minf(a.z, b.z))
	to = Vector3(maxf(a.x, b.x), maxf(a.y, b.y), maxf(a.z, b.z))
	return self


func set_sphere(centre: Vector3, radius: float) -> DotTimerZone:
	shape = Shape.SPHERE
	from = centre
	number = absf(radius)
	return self


## Makes the box unbounded on the Z axis, for a 2D game.
## A zero-thickness third axis contains nothing, the most likely way to draw a 2D zone that never fires.
func flatten_for_2d() -> DotTimerZone:
	from.z = -1e9
	to.z = 1e9
	return self


func is_point_kind() -> bool:
	return kind in POINT_KINDS


func centre() -> Vector3:
	return from if shape == Shape.SPHERE else (from + to) * 0.5


func size() -> Vector3:
	if shape == Shape.SPHERE:
		return Vector3.ONE * number * 2.0
	return to - from


## Whether [param point] is inside the volume. Half-open on the upper bound.
## Two back-to-back stage zones must not both contain the seam between them, or a stage looks skipped.
func contains(point: Vector3) -> bool:
	if is_point_kind():
		return false

	if shape == Shape.SPHERE:
		return point.distance_squared_to(from) <= number * number

	return (
		point.x >= from.x and point.x < to.x
		and point.y >= from.y and point.y < to.y
		and point.z >= from.z and point.z < to.z
	)


## Distance from [param point] to the surface. Negative inside.
## The sub-tick crossing time is computed from this; see [method DotTimer._crossing_fraction].
func signed_distance(point: Vector3) -> float:
	if shape == Shape.SPHERE:
		return point.distance_to(from) - number

	var half := (to - from) * 0.5
	var offset := (point - centre()).abs() - half

	var outside := Vector3(
		maxf(offset.x, 0.0), maxf(offset.y, 0.0), maxf(offset.z, 0.0)
	)

	# The exact signed distance for a box: the length of the outside part, plus the
	# largest negative component when every one of them is negative (fully inside).
	return outside.length() + minf(maxf(offset.x, maxf(offset.y, offset.z)), 0.0)


## Whether the volume is big enough to be crossed rather than tunnelled through. Advisory.
## A finish thinner than one tick of travel (23 cm at 30 m/s and 128 Hz) is never sampled and the run never ends.
func min_thickness() -> float:
	if shape == Shape.SPHERE:
		return number * 2.0

	var s := size()
	return minf(s.x, minf(s.y, s.z))


## Whether a player moving this fast steps clean over the zone between two ticks. Both arguments are metres per tick.
## Per axis: the Y extent is judged against the fall speed, a different number on a jumping course.
func is_thin_for(horizontal_per_tick: float, vertical_per_tick: float) -> bool:
	if shape == Shape.SPHERE:
		# Equally thin in every direction, so the fastest axis is the only one that
		# decides it.
		return number * 2.0 < maxf(horizontal_per_tick, vertical_per_tick)

	var s := size()
	return minf(s.x, s.z) < horizontal_per_tick or s.y < vertical_per_tick


func validate() -> DotResult:
	if not DotTimerTrack.is_valid(track):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A zone's track must be 0..%d." % DotTimerTrack.BONUS_LAST,
			"track %d" % track
		)

	if is_point_kind():
		return DotResult.success(null)

	if shape == Shape.SPHERE:
		if number <= 0.0:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A spherical zone needs a positive radius.",
				"radius %.3f" % number
			)
		return DotResult.success(null)

	if to.x <= from.x or to.y <= from.y or to.z <= from.z:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A box zone needs a positive size on every axis.",
			"%s .. %s" % [str(from), str(to)]
		)

	if kind == Kind.STAGE and int(number) < 1:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A stage zone's number is the stage, counted from 1.",
			"number %.1f" % number
		)

	return DotResult.success(null)



func to_dictionary() -> Dictionary:
	var out := {
		"id": id,
		"kind": kind,
		"track": track,
		"shape": shape,
		"from": [from.x, from.y, from.z],
		"to": [to.x, to.y, to.z],
	}

	# Sparse on purpose. A zone file is read and hand-edited by mappers, and eighteen
	# zero-valued keys per zone is how a hundred-zone map becomes unreadable.
	if number != 0.0:
		out["number"] = number
	if destination != Vector3.ZERO:
		out["destination"] = [destination.x, destination.y, destination.z]
	if destination_yaw != 0.0:
		out["destination_yaw"] = destination_yaw
	if direction != Vector3.ZERO:
		out["direction"] = [direction.x, direction.y, direction.z]
	if not payload.is_empty():
		# Duplicated, not handed out: a Dictionary is a reference, so a shared payload would make a duplicated zone edit the original.
		out["payload"] = payload.duplicate(true)
	if comment != "":
		out["comment"] = comment

	return out


static func _vector(value: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var a: Array = value
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback


static func from_dictionary(data: Dictionary) -> DotTimerZone:
	var zone := DotTimerZone.new()

	zone.id = int(data.get("id", 0))
	zone.kind = _to_kind(data.get("kind", Kind.START))
	zone.track = clampi(int(data.get("track", 0)), 0, DotTimerTrack.BONUS_LAST)
	zone.shape = _to_shape(data.get("shape", Shape.BOX))
	zone.from = _vector(data.get("from"))
	zone.to = _vector(data.get("to"))
	zone.number = float(data.get("number", 0.0))
	zone.destination = _vector(data.get("destination"))
	zone.destination_yaw = float(data.get("destination_yaw", 0.0))
	zone.direction = _vector(data.get("direction"))
	zone.comment = str(data.get("comment", ""))

	var payload_value: Variant = data.get("payload", {})
	zone.payload = (
		(payload_value as Dictionary).duplicate(true) if payload_value is Dictionary
		else {}
	)

	return zone


## Reads a [enum Kind] out of untrusted data.
## A match, not a cast: an out-of-range int cast to an enum falls through every branch, a zone that does nothing with no error.
static func _to_kind(value: Variant) -> Kind:
	var raw := int(value)

	if raw >= 0 and raw < Kind.size():
		return raw as Kind

	return Kind.CUSTOM


static func _to_shape(value: Variant) -> Shape:
	return Shape.SPHERE if int(value) == Shape.SPHERE else Shape.BOX


func duplicate_zone() -> DotTimerZone:
	return DotTimerZone.from_dictionary(to_dictionary())


static func kind_name(k: Kind) -> String:
	return Kind.keys()[k] if k >= 0 and k < Kind.size() else "CUSTOM"


func describe() -> Dictionary:
	return {
		"id": id,
		"kind": kind_name(kind),
		"track": DotTimerTrack.short_name_of(track),
		"shape": Shape.keys()[shape],
		"centre": "(%.1f, %.1f, %.1f)" % [centre().x, centre().y, centre().z],
		"size": "(%.1f, %.1f, %.1f)" % [size().x, size().y, size().z],
		"number": number,
	}


func _to_string() -> String:
	return "DotTimerZone(%s %s #%d)" % [
		kind_name(kind), DotTimerTrack.short_name_of(track), id
	]
