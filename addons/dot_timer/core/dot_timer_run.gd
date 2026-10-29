class_name DotTimerRun
extends RefCounted

## One attempt at a track: how long it has been going, what it has passed, and what the player did.
## Time is whole ticks plus two sub-tick fractions, derived from the simulation, never the wall clock.

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
## Stored on the run so a record can say what it was measured at; a mid-map tickrate change would otherwise re-scale runs in progress.
var tick_interval: float = 1.0 / 128.0

## Fraction of a tick already spent when the run began, 0..1. Subtracted from the total.
var start_offset: float = 0.0

## Fraction of the finishing tick that WAS the player's, 0..1. ADDED, where [member start_offset] is subtracted.
## The finishing tick is not counted by [method advance]; subtracting this instead loses a whole tick, by a different amount per tickrate.
var end_offset: float = 0.0

## Fractional ticks per stage, by stage number.
## Absolute, not per-segment: a comparison against a record needs the absolute one. Fractional so a split reads the same at 64 Hz.
var splits: Dictionary = {}

## Highest stage entered. 0 before the first.
var stage: int = 0

## Ticks spent paused. Not part of the time; kept so a rule can refuse a long one.
var paused_ticks: int = 0

## Whether the player used a practice checkpoint during this attempt. Sticky for the rest of the run.
## Clearing it on stopping would let anybody file a record for the last thirty seconds of a map.
var used_checkpoints: bool = false

## Whether anything else the game considers disqualifying helped the player: noclip, a spawned prop, an admin teleport.
## Set by the game; sticky.
var tainted: bool = false

## Whether the run reached a CHECKER without its VALIDATOR — a shortcut the map closes.
## Sticky, and set by the timer.
var skipped: bool = false

## VALIDATOR numbers passed during this attempt.
var validated: Dictionary = {}

## Movement statistics, as a plain dictionary.
## Not a typed stats class: dot-timer must compile without dot-player-controller. The host folds them in with [method note_stats].
var stats: Dictionary = {}

## Highest speed seen during the run, in m/s. The one statistic the timer measures
## itself, because a HUD wants it and every game has a velocity.
var max_speed: float = 0.0

## Sum of per-tick speed, for the average.
var _speed_sum: float = 0.0

## Horizontal and vertical speed on the tick the run began, m/s. What a start-speed rule
## judged, kept on the record so the rule can be checked afterwards.
var start_speed: float = 0.0
var start_speed_z: float = 0.0

## Seconds of run time per second of simulated time. 1 for every normal style.
## A slow-motion style measures in slowed time, so its runs compare only with each other. Fixed for the life of a run.
var time_scale: float = 1.0


static func make(
	p_track: int, p_style: StringName, p_tick_interval: float
) -> DotTimerRun:
	var run := DotTimerRun.new()
	run.track = p_track
	run.style_id = p_style
	run.tick_interval = p_tick_interval
	return run


## The run's elapsed time in seconds, the one place ticks become seconds. Never negative.
## A run beginning and ending inside one tick would otherwise sort to the top of every leaderboard.
func time() -> float:
	return maxf(
		(float(ticks) - start_offset + end_offset) * tick_interval * time_scale, 0.0
	)


## The time at a stage, in seconds, or -1 if it has not been reached.
func split_time(number: int) -> float:
	if not splits.has(number):
		return -1.0

	return maxf((float(splits[number]) - start_offset) * tick_interval * time_scale, 0.0)


## The time of a stage line: 0 for the start, the split for line [param line], and the
## run's time for [code]-1[/code], the finish. -1 when that line has not been reached.
func line_time(line: int) -> float:
	if line == 0:
		return 0.0
	if line < 0:
		return time() if status == Status.FINISHED else -1.0
	return split_time(line)


## The time spent on section [param section], or -1 if the run has not crossed both of its lines.
## [param total_sections] is [code]n + 1[/code] so the last section knows it ends at the finish; a skipped first line gives no time.
func section_time(section: int, total_sections: int = 0) -> float:
	if section <= 0:
		return -1.0
	var from := line_time(section - 1)
	var to_line := -1 if total_sections > 0 and section >= total_sections else section
	var to := line_time(to_line)
	if from < 0.0 or to < 0.0 or to < from:
		return -1.0
	return to - from

func is_running() -> bool:
	return status == Status.RUNNING


func is_active() -> bool:
	return status == Status.RUNNING or status == Status.PAUSED


func average_speed() -> float:
	return _speed_sum / float(ticks) if ticks > 0 else 0.0



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
	skipped = false
	validated.clear()
	stats.clear()
	max_speed = 0.0
	_speed_sum = 0.0
	start_speed = 0.0
	start_speed_z = 0.0


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
## Refused rather than overwritten: walking back through a stage zone would replace the split with a later, worse one.
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



## The run as plain data, to be put back later — a player who dropped mid-run and came
## back. Everything that decides the run's time and whether it may be filed, and nothing
## that only describes it.
func to_snapshot() -> Dictionary:
	var split_out := {}
	for number in splits:
		split_out[str(number)] = splits[number]
	return {
		"status": int(status),
		"track": track,
		"style": String(style_id),
		"ticks": ticks,
		"tick_interval": tick_interval,
		"start_offset": start_offset,
		"splits": split_out,
		"stage": stage,
		"paused_ticks": paused_ticks,
		"used_checkpoints": used_checkpoints,
		"tainted": tainted,
		"skipped": skipped,
		"validated": validated.keys(),
		"stats": stats.duplicate(true),
		"max_speed": max_speed,
		"speed_sum": _speed_sum,
		"start_speed": start_speed,
		"start_speed_z": start_speed_z,
		"time_scale": time_scale,
	}


## A run rebuilt from [method to_snapshot]. Null when the data is not one.
## Restored PAUSED whatever it was saved as: the clock must not count the time spent reconnecting.
static func from_snapshot(data: Dictionary) -> DotTimerRun:
	if not data.has("ticks") or not data.has("tick_interval"):
		return null
	var run := DotTimerRun.make(
		int(data.get("track", DotTimerTrack.MAIN)),
		StringName(str(data.get("style", "normal"))),
		float(data["tick_interval"])
	)
	if run.tick_interval <= 0.0:
		return null
	run.status = Status.PAUSED
	run.ticks = maxi(int(data["ticks"]), 0)
	run.start_offset = clampf(float(data.get("start_offset", 0.0)), 0.0, 1.0)
	var split_in: Variant = data.get("splits", {})
	if split_in is Dictionary:
		for key in split_in:
			run.splits[int(key)] = float(split_in[key])
	run.stage = int(data.get("stage", 0))
	run.paused_ticks = int(data.get("paused_ticks", 0))
	run.used_checkpoints = bool(data.get("used_checkpoints", false))
	run.tainted = bool(data.get("tainted", false))
	run.skipped = bool(data.get("skipped", false))
	var validated_in: Variant = data.get("validated", [])
	if validated_in is Array:
		for number in validated_in:
			run.validated[int(number)] = true
	var stats_in: Variant = data.get("stats", {})
	run.stats = (stats_in as Dictionary).duplicate(true) if stats_in is Dictionary else {}
	run.max_speed = float(data.get("max_speed", 0.0))
	run._speed_sum = float(data.get("speed_sum", 0.0))
	run.start_speed = float(data.get("start_speed", 0.0))
	run.start_speed_z = float(data.get("start_speed_z", 0.0))
	run.time_scale = float(data.get("time_scale", 1.0))
	return run



## A time as [code]m:ss.mmm[/code], or [code]h:mm:ss.mmm[/code] past an hour.
## Always three decimals: these boards are decided by thousandths and two would make ties of runs that were not tied.
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
