class_name DotTimerRecord
extends RefCounted

## A finished run, as it is stored, sorted, sent and compared.
##
## [b]The identity of a record is (map, track, style, player).[/b] Everything a
## leaderboard does — "the record for this map", "my best", "am I first" — is a query
## over those four, which is why they are separate fields rather than a composite key
## somebody has to parse. [method key] builds the composite when a store needs one.
##
## [b]Times are seconds, and the tickrate they were measured at is stored beside
## them.[/b] Not because anything divides by it, but because a record whose provenance
## cannot be established is a record nobody can defend when it is disputed — and in
## this genre records are disputed. The same reasoning puts the zone fingerprint here:
## if the finish line moves, every record set against the old one is on a different
## map, and only the fingerprint can say so afterwards.
##
## Plain types only. This goes into a JSON file, a database and an HTTP body.

## Format version, written into every serialised record.
const FORMAT_VERSION := 1

## Which map, by id rather than by path. See [DotTimerZoneSet.map_id].
var map_id: StringName = &""

var track: int = DotTimerTrack.MAIN

var style_id: StringName = &"normal"

## Who set it, in the host's own vocabulary.
##
## [b]Not a site user id, and deliberately not.[/b] The family's identity layer gives a
## server a per-scope pseudonymous id precisely so operators cannot correlate their
## players across servers, and a records table that stored a global id would undo
## that. What goes here is whatever the host uses to mean "this player on this
## server"; the backbone maps it to an account at the point of reporting, if the
## player has linked one.
var player_id: StringName = &""

## What to show. Denormalised on purpose: a leaderboard has to render without a
## lookup per row, and the name a record was set under is part of the record.
var player_name: String = ""

## The run's time, in seconds.
var time: float = 0.0

## Absolute stage times in seconds, by stage number, as strings->floats survive JSON.
var splits: Dictionary = {}

## Unix seconds. Presentation only; never used for ordering.
##
## Ordering by time and breaking ties by this would be wrong in the one case that
## matters: two identical times are a tie, and awarding the older one first is a rule
## nobody agreed to.
var set_at: int = 0

## Ticks per second the run was measured at.
var tick_rate: int = 128

## The zone set the run was measured against. See the class documentation.
var zone_fingerprint: String = ""

## Movement statistics: jumps, strafes, sync, speeds. Whatever the host measured.
var stats: Dictionary = {}

## Points this completion earned, as computed at the time it was filed.
##
## Stored rather than recomputed because the formula changes and a player's total
## should not silently move when it does. A re-rank recomputes them all deliberately.
var points: float = 0.0

## An opaque handle to the replay, or empty. Where it lives is the store's business.
var replay_id: String = ""

## Anything the game wants to keep with a record.
var extra: Dictionary = {}

## Which section of the track this is the time for. 0 is the whole run.
##
## A staged map is ranked twice: by the whole run, and section by section — the stage
## records players chase when the whole map is out of reach. Section [code]k[/code] is
## the stretch from stage line [code]k - 1[/code] (the start, for the first) to stage line
## [code]k[/code] (the finish, for the last); see [method DotTimerRun.section_time].
## Stored in the same table with its own board, because every query a board answers —
## the record, a player's best, a rank — is the same query for a section.
var stage: int = 0

## How many times the player has finished this board, slower runs included.
##
## [b]Kept by the store, not by the run.[/b] A run is one attempt; the count belongs to
## the row the store keeps, which is the only thing that sees every finish — including
## the slower ones it does not keep.
var completions: int = 1

## Horizontal speed leaving the start, m/s. What a prespeed rule is judged against,
## kept so a disputed record can be checked against the rule in force when it was set.
var start_speed: float = 0.0

## Vertical speed leaving the start, m/s.
var start_speed_z: float = 0.0

## The style's timescale when the run was set. 1 for every normal style; a slow-motion
## style's times are measured in its own slowed time and are only comparable with each
## other, which is why the style is part of the board.
var timescale: float = 1.0


static func from_run(
	run: DotTimerRun,
	p_map: StringName,
	p_player: StringName,
	p_name: String
) -> DotTimerRecord:
	var record := DotTimerRecord.new()

	record.map_id = p_map
	record.track = run.track
	record.style_id = run.style_id
	record.player_id = p_player
	record.player_name = p_name
	record.time = run.time()
	record.start_speed = run.start_speed
	record.start_speed_z = run.start_speed_z
	record.timescale = run.time_scale
	record.tick_rate = int(round(1.0 / maxf(run.tick_interval, 0.000001)))
	record.stats = run.stats.duplicate()
	record.set_at = int(Time.get_unix_time_from_system())

	for number in run.splits:
		record.splits[str(number)] = run.split_time(number)

	# Filed at all only on a style that allows it; flagged so a board can show it.
	if run.used_checkpoints:
		record.extra["segmented"] = true

	# The two statistics the timer measures itself, so a record has them whatever the
	# host folds in. A host's own figures (sync, strafes) arrive through note_stats and
	# are kept beside these; if it measured speed too, its numbers win.
	if not record.stats.has("max_speed"):
		record.stats["max_speed"] = snappedf(run.max_speed, 0.01)
	if not record.stats.has("avg_speed"):
		record.stats["avg_speed"] = snappedf(run.average_speed(), 0.01)

	return record


## A section of [param run] as its own record: the time between two stage lines.
## Null when the run has not crossed both ends of that section.
static func section_from_run(
	run: DotTimerRun,
	section: int,
	total_sections: int,
	p_map: StringName,
	p_player: StringName,
	p_name: String
) -> DotTimerRecord:
	var seconds := run.section_time(section, total_sections)
	if seconds < 0.0:
		return null

	var record := DotTimerRecord.new()
	record.map_id = p_map
	record.track = run.track
	record.style_id = run.style_id
	record.stage = section
	record.player_id = p_player
	record.player_name = p_name
	record.time = seconds
	record.timescale = run.time_scale
	record.tick_rate = int(round(1.0 / maxf(run.tick_interval, 0.000001)))
	record.set_at = int(Time.get_unix_time_from_system())
	return record


## The composite a store keys a leaderboard by.
##
## Player excluded: this names the BOARD, not the row. A store looking up "the record
## for this map, track and style" and a store looking up "this player's best" are the
## same query with a different filter, and conflating the two keys is how a player
## ends up holding the world record on a board they were never on.
func board_key() -> String:
	return board_key_of(map_id, track, style_id, stage)


## The board key for any board. Stage 0 keeps the original three-part form, so the
## key — and the records filename built from the same parts — of every board that
## existed before sections did is unchanged.
static func board_key_of(
	p_map: StringName, p_track: int, p_style: StringName, p_stage: int = 0
) -> String:
	if p_stage <= 0:
		return "%s/%d/%s" % [String(p_map), p_track, String(p_style)]
	return "%s/%d/%s/s%d" % [String(p_map), p_track, String(p_style), p_stage]


## The composite that identifies THIS row: the board plus the player.
func key() -> String:
	return "%s/%s" % [board_key(), String(player_id)]


## Whether this record beats [param other]. Strictly — an equal time does not.
##
## [b]Strict, and that is a rule rather than an oversight.[/b] A player who ties their
## own record has not improved it, and replacing the row would move the date, reset
## the replay and reorder a leaderboard for a run that was not better.
func beats(other: DotTimerRecord) -> bool:
	if other == null:
		return true
	return time < other.time


func formatted_time() -> String:
	return DotTimerRun.format_time(time)


## The gap to [param other], as [code]+1:23.456[/code] or [code]-0:00.123[/code].
func delta_to(other: DotTimerRecord) -> String:
	if other == null:
		return ""
	return DotTimerRun.format_time(time - other.time, true)


func to_dictionary() -> Dictionary:
	return {
		"format": FORMAT_VERSION,
		"map": String(map_id),
		"track": track,
		"style": String(style_id),
		"player": String(player_id),
		"name": player_name,
		"time": time,
		# Duplicated for the reason DotTimerZone's payload is: a Dictionary is a
		# reference, and `duplicate_record()` round-trips through here — so a
		# "copy" would share its splits with the record it was copied from.
		"splits": splits.duplicate(true),
		"set_at": set_at,
		"tick_rate": tick_rate,
		"zones": zone_fingerprint,
		"stats": stats.duplicate(true),
		"points": points,
		"replay": replay_id,
		"extra": extra.duplicate(true),
		"stage": stage,
		"completions": completions,
		"start_speed": start_speed,
		"start_speed_z": start_speed_z,
		"timescale": timescale,
	}


static func from_dictionary(data: Dictionary) -> DotTimerRecord:
	var record := DotTimerRecord.new()

	record.map_id = StringName(str(data.get("map", "")))
	record.track = clampi(int(data.get("track", 0)), 0, DotTimerTrack.BONUS_LAST)
	record.style_id = StringName(str(data.get("style", "normal")))
	record.player_id = StringName(str(data.get("player", "")))
	record.player_name = str(data.get("name", ""))
	record.time = float(data.get("time", 0.0))
	record.set_at = int(data.get("set_at", 0))
	record.tick_rate = int(data.get("tick_rate", 128))
	record.zone_fingerprint = str(data.get("zones", ""))
	record.points = float(data.get("points", 0.0))
	record.replay_id = str(data.get("replay", ""))
	# Absent in every record written before they existed, and the defaults are what
	# those records were: a whole run, finished once as far as anybody knows, at 1x.
	record.stage = maxi(int(data.get("stage", 0)), 0)
	record.completions = maxi(int(data.get("completions", 1)), 1)
	record.start_speed = float(data.get("start_speed", 0.0))
	record.start_speed_z = float(data.get("start_speed_z", 0.0))
	record.timescale = float(data.get("timescale", 1.0))

	var splits_value: Variant = data.get("splits", {})
	record.splits = (
		(splits_value as Dictionary).duplicate(true) if splits_value is Dictionary
		else {}
	)

	var stats_value: Variant = data.get("stats", {})
	record.stats = (
		(stats_value as Dictionary).duplicate(true) if stats_value is Dictionary
		else {}
	)

	var extra_value: Variant = data.get("extra", {})
	record.extra = (
		(extra_value as Dictionary).duplicate(true) if extra_value is Dictionary
		else {}
	)

	return record


func duplicate_record() -> DotTimerRecord:
	return DotTimerRecord.from_dictionary(to_dictionary())


## Sorts a list fastest-first, in place.
##
## A named helper rather than a lambda at each call site because getting the
## comparison the wrong way round produces a leaderboard that looks plausible and is
## upside down, and it is exactly the kind of thing that is copied.
static func sort_fastest_first(records: Array) -> void:
	records.sort_custom(
		func(a: DotTimerRecord, b: DotTimerRecord) -> bool: return a.time < b.time
	)


func describe() -> Dictionary:
	return {
		"map": String(map_id),
		"track": DotTimerTrack.short_name_of(track),
		"style": String(style_id),
		"stage": stage,
		"player": player_name if player_name != "" else String(player_id),
		"time": formatted_time(),
		"points": "%.1f" % points,
		"tick_rate": tick_rate,
	}


func _to_string() -> String:
	return "DotTimerRecord(%s %s %s)" % [
		String(map_id), formatted_time(),
		player_name if player_name != "" else String(player_id)
	]
