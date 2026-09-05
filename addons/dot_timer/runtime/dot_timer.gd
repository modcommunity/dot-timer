class_name DotTimer
extends RefCounted

## The timer for one player: starts, splits, finishes, and reports what the map asked
## for along the way.
##
## [codeblock]
## var timer := DotTimer.new()
## timer.bind(zone_set, 128)
##
## # every simulated tick
## sample.position = player_position
## sample.velocity = player_velocity
## sample.grounded = player_is_grounded
## timer.tick(sample)
## [/codeblock]
##
## [b]One instance per player, and no singletons anywhere.[/b] A server times thirty
## of these at once, a replay viewer runs another over the same map, and a test runs
## a hundred in one process.
##
## [b]The timer decides; the game acts.[/b] Nothing here teleports a player, kills
## one, changes their gravity or refuses their jump. It reports what the zone asked
## for and the host does it — because "teleport" means something different in a
## first-person controller, a 2D game and a replay being scrubbed, and a timer that
## knew how to do it would only work in one of them.
##
## [b]Everything is counted in simulated ticks.[/b] No wall clock, anywhere. A timer
## that read the system clock could be sped up by lagging the server, would not
## reproduce from a replay, and would disagree with itself after a stall.

const CHANNEL := "timer"

## Fired when a run begins. [param run] is live and will keep changing.
signal run_started(run: DotTimerRun)

## Fired when one ends successfully. The run is FINISHED and will not change again.
signal run_finished(run: DotTimerRun)

## Fired when one is abandoned: a stop zone, a death, a style change, a reset.
signal run_stopped(run: DotTimerRun, reason: StringName)

## Fired on reaching a stage for the first time in a run.
signal stage_reached(number: int, split_seconds: float)

## Fired the tick a player enters or leaves any zone.
##
## [b]Every zone, including the ones the timer acts on itself.[/b] A HUD wants to say
## "in the start zone", a sound wants to play at a stage, and an anti-cheat wants to
## know about a teleport — none of which the timer should have opinions about.
signal zone_entered(zone: DotTimerZone)
signal zone_exited(zone: DotTimerZone)

## The zone asked for something the host has to do: a teleport, a respawn, a slay.
##
## [param zone] carries the destination and the payload. Emitted rather than acted on
## for the reason in the class documentation.
signal effect_requested(zone: DotTimerZone)

## The set of "while you are inside this" zones the player is in changed.
##
## Gravity, air acceleration, no-jump, auto-hop, freestyle, speed limits. The host
## reads [method active_effects] and applies whatever it supports. One signal for the
## whole set rather than one per kind, because they compose and a host applying them
## one at a time has to work out what to undo.
signal effects_changed()

## Why a run stopped. StringNames rather than an enum so a game can add its own.
const REASON_ZONE := &"zone"
const REASON_DEATH := &"death"
const REASON_STYLE := &"style"
const REASON_TRACK := &"track"
const REASON_RESET := &"reset"
const REASON_CHECKPOINT := &"checkpoint"
const REASON_TELEPORT := &"teleport"
const REASON_PAUSE_EXPIRED := &"pause_expired"

## Zone kinds that ask the HOST to do something the moment the player enters one.
##
## [b]Distinct from [constant EFFECT_KINDS], which describe a condition while
## inside.[/b] These fire once, on entry, through [signal effect_requested] — and the
## timer never acts on any of them itself, because what "respawn" means is different
## in a first-person game, a 2D game and a replay being scrubbed.
const REQUEST_KINDS: Array[DotTimerZone.Kind] = [
	DotTimerZone.Kind.RESPAWN,
	DotTimerZone.Kind.SLAY,
	DotTimerZone.Kind.TELEPORT,
	DotTimerZone.Kind.CUSTOM,
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

## Whether this timer is the authority.
##
## [b]A client runs one too, and it must not file records.[/b] Predicting the timer
## locally is what makes the HUD respond on the tick rather than a round trip later,
## and it is also what would let a modified client announce a world record. The server
## sets this; a client leaves it false and treats its own answer as a display.
var authoritative: bool = false

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


# --- The tick --------------------------------------------------------------

## Advances the timer by one simulated tick.
##
## [b]Call once per simulated tick, from the same loop the movement runs in.[/b] Not
## from [code]_process[/code]: a timer sampled per frame counts a different number of
## ticks on a 144 Hz monitor than on a 60 Hz one, and a player's time then depends on
## their hardware. Not twice for a replayed tick either — see
## [member DotFpsController.stats] for the same hazard on the other side.
func tick(sample: DotTimerSample) -> void:
	ticks_processed += 1

	if index == null:
		return

	index.zones_at(sample.position, _found)

	_diff_membership(_found)
	_rebuild_effects(_found)

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
		if zone.track != track:
			# A zone belonging to another track is still reported as entered — a HUD
			# and an anti-cheat both want to know — but it never affects this run.
			# Without this a bonus finish line ends a main-track run, which is the
			# most common way a hand-drawn zone file ruins a leaderboard.
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
			_:
				pass

	# Started on LEAVING the start zone, not on entering it.
	#
	# This is how every timer in this genre works and it is not arbitrary: the start
	# zone is where a player builds their speed up, and timing from the moment they
	# enter it would time their run-up. It also means the boundary is crossed exactly
	# once per attempt, in a known direction, which is what makes the sub-tick
	# fraction below meaningful.
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

	# Last, so the timer's own state for this tick is complete before the host is
	# asked to move anybody: a respawn handler calls straight back in through
	# `stop()`, and doing that halfway through a tick leaves the run counted against
	# a position the timer has not carried forward yet.
	_request_effects()


## Asks the host to act on the act-on-entry zones entered this tick.
##
## [b]This is the only thing that fires [signal effect_requested], and for a long
## time nothing did.[/b] The signal was declared, the manager forwarded it, and both
## games connected a handler — so a RESPAWN zone under a surf map did nothing at all
## and a player who fell off fell for ever. Nothing errored: a zone kind the timer
## has no rule for is a legitimate thing to find, and the whole design says the timer
## must not act on one itself. The family's own pattern, in its commonest shape — a
## value produced correctly and consumed by nothing, except that here it was the
## other way round and nothing produced it.
##
## Once on entry, not every tick while inside. A respawn that re-fired each tick
## would fight a host that moves the player over several frames, and a teleport that
## did would be a loop for any two zones pointing at each other.
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

		if zone.kind in REQUEST_KINDS:
			effect_requested.emit(zone)


## Rolls this tick's position forward to be the next tick's "previous".
##
## [b]Owned by the timer, not by the host.[/b] The sub-tick crossing fraction is
## computed from the segment between two ticks, so a host that maintained this itself
## and got it wrong — updated it twice, or before the timer ran — would produce times
## that are subtly and permanently wrong with nothing in the run to explain it.
func _carry(sample: DotTimerSample) -> void:
	sample.previous_position = sample.position


# --- Membership and effects ------------------------------------------------

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
			# Last one wins on a tie, which for overlapping zones of the same kind is
			# the highest id — the most recently drawn. A mapper correcting a gravity
			# volume by drawing a new one over the old one gets the new one, which is
			# what they meant.
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
##
## The host reads this on [signal effects_changed] and applies whatever it supports.
## Kinds it does not understand are simply not applied, which is the correct behaviour
## for a map that uses a zone type this game does not have.
func active_effects() -> Dictionary:
	return _effects


## The effect zone of one kind in force, or null.
func effect(kind: DotTimerZone.Kind) -> DotTimerZone:
	var found: Variant = _effects.get(kind)
	return found if found is DotTimerZone else null


## Whether an EFFECT zone of this kind is in force. See [member EFFECT_KINDS].
func is_inside(kind: DotTimerZone.Kind) -> bool:
	return _effects.has(kind)


## Whether the player is standing in a zone of this kind on this run's track —
## any kind, START and END included, which [method is_inside] does not answer.
## The prespeed clamp asks this; asking [method is_inside] about START is always
## false, and the clamp then never runs.
func in_zone(kind: DotTimerZone.Kind) -> bool:
	for id in _inside:
		var zone: DotTimerZone = _inside[id]
		if zone.kind == kind and zone.track == track:
			return true
	return false


# --- Starting and finishing ------------------------------------------------

func _try_start(sample: DotTimerSample) -> void:
	if not sample.alive:
		return

	# Some styles require the player to be on the ground when the run begins, which
	# stops them building speed outside the start zone and diving through it.
	if style != null and not style.allow_air_start and not sample.grounded:
		return

	var start_zone := _zone_for(DotTimerZone.Kind.START)

	var fraction := 0.0

	if start_zone != null:
		fraction = _crossing_fraction(
			start_zone, sample.previous_position, sample.position
		)

	run = DotTimerRun.make(track, _style_id(), tick_interval())
	run.begin(fraction)

	runs_started += 1
	_pause_ticks = 0

	DotLog.debug(CHANNEL, "run started", {
		"track": track, "style": String(run.style_id), "offset": fraction
	})

	run_started.emit(run)


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


## Where along the last tick's movement the player crossed [param zone]'s boundary,
## 0..1.
##
## [b]This is what makes a 64 Hz run comparable with a 128 Hz one.[/b] A timer that
## counted whole ticks quantises every run to its tickrate: the same play is worth up
## to 15 ms more on a 64 Hz server than on a 128 Hz one, and on a leaderboard sorted
## to the millisecond the tickrate decides the ordering. The community timers solve
## it the same
## way, and it is the single most important line in the file for anybody who wants two
## servers to share a records table.
##
## Linear along the segment, using the signed distance to the zone's surface. The
## player's path within one tick is not exactly a straight line — gravity curves it —
## but over 8 ms at plausible speeds the error is micrometres, and the alternative
## (re-simulating the tick at a finer step) would have to be done identically on every
## machine that ever recomputes the time.
func _crossing_fraction(
	zone: DotTimerZone,
	from: Vector3,
	to: Vector3
) -> float:
	var d_from := zone.signed_distance(from)
	var d_to := zone.signed_distance(to)

	# Both ends STRICTLY on the same side: the boundary was not crossed on this
	# segment. The player was already through when the tick began — teleported in, or
	# the zone is thinner than one tick of travel. Zero is the honest answer: no part
	# of this tick is being discounted.
	#
	# [b]Strictly, and a distance of exactly zero is neither side.[/b] Zero IS the
	# boundary, so it terminates the crossing at whichever end it is on. Folding it
	# into "inside" — the obvious spelling, `d <= 0.0` — throws the whole fraction
	# away in the one case that is not rare at all: a player whose per-tick step
	# divides the distance to the line lands on it exactly, which with a fixed step
	# and an axis-aligned zone happens on any course built out of round numbers.
	# dot-timer's 2D suite caught it as every run being exactly one tick long, at
	# both tickrates, which is precisely the tickrate-dependent error the fractions
	# exist to remove.
	#
	# It cannot be fixed by choosing the other spelling either: a box is half-open —
	# [method DotTimerZone.contains] includes its lower bound and excludes its
	# upper — so a distance of zero is inside at one face and outside at the
	# opposite one, and a signed distance cannot tell which face it is at.
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


# --- Control ---------------------------------------------------------------

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
##
## [b]Abandoned, not carried over.[/b] The style is an input to the movement, so half
## a run under one style and half under another is a run on neither — and a player who
## could switch to low gravity for the hard section would do exactly that.
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


## Marks the run as having used a practice checkpoint.
##
## [b]Sticky for the rest of the attempt.[/b] A run in which the player restored a
## saved position is not a run, and clearing the flag when they stop using them would
## let anybody file a record for the last thirty seconds of a map. On a style that
## does not allow checkpoints at all, the run is abandoned instead — which is the
## honest thing to do, because continuing to time a run that can never be filed just
## wastes the player's next four minutes.
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


# --- Filing a record -------------------------------------------------------

## Whether the finished run may be recorded, and why not if it may not.
##
## [b]Every one of these refusals exists because of a real exploit.[/b] The minimum
## time stops a start and finish drawn close enough to touch producing an unbeatable
## 0.02 second world record. The checkpoint and taint flags stop a segmented or
## assisted run being filed as a clean one. The zone fingerprint stops a record set
## before a finish line moved being compared with one set after.
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

	if finished.used_checkpoints:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The run used practice checkpoints."
		)

	if finished.tainted:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The run was assisted."
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
