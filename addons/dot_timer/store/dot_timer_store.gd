class_name DotTimerStore
extends RefCounted

## Where records live. Subclass to put them somewhere else.
##
## [b]Await every call, including the ones that do not need it.[/b] The memory store
## answers instantly; the SQL store crosses a network. An interface written against the
## fast case has to be rewritten the first time somebody points it at a database — the
## family's own history has that mistake in it twice — so every caller writes
## [code]await store.top(...)[/code], which costs nothing against a store that returns
## at once and is correct against one that does not.
##
## [b]Except the two [code]peek_[/code] methods[/b], which are synchronous on purpose: a
## HUD draws every frame and cannot wait on a database. They answer from whatever the
## store already holds — everything, for the memory store; a cache, for the SQL store —
## and a null means "not known yet", never "nobody has a time".
##
## [b]A store never decides whether a record is allowed.[/b] It writes what it is given.
## Whether a run is fast enough, clean enough and on a ranked style is
## [method DotTimer.can_record], which runs on the authoritative timer where the run
## actually happened — a check inside the store would have to be repeated in every
## implementation and would be missing from somebody's.
##
## [b]A board is (map, track, style, stage).[/b] Stage 0 is the whole run; stage
## [code]k[/code] is section [code]k[/code] of a staged map (see
## [member DotTimerRecord.stage]). Every board query takes the stage last, defaulting to
## the whole run, so a caller that has never heard of sections is unchanged.
##
## [b]Ranks are shared by ties.[/b] Two identical times are both rank 3, and the next is
## rank 5. Awarding the older one the better rank is a rule nobody agreed to, and the
## site ranks the same way.
##
## Shipped: [DotTimerStoreMemory] (tests, a scratch server, and the reference
## implementation), [DotTimerStoreFile] (JSON files), [DotTimerStoreSql] (SQLite,
## Postgres or MySQL through a dot-sql driver).

# No log channel: an abstract interface. Every implementation logs its own trouble, and
# a failed put() is logged by DotTimerManager._file, its one caller.

## How many entries [method recent] may hold. Older entries fall off.
const HISTORY_LIMIT := 2000


# --- Boards ----------------------------------------------------------------

## Files a finish. Returns a [Dictionary]:
##
## [codeblock]
## {
##     "previous": DotTimerRecord or null,  # the player's best before this run
##     "improved": bool,                     # whether this run replaced it
##     "previous_record": DotTimerRecord or null,  # the board's #1 before this run
##     "completions": int,                   # finishes on this board, this one included
## }
## [/codeblock]
##
## [b]Every finish is counted, kept or not.[/b] A slower run does not replace the row but
## does bump its completion count — the only place that sees every finish is the store.
## An improvement is also written to the history [method recent] reads.
func put(_record: DotTimerRecord) -> DotResult:
	return _unsupported("put")


## The fastest [param limit] records on a board, fastest first, from [param offset].
func top(
	_map_id: StringName, _track: int, _style_id: StringName,
	_limit: int = 10, _offset: int = 0, _stage: int = 0
) -> DotResult:
	return _unsupported("top")


## One player's record on a board, or a success carrying null.
##
## [b]Absent is not an error.[/b] A player who has never finished a map is the normal
## case, and making it a failure means every caller has to tell "no record" from "the
## database is down" by inspecting an error code — which somebody will not do.
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
##
## What a practice run, a slower run and a run on an unranked style are told — "that
## would have been 4th" — without anything being filed.
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
##
## [param filter] as for [method records_of]; [code]stage[/code] -1 counts section
## records too.
func record_count(_player_id: StringName, _filter: Dictionary = {}) -> DotResult:
	return _unsupported("record_count")


## The latest improvements, newest first: an [Array] of [Dictionary]
## [code]{record, previous_time, previous_record_time, was_record}[/code].
##
## [param filter] may carry [code]map[/code], [code]track[/code], [code]style[/code],
## [code]stage[/code] and [code]records_only[/code] (default true: only runs that took
## first place when they were set — "latest records", not "latest finishes").
##
## A history, not a view of the boards: a record since beaten is still listed, with the
## time it was, because "who held it before" is half of what this list is for.
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


# --- Players ---------------------------------------------------------------

## Notes that a player was here: their current name, when, and play time to add.
func note_player(
	_player_id: StringName, _name: String, _seen_at: int, _playtime_add: float = 0.0
) -> DotResult:
	return _unsupported("note_player")


## A player's row, or a success carrying null:
## [code]{player, name, points, first_seen, last_seen, playtime}[/code].
func player_info(_player_id: StringName) -> DotResult:
	return _unsupported("player_info")


## Recomputes the points totals of [param player_ids] from their records.
##
## [param weighting] is the decay applied down a player's own list, best first: the
## total is [code]sum(points[i] * weighting^i)[/code], so a hundred mediocre clears are
## worth less than a handful of great ones. 1.0 is a plain sum. [param limit] caps how
## many of a player's records count; 0 counts them all.
##
## [b]Whole runs only.[/b] Section records are a separate ranking and earn nothing here.
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


# --- Maps ------------------------------------------------------------------

## Records what a map is: [code]{map, tier, stages, bonuses, ranked, mapper, info}[/code].
## Upserted — a map's zones being reloaded is the normal way this is called.
func put_map(_info: Dictionary) -> DotResult:
	return _unsupported("put_map")


func map_info(_map_id: StringName) -> DotResult:
	return _unsupported("map_info")


## Every map this store knows, by id.
func maps() -> DotResult:
	return _unsupported("maps")


# --- Progress --------------------------------------------------------------

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


# --- Saved runs ------------------------------------------------------------

## Keeps a run in progress for a player who dropped, to give back when they return.
func save_resume(_player_id: StringName, _map_id: StringName, _state: Dictionary) -> DotResult:
	return _unsupported("save_resume")


## Takes a saved run back — and forgets it, so it can be used once. Null when none.
func take_resume(_player_id: StringName, _map_id: StringName) -> DotResult:
	return _unsupported("take_resume")


# --- Synchronous reads for a HUD -------------------------------------------

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
