class_name DotTimer
extends RefCounted

## The timer for one player: starts, splits, finishes, and reports what the map asked for along the way.
## One instance per player; it decides and the host acts; everything is counted in simulated ticks, never the wall clock.

const CHANNEL := "timer"

## Fired when a run begins. [param run] is live and will keep changing.
signal run_started(run: DotTimerRun)

## Fired when one ends successfully. The run is FINISHED and will not change again.
signal run_finished(run: DotTimerRun)

## Fired when one is abandoned: a stop zone, a death, a style change, a reset.
signal run_stopped(run: DotTimerRun, reason: StringName)

## Fired on reaching a stage for the first time in a run.
signal stage_reached(number: int, split_seconds: float)

## Fired the tick a player enters or leaves any zone, including the ones the timer acts on itself.
## A HUD, a sound or an anti-cheat wants to know; the timer has no opinion.
signal zone_entered(zone: DotTimerZone)
signal zone_exited(zone: DotTimerZone)

## The zone asked for something the host has to do: a teleport, a respawn, a slay.
## [param zone] carries the destination and payload. Emitted, not acted on, for the reason in the class documentation.
signal effect_requested(zone: DotTimerZone)

## The set of "while you are inside this" zones the player is in changed.
## One signal for the set, since effects compose and applying them singly leaves the host to work out what to undo.
signal effects_changed()

## Leaving the start did not begin a run, and why ("too fast", "not on the ground long enough").
## Emitted, not swallowed, like [signal DotTimerManager.record_refused].
signal start_refused(reason: String)

## Why a run stopped. StringNames rather than an enum so a game can add its own.
const REASON_ZONE := &"zone"
const REASON_DEATH := &"death"
const REASON_STYLE := &"style"
const REASON_TRACK := &"track"
const REASON_RESET := &"reset"
const REASON_CHECKPOINT := &"checkpoint"
const REASON_TELEPORT := &"teleport"
const REASON_PAUSE_EXPIRED := &"pause_expired"
const REASON_NOCLIP := &"noclip"
const REASON_AUTO_RESTART := &"auto_restart"

## Zone kinds that ask the HOST to do something the moment the player enters one, through [signal effect_requested].
## Distinct from [constant EFFECT_KINDS], which describe a condition while inside.
const REQUEST_KINDS: Array[DotTimerZone.Kind] = [
	DotTimerZone.Kind.RESPAWN,
	DotTimerZone.Kind.SLAY,
	DotTimerZone.Kind.TELEPORT,
	DotTimerZone.Kind.CUSTOM,
]

## Kinds whose request means the host is about to move the player. A teleport that
## follows one is expected; see [member teleport_stop_distance].
const MOVING_KINDS: Array[DotTimerZone.Kind] = [
	DotTimerZone.Kind.RESPAWN,
	DotTimerZone.Kind.TELEPORT,
	DotTimerZone.Kind.CHECKER,
]

## Zone kinds that describe a condition while inside, rather than an event on entry.
const EFFECT_KINDS: Array[DotTimerZone.Kind] = [
	DotTimerZone.Kind.FREESTYLE,
	DotTimerZone.Kind.SPEED_LIMIT,
	DotTimerZone.Kind.EASY_BHOP,
	DotTimerZone.Kind.SLIDE,
	DotTimerZone.Kind.AIR_ACCELERATE,
	DotTimerZone.Kind.GRAVITY,
	DotTimerZone.Kind.PUSH,
	DotTimerZone.Kind.NO_JUMP,
	DotTimerZone.Kind.AUTO_HOP,
]

var zones: DotTimerZoneSet = null
var index: DotTimerZoneIndex = null

## Ticks per second. Must match the host's simulation rate.
var tick_rate: int = 128

## The ranking rules for the style in force. Null means everything is allowed.
var style: DotTimerStyle = null

## The current attempt. Never null; a stopped one is a run with STOPPED status.
var run: DotTimerRun = null

## Which track the player is attempting. Changing it stops a run in progress.
var track: int = DotTimerTrack.MAIN

## Whether this timer is the authority. A client's timer must not file records.
## The server sets this; a client leaves it false and treats its answer as a display, which keeps the HUD on the tick.
var authoritative: bool = false

## Whether a run must pass every stage line to be filed. On by default.
## A map allowing two routes says so in its zone file ([code]meta.enforce_stages: false[/code]).
var enforce_stages: bool = true

## Metres moved in one tick that count as an unexplained teleport, stopping a run in progress. 0 = off.
## Off by default: a host moves players for reasons this timer cannot see. Asked-for teleports are expected for two ticks; see [method expect_teleport].
var teleport_stop_distance: float = 0.0

## Rules a pause must clear. See [method pause_checked].
var pause_rules: bool = true

## Fastest a player may be moving and still pause, m/s.
var pause_max_speed: float = 0.5

## Zones the player was inside on the previous tick, by id.
var _inside: Dictionary = {}

## Zones entered on this tick. Rebuilt every tick by [method _diff_membership].
var _entered: Array[DotTimerZone] = []

## The "while inside" zones in force, by kind. Rebuilt only when the set changes.
var _effects: Dictionary = {}

## Reused per-tick scratch, so a tick allocates nothing.
var _found: Array[DotTimerZone] = []

## Ticks the run has been paused for, checked against the style's limit.
var _pause_ticks: int = 0

## Whether the player was inside the start zone last tick.
##
## The run begins when they LEAVE it, which needs the previous tick's answer.
var _was_in_start: bool = false

## Consecutive grounded ticks, and how long the last grounded stretch was when they left the ground.
## The start rule asks the second: a player who jumped out was not grounded on that tick.
var _ground_ticks: int = 0
var _last_ground_streak: int = 0

## Ticks during which a teleport is expected rather than suspicious.
var _expect_teleport_ticks: int = 0

## Where the player was, and how they were moving, when the run was paused.
var _pause_snapshot: Dictionary = {}

## The start zone the player was last inside, for its own speed rules.
var _start_zone: DotTimerZone = null

## Diagnostic counters.
var ticks_processed: int = 0
var runs_started: int = 0
var runs_finished: int = 0


func _init() -> void:
	run = DotTimerRun.make(track, &"normal", 1.0 / float(tick_rate))


## Binds the timer to a map's zones. Safe to call again on a map change.
func bind(set: DotTimerZoneSet, p_tick_rate: int = 128) -> DotResult:
	if p_tick_rate <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A timer needs a positive tick rate.",
			"%d" % p_tick_rate
		)

	zones = set
	tick_rate = p_tick_rate
	index = DotTimerZoneIndex.of(set)

	# A map change abandons whatever was in progress. Silently carrying a run across
	# one would file a record on the new map for a run set on the old.
	_reset_state(REASON_RESET)

	return DotResult.success(null)


func tick_interval() -> float:
	return 1.0 / float(tick_rate)



## Advances the timer by one simulated tick.
## Call once per simulated tick from the movement loop, never from [code]_process[/code]: a per-frame timer makes a time depend on the monitor.
func tick(sample: DotTimerSample) -> void:
	ticks_processed += 1

	if index == null:
		return

	index.zones_at(sample.position, _found)

	_diff_membership(_found)
	_rebuild_effects(_found)

	if sample.grounded:
		_ground_ticks += 1
	else:
		if _ground_ticks > 0:
			_last_ground_streak = _ground_ticks
		_ground_ticks = 0

	if run.is_active():
		if sample.noclip:
			_stop(REASON_NOCLIP)
		elif (
			teleport_stop_distance > 0.0 and _expect_teleport_ticks <= 0
			and sample.position.distance_to(sample.previous_position) > teleport_stop_distance
		):
			_stop(REASON_TELEPORT)
	if _expect_teleport_ticks > 0:
		_expect_teleport_ticks -= 1

	if not sample.alive:
		# Death abandons the run. Reported before the zone handling so a player who
		# dies inside a finish zone does not finish.
		if run.is_active():
			_stop(REASON_DEATH)
		_was_in_start = false
		_carry(sample)
		return

	var in_start := false

	for zone in _found:
		if zone.kind == DotTimerZone.Kind.START and zone.track == track:
			_start_zone = zone
		if zone.track != track:
			# Another track's zone is reported as entered but never affects this run; else a bonus finish ends a main-track run.
			continue

		match zone.kind:
			DotTimerZone.Kind.START:
				in_start = true
			DotTimerZone.Kind.END:
				_try_finish(sample)
			DotTimerZone.Kind.STAGE:
				_try_stage(zone, sample, int(zone.number))
			DotTimerZone.Kind.STOP:
				if run.is_active():
					_stop(REASON_ZONE)
			DotTimerZone.Kind.VALIDATOR:
				if run.is_active():
					run.validated[int(zone.number)] = true
			_:
				pass

	# Back in the start zone ends the attempt (the HUD reads 0 again), instead of the stale run counting on until the player leaves.
	if in_start and run.is_active():
		_stop(REASON_RESET)

	# Started on LEAVING the start zone: entering would time the run-up, and it makes the crossing happen once, in a known direction.
	if _was_in_start and not in_start:
		_try_start(sample)

	_was_in_start = in_start

	if run.status == DotTimerRun.Status.PAUSED:
		_pause_ticks += 1

		if (
			style != null and style.maximum_pause > 0.0
			and float(_pause_ticks) * tick_interval() > style.maximum_pause
		):
			_stop(REASON_PAUSE_EXPIRED)

	run.advance(sample.velocity.length())

	_carry(sample)

	# Last, so the timer's state is complete before the host moves anybody: a respawn handler calls back in through `stop()`.
	_request_effects()


## Asks the host to act on the act-on-entry zones entered this tick.
## Once on entry, not every tick inside: a respawn that re-fired would fight a host that moves the player over several frames.
func _request_effects() -> void:
	if _entered.is_empty():
		return

	# Iterated over a copy. The host acts synchronously inside the signal and calls
	# back in — `Playground._on_effect_requested` teleports, which stops the run —
	# and a handler that reaches `set_zones` clears the array being walked.
	var entered: Array = _entered.duplicate()

	for zone: DotTimerZone in entered:
		# The same track filter the run itself uses. A bonus track's pit must not
		# respawn somebody attempting the main route past it.
		if zone.track != track:
			continue

		if zone.kind == DotTimerZone.Kind.CHECKER:
			# Only a checker that was not validated sends anybody back, and only during
			# a run: walking through one with no run going is not skipping anything.
			if not run.is_active() or run.validated.has(int(zone.number)):
				continue
			run.skipped = true
		elif not (zone.kind in REQUEST_KINDS):
			continue

		if zone.kind in MOVING_KINDS:
			expect_teleport()
		effect_requested.emit(zone)


## Rolls this tick's position forward to be the next tick's "previous".
## Owned by the timer: a host that updated it twice or before the timer ran would give permanently wrong times.
func _carry(sample: DotTimerSample) -> void:
	sample.previous_position = sample.position



func _diff_membership(current: Array[DotTimerZone]) -> void:
	var now := {}

	_entered.clear()

	for zone in current:
		now[zone.id] = zone
		if not _inside.has(zone.id):
			_entered.append(zone)
			zone_entered.emit(zone)

	for id in _inside:
		if not now.has(id):
			zone_exited.emit(_inside[id])

	_inside = now


func _rebuild_effects(current: Array[DotTimerZone]) -> void:
	var next := {}

	for zone in current:
		if zone.kind in EFFECT_KINDS:
			# Last one wins on a tie, i.e. the highest id: a mapper correcting a volume by drawing a new one over it gets the new one.
			next[zone.kind] = zone

	if next.size() != _effects.size():
		_effects = next
		effects_changed.emit()
		return

	for kind in next:
		if _effects.get(kind) != next[kind]:
			_effects = next
			effects_changed.emit()
			return

	_effects = next


## The "while you are inside this" zones in force, by [enum DotTimerZone.Kind].
## The host applies what it supports; kinds it does not understand are simply not applied.
func active_effects() -> Dictionary:
	return _effects


## The effect zone of one kind in force, or null.
func effect(kind: DotTimerZone.Kind) -> DotTimerZone:
	var found: Variant = _effects.get(kind)
	return found if found is DotTimerZone else null


## Whether an EFFECT zone of this kind is in force. See [member EFFECT_KINDS].
func is_inside(kind: DotTimerZone.Kind) -> bool:
	return _effects.has(kind)


## Whether the player is standing in a zone of this kind on this run's track, START and END included.
## [method is_inside] answers for EFFECT zones only; the prespeed clamp needs this one.
func in_zone(kind: DotTimerZone.Kind) -> bool:
	for id in _inside:
		var zone: DotTimerZone = _inside[id]
		if zone.kind == kind and zone.track == track:
			return true
	return false



func _try_start(sample: DotTimerSample) -> void:
	if not sample.alive:
		return

	# Some styles require the player to be on the ground when the run begins, which
	# stops them building speed outside the start zone and diving through it.
	if style != null and not style.allow_air_start and not sample.grounded:
		return

	var refused := _start_refusal(sample)
	if refused != "":
		start_refused.emit(refused)
		return

	var start_zone := _zone_for(DotTimerZone.Kind.START)

	var fraction := 0.0

	if start_zone != null:
		fraction = _crossing_fraction(
			start_zone, sample.previous_position, sample.position
		)

	run = DotTimerRun.make(track, _style_id(), tick_interval())
	run.time_scale = style.timescale if style != null else 1.0
	run.begin(fraction)
	run.start_speed = Vector2(sample.velocity.x, sample.velocity.z).length()
	run.start_speed_z = sample.velocity.y

	runs_started += 1
	_pause_ticks = 0

	DotLog.debug(CHANNEL, "run started", {
		"track": track, "style": String(run.style_id), "offset": fraction
	})

	run_started.emit(run)


## Why leaving the start does not begin a run, or "" if it does.
## The style's rules, overridden by the start zone's payload ([code]prespeed[/code], [code]no_vertical[/code], [code]ground_seconds[/code]); waived below [member DotTimerStyle.start_rules_below].
func _start_refusal(sample: DotTimerSample) -> String:
	if style == null:
		return ""
	var payload: Dictionary = _start_zone.payload if _start_zone != null else {}
	var speed := Vector2(sample.velocity.x, sample.velocity.z).length()
	if speed <= style.start_rules_below and absf(sample.velocity.y) <= style.start_rules_below:
		return ""

	var cap := float(payload.get("prespeed", style.start_speed_cap))
	if cap > 0.0 and speed > cap:
		return "Too fast leaving the start: %.1f m/s, the limit is %.1f." % [speed, cap]

	var no_vertical := bool(payload.get("no_vertical", style.refuse_vertical_start))
	if no_vertical and absf(sample.velocity.y) > 0.05:
		return "Leave the start on the level, not moving up or down."

	var ground_seconds := float(payload.get("ground_seconds", style.start_ground_seconds))
	if ground_seconds > 0.0:
		var streak := _ground_ticks if sample.grounded else _last_ground_streak
		if float(streak) * tick_interval() < ground_seconds:
			return "Stand in the start for %.1f s before leaving it." % ground_seconds

	return ""


func _try_finish(sample: DotTimerSample) -> void:
	if not run.is_running():
		return

	var end_zone := _zone_for(DotTimerZone.Kind.END)

	# The fraction of this tick spent REACHING the line, which is the player's and is
	# added — see DotTimerRun.end_offset. The finishing tick is never counted by
	# advance(), because the run is FINISHED before it runs.
	var fraction := 0.0

	if end_zone != null:
		fraction = _crossing_fraction(
			end_zone, sample.previous_position, sample.position
		)

	run.finish(fraction)
	runs_finished += 1

	DotLog.info(CHANNEL, "run finished", {
		"track": track,
		"style": String(run.style_id),
		"time": run.formatted_time(),
	})

	run_finished.emit(run)


func _try_stage(
	zone: DotTimerZone, sample: DotTimerSample, number: int
) -> void:
	if not run.is_running():
		return

	var fraction := _crossing_fraction(
		zone, sample.previous_position, sample.position
	)

	if run.mark_stage(number, fraction):
		stage_reached.emit(number, run.split_time(number))


## Where along the last tick's movement the player crossed [param zone]'s boundary, 0..1.
## Linear in the signed distance; the curve of gravity over one tick is micrometres, and re-simulating would have to be identical everywhere.
func _crossing_fraction(
	zone: DotTimerZone,
	from: Vector3,
	to: Vector3
) -> float:
	var d_from := zone.signed_distance(from)
	var d_to := zone.signed_distance(to)

	# Both ends STRICTLY on one side: no crossing on this segment (teleported in, or a zone thinner than a tick), so nothing is discounted.
	# Strictly: a distance of exactly zero IS the boundary, neither side. `d <= 0.0` discards the fraction when a round-number step lands on the line.
	if (d_from > 0.0 and d_to > 0.0) or (d_from < 0.0 and d_to < 0.0):
		return 0.0

	var span := d_from - d_to

	if absf(span) < 1e-9:
		return 0.0

	return clampf(d_from / span, 0.0, 1.0)


func _zone_for(kind: DotTimerZone.Kind) -> DotTimerZone:
	return zones.first_of_kind(kind, track) if zones != null else null


func _style_id() -> StringName:
	return style.id if style != null else &"normal"



## Abandons any run in progress. Idempotent.
func stop(reason: StringName = REASON_RESET) -> void:
	if run.is_active():
		_stop(reason)


func _stop(reason: StringName) -> void:
	var stopped := run
	run = DotTimerRun.make(track, _style_id(), tick_interval())
	_pause_ticks = 0

	stopped.stop()
	run_stopped.emit(stopped, reason)


## Switches track. Any run in progress is abandoned.
func set_track(new_track: int) -> bool:
	if not DotTimerTrack.is_valid(new_track) or new_track == track:
		return false

	if run.is_active():
		_stop(REASON_TRACK)

	track = new_track
	run.track = track
	_was_in_start = false

	return true


## Switches style. Any run in progress is abandoned.
## Abandoned, not carried over: half a run under one style and half under another is a run on neither.
func set_style(new_style: DotTimerStyle) -> bool:
	var new_id: StringName = new_style.id if new_style != null else &"normal"

	if new_id == _style_id():
		style = new_style
		return false

	if run.is_active():
		_stop(REASON_STYLE)

	style = new_style
	run.style_id = new_id

	return true


func pause() -> bool:
	return run.pause()


func resume() -> bool:
	if run.resume():
		_pause_ticks = 0
		return true
	return false


## Pauses the run if the rules allow it, keeping where the player was.
## The rules (not in start or end, grounded, nearly still) stop a pause being a free checkpoint or run-up; the snapshot is what [method resume_checked] hands back.
func pause_checked(sample: DotTimerSample) -> DotResult:
	if not run.is_running():
		return DotResult.fail(DotError.CODE_STATE, "There is no run to pause.")
	if pause_rules and sample != null:
		if in_zone(DotTimerZone.Kind.START) or in_zone(DotTimerZone.Kind.END):
			return DotResult.fail(DotError.CODE_FORBIDDEN, "You cannot pause in the start or the end.")
		if not sample.grounded:
			return DotResult.fail(DotError.CODE_FORBIDDEN, "You can only pause on the ground.")
		if sample.velocity.length() > pause_max_speed:
			return DotResult.fail(DotError.CODE_FORBIDDEN, "Stop moving before you pause.")
	_pause_snapshot = {
		"position": sample.position if sample != null else Vector3.ZERO,
		"velocity": sample.velocity if sample != null else Vector3.ZERO,
	}
	run.pause()
	return DotResult.success(_pause_snapshot.duplicate())


## Resumes a paused run. Success carries the snapshot [method pause_checked] took — the
## host puts the player back there before the next tick, which is why the move that
## follows is an expected teleport rather than a suspicious one.
func resume_checked() -> DotResult:
	if run.status != DotTimerRun.Status.PAUSED:
		return DotResult.fail(DotError.CODE_STATE, "The run is not paused.")
	resume()
	expect_teleport()
	return DotResult.success(_pause_snapshot.duplicate())


## Declares that the host is about to move the player, so the move does not stop the
## run. See [member teleport_stop_distance].
func expect_teleport(ticks: int = 2) -> void:
	_expect_teleport_ticks = maxi(_expect_teleport_ticks, ticks)


## Puts a saved run back — a player who dropped mid-run returning. The run comes back
## PAUSED; the host moves the player to where it was and calls [method resume_checked].
func restore_run(restored: DotTimerRun, at: Vector3 = Vector3.ZERO, velocity: Vector3 = Vector3.ZERO) -> bool:
	# The run is the style it was run on: a run restored onto another style would be
	# filed on that style's board — half a run on low gravity, ranked as normal.
	if restored == null or restored.track != track or restored.style_id != _style_id():
		return false
	if run.is_active():
		_stop(REASON_RESET)
	run = restored
	_pause_snapshot = {"position": at, "velocity": velocity}
	_pause_ticks = 0
	return true


## Marks the run as having used a practice checkpoint. Sticky for the rest of the attempt.
## On a style that disallows checkpoints the run is abandoned instead, since it can never be filed.
func note_checkpoint_used() -> void:
	if not run.is_active():
		return

	if style != null and not style.allow_checkpoints:
		_stop(REASON_CHECKPOINT)
		return

	run.used_checkpoints = true


## Marks the run as helped by something the game considers disqualifying.
func taint() -> void:
	if run.is_active():
		run.tainted = true



## Whether the finished run may be recorded, and why not if it may not.
## Each refusal exists because of a real exploit: minimum time, checkpoint and taint flags, zone fingerprint.
func can_record(finished: DotTimerRun) -> DotResult:
	if not authoritative:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"Only an authoritative timer may file a record.",
			"a client's own timer is a display, not a source"
		)

	if finished == null or finished.status != DotTimerRun.Status.FINISHED:
		return DotResult.fail(
			DotError.CODE_STATE, "That run did not finish."
		)

	if style != null and not style.ranked:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"This style is not ranked.",
			String(style.id)
		)

	# A style that allows checkpoints files the run anyway — that is what the switch
	# means (see DotTimerStyle.allow_checkpoints), and refusing here regardless made a
	# segmented style one that could never file anything.
	if finished.used_checkpoints and not (style != null and style.allow_checkpoints):
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The run used practice checkpoints."
		)

	if finished.tainted:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The run was assisted."
		)

	# After the refusals above on purpose: a run that was assisted AND skipped a stage
	# was assisted, and that is the reason the player should be told.
	if finished.skipped:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The run skipped part of the route."
		)

	if enforce_stages and zones != null:
		var stages := zones.stage_count(finished.track)
		for number in range(1, stages + 1):
			if not finished.splits.has(number):
				return DotResult.fail(
					DotError.CODE_FORBIDDEN,
					"The run missed stage %d." % number,
					"%d of %d stages" % [finished.splits.size(), stages]
				)

	var floor_time := (
		style.minimum_time_for(finished.track) if style != null else 0.0
	)

	if finished.time() < floor_time:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Faster than the shortest run this style records.",
			"%.3f s, floor %.3f s" % [finished.time(), floor_time]
		)

	return DotResult.success(null)


## Builds the record for a finished run. Null when [method can_record] refuses.
func build_record(
	finished: DotTimerRun,
	player_id: StringName,
	player_name: String
) -> DotTimerRecord:
	if not can_record(finished).ok:
		return null

	var record := DotTimerRecord.from_run(
		finished,
		zones.map_id if zones != null else &"",
		player_id,
		player_name
	)

	record.tick_rate = tick_rate

	if zones != null:
		record.zone_fingerprint = zones.fingerprint()

	return record


func _reset_state(reason: StringName) -> void:
	_inside.clear()
	_entered.clear()
	_effects.clear()
	_found.clear()
	_was_in_start = false
	_pause_ticks = 0
	_ground_ticks = 0
	_last_ground_streak = 0
	_expect_teleport_ticks = 0
	_start_zone = null

	if run.is_active():
		_stop(reason)
	else:
		run = DotTimerRun.make(track, _style_id(), tick_interval())


func describe() -> Dictionary:
	return {
		"map": String(zones.map_id) if zones != null else "-",
		"track": DotTimerTrack.name_of(track),
		"style": String(_style_id()),
		"authoritative": authoritative,
		"run": run.describe(),
		"inside": _inside.size(),
		"effects": _effects.size(),
		"started": runs_started,
		"finished": runs_finished,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("map          %s" % (String(zones.map_id) if zones != null else "-"))
	out.append("track        %s" % DotTimerTrack.name_of(track))
	out.append("style        %s" % String(_style_id()))
	out.append("tick rate    %d" % tick_rate)
	out.append("authority    %s" % authoritative)

	for line in run.describe_lines():
		out.append("  " + line)

	return out


func _to_string() -> String:
	return "DotTimer(%s)" % str(run)
