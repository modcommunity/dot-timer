class_name DotTimerZonePainter
extends RefCounted

## Draws zones from inside the game, with two points and a console command.
##
## [b]This is how these maps have actually been made for twenty years.[/b] A surf or
## bhop map ships as geometry from somebody who is not the server operator, and the
## zones are added afterwards by an admin standing in the map: walk to one corner,
## type the command, walk to the other, type it again. The community timers'
## [code]sm_zones[/code] is exactly this, and a timer without it can only be used on
## maps whose author happened to be using the same engine.
##
## [codeblock]
## painter.begin(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
## painter.mark(player_position)     # first corner
## painter.mark(player_position)     # second corner — and the zone is added
## [/codeblock]
##
## [b]Everything it does is on the server's copy of the set.[/b] Zone editing is an
## administrative action and the client's copy is a display; a painter that wrote to a
## client's zones would let a player move their own finish line.

const CHANNEL := "timer.painter"

## Vertical padding added above the marked points, in metres.
##
## [b]Because an admin marks corners by standing on them.[/b] Both points are taken at
## the player's feet, so without this every zone is a flat sheet with no height and
## nothing ever enters it. This is the single most common mistake when drawing zones
## by hand, and making the tool add the height removes it.
const DEFAULT_HEIGHT := 3.0

## Horizontal padding, in metres, so a corner marked slightly inside still encloses it.
const DEFAULT_PADDING := 0.5

var zones: DotTimerZoneSet = null

## What is being drawn, once [method begin] has been called.
var kind: DotTimerZone.Kind = DotTimerZone.Kind.START
var track: int = DotTimerTrack.MAIN
var number: float = 0.0

## Height added above the marked corners. See [constant DEFAULT_HEIGHT].
var height: float = DEFAULT_HEIGHT

var padding: float = DEFAULT_PADDING

## The first corner, once marked.
var _first: Vector3 = Vector3.ZERO
var _have_first: bool = false


static func on(set: DotTimerZoneSet) -> DotTimerZonePainter:
	var painter := DotTimerZonePainter.new()
	painter.zones = set
	return painter


## Starts drawing a zone. Discards a half-drawn one.
func begin(
	p_kind: DotTimerZone.Kind,
	p_track: int = DotTimerTrack.MAIN,
	p_number: float = 0.0
) -> DotResult:
	if zones == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The painter has no zone set to draw into."
		)

	if not DotTimerTrack.is_valid(p_track):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That is not a track.",
			"%d, expected 0..%d" % [p_track, DotTimerTrack.BONUS_LAST]
		)

	kind = p_kind
	track = p_track
	number = p_number
	_have_first = false

	return DotResult.success(null)


func is_drawing() -> bool:
	return _have_first


## Marks a corner. The second mark completes the zone and returns it.
##
## Returns a success carrying null for the first corner, and the finished
## [DotTimerZone] for the second — so a console command can say "corner one, now walk
## to the other" or "done" from one return value.
func mark(at: Vector3) -> DotResult:
	if zones == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The painter has no zone set to draw into."
		)

	if not _have_first:
		_first = at
		_have_first = true
		return DotResult.success(null)

	_have_first = false

	var low := Vector3(
		minf(_first.x, at.x) - padding,
		minf(_first.y, at.y),
		minf(_first.z, at.z) - padding
	)
	var high := Vector3(
		maxf(_first.x, at.x) + padding,
		maxf(_first.y, at.y) + height,
		maxf(_first.z, at.z) + padding
	)

	var zone := DotTimerZone.make(kind, track)
	zone.set_box(low, high)
	zone.number = number

	var valid := zone.validate()

	if not valid.ok:
		return valid.wrap("That is not a usable zone.")

	zones.add(zone)

	DotLog.info(CHANNEL, "zone drawn", zone.describe())

	return DotResult.success(zone)


## Adds a point-kind zone — a track's spawn — at one position.
func mark_point(
	at: Vector3, yaw: float = 0.0, p_kind: DotTimerZone.Kind = DotTimerZone.Kind.SPAWN
) -> DotResult:
	if zones == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The painter has no zone set to draw into."
		)

	# Replaced rather than added: a track has one spawn, and an admin re-marking it
	# means "here instead", not "here as well". Two spawns for one track is a state
	# nothing downstream knows how to resolve.
	for existing in zones.of_kind(p_kind, track):
		zones.remove_id(existing.id)

	var zone := DotTimerZone.make(p_kind, track)
	zone.destination = at
	zone.destination_yaw = yaw

	zones.add(zone)

	return DotResult.success(zone)


## Abandons a half-drawn zone.
func cancel() -> void:
	_have_first = false


## Removes the most recently added zone. The undo an admin reaches for.
func undo() -> DotResult:
	if zones == null or zones.zones.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "There is nothing to undo.")

	var last := zones.zones[zones.zones.size() - 1]
	zones.remove_id(last.id)

	return DotResult.success(last)


## The zones on a track, for a "list what I have drawn" command.
func summary() -> PackedStringArray:
	var out := PackedStringArray()

	if zones == null:
		return out

	for zone in zones.zones:
		out.append("#%d %-14s %-7s %s" % [
			zone.id,
			DotTimerZone.kind_name(zone.kind),
			DotTimerTrack.short_name_of(zone.track),
			"(%.1f, %.1f, %.1f) %.1f x %.1f x %.1f" % [
				zone.centre().x, zone.centre().y, zone.centre().z,
				zone.size().x, zone.size().y, zone.size().z
			],
		])

	for problem in zones.problems():
		out.append("PROBLEM %s" % problem)

	return out


func describe() -> Dictionary:
	return {
		"drawing": _have_first,
		"kind": DotTimerZone.kind_name(kind),
		"track": DotTimerTrack.short_name_of(track),
		"height": height,
		"zones": zones.zones.size() if zones != null else 0,
	}
