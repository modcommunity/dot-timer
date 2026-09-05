class_name DotTimerRun
extends RefCounted

## One attempt at a track: how long it has been going, what it has passed, and what
## the player did during it.
##
## [b]Time is counted in ticks, plus two fractions.[/b] Not in seconds, and the
## difference decides whether two servers can share a leaderboard.
##
## A float accumulator drifts: adding 1/128 to a running total ten thousand times does
## not give the same answer as multiplying, and two servers with different frame
## pacing reach different totals for identical play. A tick counter is exact — but a
## tick counter alone quantises every run to the tick, so the same run is worth up to
## 15 ms more on a 64 Hz server than on a 128 Hz one, which on a leaderboard sorted to
## the millisecond means the tickrate wins.
##
## So: whole ticks, plus the fraction of a tick the player was already past the start
## line when the first tick was sampled, minus the fraction they were past the finish
## line when the last one was. Both fractions come from where the player was along the
## segment they crossed on ([method DotTimer._crossing_fraction]). What comes out is
## comparable across tickrates to well under a millisecond, which is what a shared
## leaderboard needs.
##
## [b]Everything here is derived from the simulation, never from the wall clock.[/b]
## A timer that reads [code]Time.get_ticks_msec()[/code] can be sped up by lagging the
## server, is not reproducible from a replay, and disagrees with itself when the
## server catches up after a stall.

enum Status {
	## Not running. The player is somewhere on the map with no attempt in progress.
	STOPPED,
	## Running.
	RUNNING,
	## Held. Ticks do not accumulate, and the pause itself is timed separately.
	PAUSED,
	## Finished. Kept rather than reset so the result can be read.
	FINISHED,
}

var status: Status = Status.STOPPED

var track: int = DotTimerTrack.MAIN

## The style this attempt is on. A change means a new attempt; see [DotTimer].
var style_id: StringName = &"normal"

## Whole ticks accumulated. The trustworthy half of the time.
var ticks: int = 0

## Seconds per tick. Fixed for the life of a run.
##
## Stored on the run rather than looked up because a record has to be able to say what
## it was measured at: a server that changes its tickrate mid-map would otherwise
## silently re-scale every run in progress.
var tick_interval: float = 1.0 / 128.0

## Fraction of a tick already spent when the run began, 0..1.
##
## Subtracted from the total: the player crossed the start line partway through the
## tick, so that part of it was not theirs.
var start_offset: float = 0.0

## Fraction of the finishing tick that WAS the player's, 0..1.
##
## [b]Added, where [member start_offset] is subtracted, and the asymmetry is the
## whole of a real bug.[/b] The finishing tick is not counted by [method advance] —
## the run is already FINISHED by the time it runs — so the part of that tick spent
## getting to the line has to be added back. Storing "the part after the line" and
## subtracting it instead loses a whole tick: 7.8 ms at 128 Hz and 15.6 ms at 64 Hz,
## which is both wrong and, worse, wrong by a DIFFERENT amount at each tickrate —
## exactly the tickrate dependence the sub-tick fractions exist to remove. The
## self-test measured it at 7.8 ms and named it to the microsecond.
var end_offset: float = 0.0

## Fractional ticks per stage, by stage number.
##
## Absolute rather than per-segment: a HUD shows both, only one of them can be stored
## without loss, and the absolute one is what a comparison against a record needs.
##
## Fractional for the reason the run's own time is: a split quantised to the tick is a
## split that reads differently on a 64 Hz server, and a player comparing their splits
## against a record set elsewhere would find every one of them systematically off.
var splits: Dictionary = {}

## Highest stage entered. 0 before the first.
var stage: int = 0

## Ticks spent paused. Not part of the time; kept so a rule can refuse a long one.
var paused_ticks: int = 0

## Whether the player used a practice checkpoint during this attempt.
##
## [b]Sticky, and it must be.[/b] A run in which the player teleported back to a
## checkpoint is not a run, and clearing this when they stop using them would let
## anybody file a record for the last thirty seconds of a map.
var used_checkpoints: bool = false

## Whether the player was helped by anything else the game considers disqualifying —
## noclip, a spawned prop, an admin teleport.
##
## Set by the game, sticky for the same reason.
var tainted: bool = false

## Movement statistics, as a plain dictionary.
##
## A dictionary rather than a [code]DotFpsStats[/code] because dot-timer must compile
## without dot-fps-controller. The host folds its own statistics in with
## [method note_stats]; a 2D game supplies whatever it measures instead.
var stats: Dictionary = {}

## Highest speed seen during the run, in m/s. The one statistic the timer measures
## itself, because a HUD wants it and every game has a velocity.
var max_speed: float = 0.0

## Sum of per-tick speed, for the average.
var _speed_sum: float = 0.0


static func make(
	p_track: int, p_style: StringName, p_tick_interval: float
) -> DotTimerRun:
	var run := DotTimerRun.new()
	run.track = p_track
	run.style_id = p_style
	run.tick_interval = p_tick_interval
	return run


## The run's elapsed time in seconds.
##
## [b]The one place ticks become seconds.[/b] Everything upstream is integer; every
## comparison, every record and every leaderboard uses this. Never negative: a run
## that begins and ends inside one tick would otherwise report a negative time, and a
## negative time sorts to the top of every leaderboard ever built.
func time() -> float:
	return maxf(
		(float(ticks) - start_offset + end_offset) * tick_interval, 0.0
	)


## The time at a stage, in seconds, or -1 if it has not been reached.
func split_time(number: int) -> float:
	if not splits.has(number):
		return -1.0

	return maxf((float(splits[number]) - start_offset) * tick_interval, 0.0)


func is_running() -> bool:
	return status == Status.RUNNING


func is_active() -> bool:
	return status == Status.RUNNING or status == Status.PAUSED


func average_speed() -> float:
	return _speed_sum / float(ticks) if ticks > 0 else 0.0


# --- Mutation --------------------------------------------------------------

func begin(offset: float) -> void:
	status = Status.RUNNING
	ticks = 0
	start_offset = clampf(offset, 0.0, 1.0)
	end_offset = 0.0
	splits.clear()
	stage = 0
	paused_ticks = 0
	used_checkpoints = false
	tainted = false
	stats.clear()
	max_speed = 0.0
	_speed_sum = 0.0


## Advances by one tick. [param speed] feeds the speed statistics.
func advance(speed: float) -> void:
	if status == Status.PAUSED:
		paused_ticks += 1
		return

	if status != Status.RUNNING:
		return

	ticks += 1
	max_speed = maxf(max_speed, speed)
	_speed_sum += speed


func finish(offset: float) -> void:
	end_offset = clampf(offset, 0.0, 1.0)
	status = Status.FINISHED


func stop() -> void:
	status = Status.STOPPED


func pause() -> bool:
	if status != Status.RUNNING:
		return false
	status = Status.PAUSED
	return true


func resume() -> bool:
	if status != Status.PAUSED:
		return false
	status = Status.RUNNING
	return true


## Records reaching a stage. False if it was already reached.
##
## Already-reached is refused rather than overwritten because a player who walks back
## through a stage zone — which happens constantly on maps where the route doubles
## back — would otherwise overwrite their split with a later, worse one.
func mark_stage(number: int, offset: float = 0.0) -> bool:
	if number <= 0 or splits.has(number):
		return false

	# The tick the stage line was crossed on has not been counted yet — mark_stage
	# runs inside the tick, before advance() — so the fraction of it spent reaching
	# the line is added, exactly as the finishing tick's is.
	splits[number] = float(ticks) + clampf(offset, 0.0, 1.0)
	stage = maxi(stage, number)

	return true


func note_stats(data: Dictionary) -> void:
	for key in data:
		stats[key] = data[key]


func paused_time() -> float:
	return float(paused_ticks) * tick_interval


# --- Presentation ----------------------------------------------------------

## A time as [code]m:ss.mmm[/code], or [code]h:mm:ss.mmm[/code] past an hour.
##
## [b]Three decimal places, always.[/b] These leaderboards are decided by
## thousandths — a world record beaten by 4 ms is a normal event in this genre — and
## a display that rounds to two makes ties out of runs that were not tied.
static func format_time(seconds: float, sign_prefix: bool = false) -> String:
	var negative := seconds < 0.0
	var total := absf(seconds)

	var hours := int(total / 3600.0)
	var minutes := int(fmod(total, 3600.0) / 60.0)
	var rest := fmod(total, 60.0)

	var text := ""

	if hours > 0:
		text = "%d:%02d:%06.3f" % [hours, minutes, rest]
	else:
		text = "%d:%06.3f" % [minutes, rest]

	if sign_prefix:
		return ("-" if negative else "+") + text

	return ("-" if negative else "") + text


func formatted_time() -> String:
	return format_time(time())


func describe() -> Dictionary:
	return {
		"status": Status.keys()[status],
		"track": DotTimerTrack.name_of(track),
		"style": String(style_id),
		"time": formatted_time(),
		"ticks": ticks,
		"stage": stage,
		"splits": splits.size(),
		"max_speed": "%.1f m/s" % max_speed,
		"checkpoints": used_checkpoints,
		"tainted": tainted,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var fields := describe()

	for key in fields:
		out.append("%-12s %s" % [key, str(fields[key])])

	return out


func _to_string() -> String:
	return "DotTimerRun(%s %s %s)" % [
		Status.keys()[status], DotTimerTrack.short_name_of(track), formatted_time()
	]
