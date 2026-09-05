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
	record.tick_rate = int(round(1.0 / maxf(run.tick_interval, 0.000001)))
	record.stats = run.stats.duplicate()
	record.set_at = int(Time.get_unix_time_from_system())

	for number in run.splits:
		record.splits[str(number)] = run.split_time(number)

	return record


## The composite a store keys a leaderboard by.
##
## Player excluded: this names the BOARD, not the row. A store looking up "the record
## for this map, track and style" and a store looking up "this player's best" are the
## same query with a different filter, and conflating the two keys is how a player
## ends up holding the world record on a board they were never on.
func board_key() -> String:
	return "%s/%d/%s" % [String(map_id), track, String(style_id)]


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
