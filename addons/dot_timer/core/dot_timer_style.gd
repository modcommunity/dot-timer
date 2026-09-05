@tool
class_name DotTimerStyle
extends Resource

## The records half of a style: is it ranked, what are its points worth, what is the
## shortest run that counts.
##
## [b]The other half is [code]DotFpsStyle[/code] in dot-fps-controller[/b], and the
## split is deliberate. Movement belongs where the motor is; records belong where the
## records are. A game that only wants a timer over its own movement does not have to
## install a first-person controller to get one, and a 2D game — which cannot use
## [code]DotFpsStyle[/code] at all — still gets styles.
##
## The two are paired by [member id]. Nothing enforces the pairing, because enforcing
## it would mean this file mentioning a class that may not exist, which in GDScript
## takes the whole addon down with it.

@export var id: StringName = &"normal"

@export var display_name: String = "Normal"

@export var short_name: String = "N"

## A hex colour, e.g. [code]#7fc8ff[/code]. Strings, so it survives JSON.
@export var html_colour: String = "#ffffff"

@export_multiline var description: String = ""

## Where this style sits in a list. Lower is earlier.
@export var ordering: int = 0

@export_group("Ranking")

## Whether runs on this style are recorded at all.
##
## Off for a joke style, a testing style, or one whose movement makes the map
## trivial. An unranked style still times, splits and shows a HUD — it simply does
## not file anything, and telling the player that up front is much better than
## silently discarding their record.
@export var ranked: bool = true

## Multiplier on the points a completion is worth.
##
## Harder styles are worth more. Set to 0 for a style that ranks but earns nothing.
@export_range(0.0, 10.0, 0.01) var points_multiplier: float = 1.0

## The shortest run that may be recorded on a main track, in seconds.
##
## [b]An anti-cheat measure, not a nicety.[/b] The classic exploit is to place the
## start and finish zones close enough to touch — or find a spot where a teleport
## crosses both — and file a 0.02 second world record that nothing can beat. A floor
## makes that record impossible rather than merely suspicious.
@export_range(0.0, 600.0, 0.01) var minimum_time: float = 3.5

## The same for a bonus track, which is legitimately much shorter.
@export_range(0.0, 600.0, 0.01) var minimum_bonus_time: float = 0.5

## Whether a replay may be recorded on this style.
@export var replays: bool = true

@export_group("Rules")

## Whether a run that used a practice checkpoint may still be ranked.
##
## [b]This is about the RECORD, not about the feature.[/b] Practice mode is always
## available — that is the point of it, and a timer that took it away on a ranked
## style would be a timer nobody could learn a map on. What this decides is what
## happens to the run: off, restoring a checkpoint abandons it, because continuing
## to time a run that can never be filed wastes the player's next four minutes; on,
## the run keeps going and is filed with [member DotTimerRun.used_checkpoints] set.
##
## Off for every normal style: saving and restoring a position is the whole of the
## difficulty on some maps. A "segmented" style turns it on and ranks separately.
##
## Whether practice mode exists at all is the server's,
## [member DotTimerManager.allow_checkpoints].
@export var allow_checkpoints: bool = false

## Whether the timer may run while the player is not touching the ground at the start.
##
## The familiar [code]startinair[/code]. Off means leaving the start zone airborne does
## not begin the run, which stops a player building speed outside it and diving
## through.
@export var allow_air_start: bool = false

## Seconds a run may be paused for before it is abandoned. 0 = no limit.
@export_range(0.0, 3600.0, 1.0) var maximum_pause: float = 0.0


## The points a completion is worth, before the multiplier.
##
## [b]The shape of this formula is the whole of a ranking system's politics.[/b] Ranks
## by raw time reward whoever plays the easiest map; ranks by placement reward whoever
## plays the emptiest one. This is the compromise the genre settled on: points are the
## map's own tier weight scaled by how close the run is to the record on it, so
## finishing a hard map slowly is worth more than finishing an easy map perfectly, and
## improving a run always pays something.
##
## [param tier] is the map's difficulty, 1..10. [param record_time] is the best time
## on the same map, track and style, or 0 if this run IS the record.
func points_for(
	time_seconds: float,
	tier: int,
	record_time: float = 0.0
) -> float:
	if not ranked or time_seconds <= 0.0:
		return 0.0

	# A tier's base worth. Quadratic rather than linear because tier 10 maps are not
	# ten times harder than tier 1 maps, they are very much more than that, and a
	# linear scale makes grinding easy maps the optimal strategy.
	var base := 25.0 * float(clampi(tier, 1, 10)) * float(clampi(tier, 1, 10)) / 10.0

	# How close to the record, as a fraction. The record itself scores 1.
	var closeness := 1.0

	if record_time > 0.0 and time_seconds > 0.0:
		closeness = clampf(record_time / time_seconds, 0.0, 1.0)

	# Never less than a fifth of the base for a completion: a first clear of a hard
	# map is worth something even when it is four times the record, and a scale that
	# tends to zero makes the hardest maps the least rewarding to attempt.
	var scale := 0.2 + 0.8 * closeness

	return base * scale * points_multiplier


## The floor a run on [param track] has to clear to be recorded, in seconds.
func minimum_time_for(track: int) -> float:
	return minimum_bonus_time if DotTimerTrack.is_bonus(track) else minimum_time


func to_dictionary() -> Dictionary:
	return {
		"id": String(id),
		"display_name": display_name,
		"short_name": short_name,
		"html_colour": html_colour,
		"description": description,
		"ordering": ordering,
		"ranked": ranked,
		"points_multiplier": points_multiplier,
		"minimum_time": minimum_time,
		"minimum_bonus_time": minimum_bonus_time,
		"replays": replays,
		"allow_checkpoints": allow_checkpoints,
		"allow_air_start": allow_air_start,
		"maximum_pause": maximum_pause,
	}


static func from_dictionary(data: Dictionary) -> DotTimerStyle:
	var style := DotTimerStyle.new()

	style.id = StringName(str(data.get("id", "normal")))
	style.display_name = str(data.get("display_name", String(style.id)))
	style.short_name = str(data.get("short_name", style.display_name.substr(0, 2)))
	style.html_colour = str(data.get("html_colour", "#ffffff"))
	style.description = str(data.get("description", ""))
	style.ordering = int(data.get("ordering", 0))
	style.ranked = bool(data.get("ranked", true))
	style.points_multiplier = float(data.get("points_multiplier", 1.0))
	style.minimum_time = float(data.get("minimum_time", 3.5))
	style.minimum_bonus_time = float(data.get("minimum_bonus_time", 0.5))
	style.replays = bool(data.get("replays", true))
	style.allow_checkpoints = bool(data.get("allow_checkpoints", false))
	style.allow_air_start = bool(data.get("allow_air_start", false))
	style.maximum_pause = float(data.get("maximum_pause", 0.0))

	return style


## The ranking half of the styles [code]DotFpsStyle.defaults()[/code] ships, paired
## by id.
##
## The multipliers are the genre's conventional weights: sideways and backwards are
## much harder than normal and are worth roughly double, half-sideways sits between,
## and low gravity is easier and is worth less.
static func defaults() -> Array[DotTimerStyle]:
	var table := [
		[&"normal", "Normal", "N", "#ffffff", 1.0, 0],
		[&"sideways", "Sideways", "SW", "#ffb347", 2.0, 1],
		[&"half_sideways", "Half-Sideways", "HSW", "#ff7f7f", 1.6, 2],
		[&"backwards", "Backwards", "BW", "#b39ddb", 2.2, 3],
		[&"low_gravity", "Low Gravity", "LG", "#7fe0c0", 0.6, 4],
		[&"prebhop", "Prebhop", "PB", "#ff5f5f", 1.8, 5],
	]

	var out: Array[DotTimerStyle] = []

	for row in table:
		var style := DotTimerStyle.new()
		style.id = row[0]
		style.display_name = row[1]
		style.short_name = row[2]
		style.html_colour = row[3]
		style.points_multiplier = row[4]
		style.ordering = row[5]
		out.append(style)

	return out


func describe() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"ranked": ranked,
		"points": "x%.2f" % points_multiplier,
		"minimum": "%.2f s (%.2f bonus)" % [minimum_time, minimum_bonus_time],
	}


func _to_string() -> String:
	return "DotTimerStyle(%s)" % display_name
