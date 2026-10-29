class_name DotTimerRecord
extends RefCounted

## A finished run, as it is stored, sorted, sent and compared. Plain types only: it goes into JSON, a database and an HTTP body.
## Identity is (map, track, style, player); [method key] builds the composite a store needs.

## Format version, written into every serialised record.
const FORMAT_VERSION := 1

## Which map, by id rather than by path. See [DotTimerZoneSet.map_id].
var map_id: StringName = &""

var track: int = DotTimerTrack.MAIN

var style_id: StringName = &"normal"

## Who set it, in the host's own vocabulary: whatever the host uses for "this player on this server".
## Not a global site id: the identity layer gives per-scope pseudonymous ids so operators cannot correlate players.
var player_id: StringName = &""

## What to show. Denormalised on purpose: a leaderboard has to render without a
## lookup per row, and the name a record was set under is part of the record.
var player_name: String = ""

## The run's time, in seconds.
var time: float = 0.0

## Absolute stage times in seconds, by stage number, as strings->floats survive JSON.
var splits: Dictionary = {}

## Unix seconds. Presentation only; never used for ordering.
## Breaking ties by date would award the older of two identical times, a rule nobody agreed to.
var set_at: int = 0

## Ticks per second the run was measured at.
var tick_rate: int = 128

## The zone set the run was measured against. See the class documentation.
var zone_fingerprint: String = ""

## Movement statistics: jumps, strafes, sync, speeds. Whatever the host measured.
var stats: Dictionary = {}

## Points this completion earned, as computed when it was filed.
## Stored, not recomputed: a total should not silently move when the formula does. A re-rank recomputes deliberately.
var points: float = 0.0

## An opaque handle to the replay, or empty. Where it lives is the store's business.
var replay_id: String = ""

## Anything the game wants to keep with a record.
var extra: Dictionary = {}

## Which section of the track this is the time for. 0 is the whole run.
## Section [code]k[/code] runs from stage line [code]k - 1[/code] (the start) to line [code]k[/code] (the finish for the last); see [method DotTimerRun.section_time].
var stage: int = 0

## How many times the player has finished this board, slower runs included.
## Kept by the store, not the run: only the store sees every finish, including the slower ones it does not keep.
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
## Player excluded: this names the BOARD, not the row; conflating the two is how a player holds a record on a board they were never on.
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


## Whether this record beats [param other]. Strictly: an equal time does not.
## A tie of their own record is not an improvement; replacing the row would move the date and reset the replay.
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
## A named helper: the wrong-way-round comparison gives a plausible but upside-down leaderboard, and gets copied.
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
