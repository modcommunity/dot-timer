class_name DotTimerStore
extends RefCounted

## Where records live. Subclass to put them somewhere else.
##
## [b]Every method is asynchronous, including the ones that do not need to be.[/b] The
## in-memory store answers instantly and still returns a coroutine, because the
## alternative — a synchronous interface that an HTTP-backed store cannot implement —
## means every consumer is written against the fast case and has to be rewritten the
## first time somebody points it at a database. The family's own history has that
## mistake in it twice.
##
## [b]A store never decides whether a record is allowed.[/b] It writes what it is
## given. Whether a run is fast enough, clean enough and on a ranked style is
## [method DotTimer.can_record], which runs on the authoritative timer where the run
## actually happened — a check inside the store would have to be repeated in every
## implementation and would be missing from somebody's.
##
## Implementations shipped here:
## [DotTimerStoreMemory] for tests and for a server that does not keep records,
## [DotTimerStoreFile] for a JSON file per board.
## A game wanting SQL or the TMC backbone subclasses this; see dot-leaderboard.

const CHANNEL := "timer.store"


## Files a record. Returns the previous best for the same player, or null.
##
## [b]Returning the previous best rather than a bool[/b] because every caller needs
## it: "you improved your time by 0.4 seconds" is the message a player wants, and
## re-reading it afterwards is a second round trip in the store that just wrote it.
func put(_record: DotTimerRecord) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.put() was not overridden."
	)


## The fastest [param limit] records on a board, fastest first.
func top(
	_map_id: StringName,
	_track: int,
	_style_id: StringName,
	_limit: int = 10
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.top() was not overridden."
	)


## One player's record on a board, or a success carrying null.
##
## [b]Absent is not an error.[/b] A player who has never finished a map is the normal
## case, and making it a failure means every caller has to distinguish "no record" from
## "the database is down" by inspecting an error code — which somebody will not do.
func best_for(
	_map_id: StringName,
	_track: int,
	_style_id: StringName,
	_player_id: StringName
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.best_for() was not overridden."
	)


## Where a player stands on a board: 1 for the record, 0 if they have no time.
func rank_of(
	_map_id: StringName,
	_track: int,
	_style_id: StringName,
	_player_id: StringName
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.rank_of() was not overridden."
	)


## How many players have a time on a board.
func count_on(
	_map_id: StringName,
	_track: int,
	_style_id: StringName
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.count_on() was not overridden."
	)


## Removes one player's record. For moderation.
func remove(
	_map_id: StringName,
	_track: int,
	_style_id: StringName,
	_player_id: StringName
) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "DotTimerStore.remove() was not overridden."
	)


func describe() -> Dictionary:
	return {
		"implementation": (
			get_script().get_global_name() if get_script() != null else "?"
		),
	}
