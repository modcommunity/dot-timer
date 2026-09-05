@tool
class_name DotTimerZone
extends Resource

## One volume in a map that the timer reacts to: a start line, a finish, a stage
## split, a teleport, a speed limit.
##
## [b]A zone is data, not a node.[/b] Everything here survives JSON, is comparable
## between a client and a server, and can be authored by somebody standing in the map
## with a console open — which is how these maps have been made for twenty years and
## is the workflow [DotTimerZonePainter] reproduces. A zone that were a scene node
## could not be created by a player at runtime, could not be sent to a client that
## does not have the map's source, and could not be diffed against the copy a records
## database was built against.
##
## [b]It is also dimension-agnostic, and that is not incidental.[/b] The volume is an
## AABB (or a sphere) in [Vector3]; a 2D game hands the timer [code]Vector3(x, y, 0)[/code]
## and leaves the third axis unbounded. So the same timer, the same records and the
## same leaderboards serve a 3D surf map and a 2D racing course, and the only thing
## either has to supply is a position.
##
## [codeblock]
## var start := DotTimerZone.make(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
## start.set_box(Vector3(-2, 0, -2), Vector3(2, 3, 2))
## [/codeblock]

## What the timer does about a zone.
##
## Deliberately a superset of what the timer itself handles: the volume kinds the
## timer cannot act on ([constant Kind.GRAVITY], [constant Kind.PUSH], and the rest)
## are reported to the host game as events rather than dropped. The alternative — a
## separate "trigger volume" system beside this one — means a mapper drawing two kinds
## of box, saving them in two files, and getting the coordinates of one of them wrong.
##
## The numbering follows the community timers' where the kinds correspond, because
## these maps and
## their zone files are traded between communities and a re-numbering is a silent
## corruption of every one of them.
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
}

## How the volume is described.
enum Shape {
	## An axis-aligned box between [member from] and [member to].
	BOX,
	## A sphere centred on [member from] with radius [member number].
	##
	## Worth having for exactly one reason: a start point on a 2D map or a round
	## finish pad is a circle, and approximating one with a box means a player who
	## clips its corner starts their run half a metre before the person beside them.
	SPHERE,
}

## Kinds that do not describe a volume at all.
##
## [constant Kind.SPAWN] is a point, and asking whether a player is "inside" it is
## meaningless — but it is authored with the same tool, saved in the same file and
## edited in the same list, so it is a kind rather than a second concept.
const POINT_KINDS: Array[Kind] = [Kind.SPAWN]

@export var kind: Kind = Kind.START

## Which track this zone belongs to. See [DotTimerTrack].
@export_range(0, 8, 1) var track: int = DotTimerTrack.MAIN

@export var shape: Shape = Shape.BOX

## One corner of the box, or the centre of the sphere.
@export var from: Vector3 = Vector3.ZERO

## The opposite corner. Unused for a sphere.
@export var to: Vector3 = Vector3.ZERO

## The kind's number: a stage index, a speed cap, a gravity multiplier, a radius.
##
## One field rather than one per kind because a zone is a row in a file and a row in a
## database, and eighteen mostly-null columns is how a schema becomes unreadable. What
## it means is documented on each [enum Kind] member.
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

## Stable id within a [DotTimerZoneSet]. Assigned by the set, not by hand.
##
## Records refer to stages by number and not by this, so renumbering zones does not
## orphan anything — but a replay's zone-crossing marks and an editor's "delete that
## one" both need to name a zone that has not moved.
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
##
## A 2D game's positions are [code](x, y, 0)[/code], so a box authored in the editor
## with a zero-thickness third axis contains nothing at all — the single most likely
## way to draw a zone in 2D that never fires. This says it once.
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


## Whether [param point] is inside the volume.
##
## Half-open on the upper bound, so two zones sharing a face do not both contain the
## plane between them. Two stage zones drawn back to back is normal in these maps and
## a player standing exactly on the seam would otherwise trigger both, which reads as
## a stage being skipped.
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
##
## [b]The sub-tick crossing time is computed from this[/b], which is what makes a run
## on a 64 Hz server comparable with one on a 128 Hz server. See
## [method DotTimer._crossing_fraction].
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


## Whether the volume is big enough to be crossed rather than tunnelled through.
##
## [b]A thin zone is the classic way to lose a run.[/b] A player crossing a finish
## line at 30 m/s covers 23 cm in one tick at 128 Hz and 47 cm at 64 Hz; a finish
## volume thinner than that is simply not sampled on the tick the player is inside it,
## and the run never ends. The check is advisory — a mapper may know their zone is
## only entered slowly — but it is the first thing to look at when a zone "does not
## work".
func min_thickness() -> float:
	if shape == Shape.SPHERE:
		return number * 2.0

	var s := size()
	return minf(s.x, minf(s.y, s.z))


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


# --- Serialisation ---------------------------------------------------------

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
		# Duplicated, not handed out. A Dictionary is a reference in GDScript, so
		# returning this one makes `duplicate_zone()` — which round-trips through
		# here — produce a "copy" that shares its payload with the original, and an
		# edit to one silently edits the other. dot-leaderboard's self-test caught
		# exactly this shape in its own scope dictionary.
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
##
## A match rather than a cast for the reason [code]DotFpsStyle[/code] uses one: an
## out-of-range int cast to an enum is caught nowhere, and produces a zone whose kind
## falls through every branch in the timer — a volume that is drawn, saved, listed and
## does nothing, with no error anywhere to explain it.
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
