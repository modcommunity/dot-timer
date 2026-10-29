class_name DotTimerStore
extends RefCounted

## Where records live. Subclass to put them somewhere else.
## Await every call, even where it is not needed (except the two [code]peek_[/code] methods, which a HUD reads synchronously); a store never decides whether a record is allowed.

# No log channel: an abstract interface. Every implementation logs its own trouble, and
# a failed put() is logged by DotTimerManager._file, its one caller.

## How many entries [method recent] may hold. Older entries fall off.
const HISTORY_LIMIT := 2000



## Files a finish. Returns a [Dictionary] with [code]previous[/code], [code]improved[/code], [code]previous_record[/code] and [code]completions[/code].
## Every finish is counted, kept or not: only the store sees them all. An improvement also goes to the history [method recent] reads.
func put(_record: DotTimerRecord) -> DotResult:
	return _unsupported("put")


## The fastest [param limit] records on a board, fastest first, from [param offset].
func top(
	_map_id: StringName, _track: int, _style_id: StringName,
	_limit: int = 10, _offset: int = 0, _stage: int = 0
) -> DotResult:
	return _unsupported("top")


## One player's record on a board, or a success carrying null.
## Absent is not an error: a failure would make every caller tell "no record" from "database down" by error code.
func best_for(
	_map_id: StringName, _track: int, _style_id: StringName,
	_player_id: StringName, _stage: int = 0
) -> DotResult:
	return _unsupported("best_for")


## Where a player stands on a board: 1 for the record, 0 if they have no time.
func rank_of(
	_map_id: StringName, _track: int, _style_id: StringName,
	_player_id: StringName, _stage: int = 0
) -> DotResult:
	return _unsupported("rank_of")


## The rank a time WOULD have on a board: one more than the number strictly faster.
## What a practice or unranked run is told ("that would have been 4th") without anything being filed.
func rank_for_time(
	_map_id: StringName, _track: int, _style_id: StringName,
	_time: float, _stage: int = 0
) -> DotResult:
	return _unsupported("rank_for_time")


## How many players have a time on a board.
func count_on(
	_map_id: StringName, _track: int, _style_id: StringName, _stage: int = 0
) -> DotResult:
	return _unsupported("count_on")


## Removes one player's record. For moderation. Success carries whether one existed.
func remove(
	_map_id: StringName, _track: int, _style_id: StringName,
	_player_id: StringName, _stage: int = 0
) -> DotResult:
	return _unsupported("remove")


## Rewrites the points on records already filed — a re-score after the record on their
## board changed. Only [member DotTimerRecord.points] is written; the key fields find
## the row. Success carries how many were updated.
func set_points(_records: Array) -> DotResult:
	return _unsupported("set_points")


## Every whole-run record one player holds, on every board, for a profile, a "maps
## done" list and a points total. [param filter] may carry [code]style[/code],
## [code]track[/code] and [code]stage[/code] (default 0; -1 for every section too).
func records_of(_player_id: StringName, _filter: Dictionary = {}) -> DotResult:
	return _unsupported("records_of")


## Every record on every board of [param map_id] — what a re-score walks when a map's
## tier changes. Whole runs and sections alike.
func records_on_map(_map_id: StringName) -> DotResult:
	return _unsupported("records_on_map")


## How many whole-run boards [param player_id] holds rank 1 on. A tie for first counts.
## [param filter] as for [method records_of]; [code]stage[/code] -1 counts section records too.
func record_count(_player_id: StringName, _filter: Dictionary = {}) -> DotResult:
	return _unsupported("record_count")


## The latest improvements, newest first: [code]{record, previous_time, previous_record_time, was_record}[/code] dictionaries.
## [param filter] may carry map, track, style, stage and [code]records_only[/code] (default true). A history, not a view: a record since beaten still lists.
func recent(_limit: int = 20, _filter: Dictionary = {}) -> DotResult:
	return _unsupported("recent")


## Deletes every record on a board, every section included when [param stage] is -1.
## Success carries how many went.
func wipe_board(
	_map_id: StringName, _track: int, _style_id: StringName, _stage: int = -1
) -> DotResult:
	return _unsupported("wipe_board")


## Deletes every record, history entry, progress row and saved run of one player.
func wipe_player(_player_id: StringName) -> DotResult:
	return _unsupported("wipe_player")


## Deletes everything filed on one map.
func wipe_map(_map_id: StringName) -> DotResult:
	return _unsupported("wipe_map")



## Notes that a player was here: their current name, when, and play time to add.
func note_player(
	_player_id: StringName, _name: String, _seen_at: int, _playtime_add: float = 0.0
) -> DotResult:
	return _unsupported("note_player")


## A player's row, or a success carrying null:
## [code]{player, name, points, first_seen, last_seen, playtime}[/code].
func player_info(_player_id: StringName) -> DotResult:
	return _unsupported("player_info")


## Recomputes the points totals of [param player_ids] from their records, whole runs only.
## Total is [code]sum(points[i] * weighting^i)[/code], best first; 1.0 is a plain sum. [param limit] caps how many count, 0 = all.
func refresh_player_points(
	_player_ids: Array, _weighting: float = 1.0, _limit: int = 0
) -> DotResult:
	return _unsupported("refresh_player_points")


## The players with the most points, best first:
## [code]{player, name, points, rank}[/code] each.
func top_players(_limit: int = 10, _offset: int = 0) -> DotResult:
	return _unsupported("top_players")


## [code]{rank, total, points}[/code] for one player. Rank 0 with no points.
func player_rank(_player_id: StringName) -> DotResult:
	return _unsupported("player_rank")



## Records what a map is: [code]{map, tier, stages, bonuses, ranked, mapper, info}[/code].
## Upserted — a map's zones being reloaded is the normal way this is called.
func put_map(_info: Dictionary) -> DotResult:
	return _unsupported("put_map")


func map_info(_map_id: StringName) -> DotResult:
	return _unsupported("map_info")


## Every map this store knows, by id.
func maps() -> DotResult:
	return _unsupported("maps")



## Adds to a player's effort on a board: attempts started, seconds spent running, and
## whether this was a finish. The first finish also fixes how long it took to get one.
func note_progress(
	_player_id: StringName, _map_id: StringName, _track: int, _style_id: StringName,
	_attempts: int, _seconds: float, _finished: bool
) -> DotResult:
	return _unsupported("note_progress")


## [code]{attempts, completions, time_spent, time_to_first}[/code] on one board, or a
## success carrying null. [code]time_to_first[/code] is -1 until the first finish.
func progress_for(
	_player_id: StringName, _map_id: StringName, _track: int, _style_id: StringName
) -> DotResult:
	return _unsupported("progress_for")



## Keeps a run in progress for a player who dropped, to give back when they return.
func save_resume(_player_id: StringName, _map_id: StringName, _state: Dictionary) -> DotResult:
	return _unsupported("save_resume")


## Takes a saved run back — and forgets it, so it can be used once. Null when none.
func take_resume(_player_id: StringName, _map_id: StringName) -> DotResult:
	return _unsupported("take_resume")



## The top of a board from what the store already holds, or null if it does not know.
## Never waits. The SQL store also starts fetching it, so the next call knows.
func peek_top(
	_map_id: StringName, _track: int, _style_id: StringName,
	_limit: int = 10, _stage: int = 0
) -> Variant:
	return null


## A player's best from what the store already holds; null if not known, and a
## [code]false[/code] (not null) when it is known that they have none.
func peek_best(
	_map_id: StringName, _track: int, _style_id: StringName,
	_player_id: StringName, _stage: int = 0
) -> Variant:
	return null


## Writes anything held back. The file store batches; the others write as they go.
func flush() -> DotResult:
	return DotResult.success(0)


func describe() -> Dictionary:
	return {
		"implementation": (
			get_script().get_global_name() if get_script() != null else "?"
		),
	}


func _unsupported(method: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.%s() was not overridden." % method
	)
