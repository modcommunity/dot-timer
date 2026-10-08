class_name DotTimerReplayRecorder
extends RefCounted

## Records a run into a [DotTimerReplay], one frame per tick, with a bounded cost.
##
## [b]The whole design is about not paying for runs nobody keeps.[/b] A server records
## every attempt because it cannot know in advance which one will be a record, and on
## a busy map that is thirty players failing a map every ninety seconds. Two things
## keep it affordable:
##
## - a hard frame cap, so an idle player who started the timer and went to make tea
##   does not accumulate an unbounded array;
## - [method discard], called on every run that did not beat anything, which is the
##   overwhelming majority.
##
## [b]Recorded from the simulation, not from the render loop.[/b] One frame per
## simulated tick means a replay plays back at the rate it was recorded at whatever
## the viewer's frame rate is, and means a client and a server recording the same run
## produce the same number of frames.

const CHANNEL := "timer.replay"

## Longest run that can be recorded, in seconds. Beyond this, recording stops.
##
## Twenty minutes is far longer than any run in this genre and is short enough to
## bound the memory: at 128 Hz it is 154,000 frames, about 900 KB packed.
const MAX_SECONDS := 1200.0

## The ceiling in force. [member DotTimerConfig.max_replay_seconds] lands here
## through the manager; the constant is only the default. It was the only value
## for a while, and the config's knob was documented and read by nothing.
var max_seconds: float = MAX_SECONDS

var replay: DotTimerReplay = null

## Whether frames are being taken.
var recording: bool = false

## Frames dropped because the cap was reached. Non-zero means a truncated replay.
var overflowed: int = 0

## Seconds kept from BEFORE the timer started: the run-up in the start zone, so a ghost or a
## bot following the replay starts at the player's speed rather than at zero. 0 for none.
var pre_roll_seconds: float = 2.0

## Seconds kept AFTER the finish, so a ghost does not stop dead on the line. 0 for none.
var post_roll_seconds: float = 1.0

## A move further than this in one tick is a teleport, not motion, in metres. Far above any
## legitimate speed at a server tick rate (4 m a tick is 512 m/s at 128 Hz, 256 at 64), and
## the game can always say so itself with [constant DotTimerReplay.FLAG_TELEPORT].
var teleport_distance: float = 4.0

## The rolling run-up, newest last, capped at pre_roll_seconds.
var _pre_roll: Array[DotTimerReplay.Frame] = []

## A finished replay still taking its run-out, and how many frames it still wants.
var _trailing: DotTimerReplay = null
var _trail_left: int = 0
var _trail_done: bool = false

var _last_position: Vector3 = Vector3.ZERO
var _have_last: bool = false


## Starts a new recording, discarding anything in progress.
func begin(
	map_id: StringName,
	track: int,
	style_id: StringName,
	player_name: String,
	tick_rate: int
) -> void:
	# A new run ends the last one's run-out: its replay is written now, shorter.
	end_trail()
	replay = DotTimerReplay.new()
	replay.map_id = map_id
	replay.track = track
	replay.style_id = style_id
	replay.player_name = player_name
	replay.tick_rate = maxi(tick_rate, 1)
	replay.recorded_at = int(Time.get_unix_time_from_system())

	# The run-up, so the run starts at the speed the player had when the timer did.
	for frame in _pre_roll:
		replay.frames.append(frame)
	replay.start_frame = replay.frames.size()
	_pre_roll.clear()

	recording = true
	overflowed = 0


## Takes one frame. Call once per simulated tick while a run is in progress.
func capture(
	position: Vector3,
	yaw: float,
	pitch: float,
	flags: int = 0,
	buttons: int = 0
) -> void:
	if not recording or replay == null:
		return

	if replay.frames.size() >= int(maxf(max_seconds, 0.1) * float(replay.tick_rate)):
		if overflowed == 0:
			DotLog.warn(CHANNEL, "replay reached its frame cap; the rest is not recorded", {
				"map": String(replay.map_id), "frames": replay.frames.size()
			})
		overflowed += 1
		return

	replay.append(position, yaw, pitch, flags, buttons)


## Every tick, whether or not a run is going: a run takes the frame, a finished replay takes
## its run-out, and otherwise the frame goes into the rolling run-up. A move further than
## [member teleport_distance] since the last tick is marked as a teleport.
func feed(position: Vector3, yaw: float, pitch: float, flags: int = 0, buttons: int = 0) -> void:
	if _have_last and position.distance_to(_last_position) > teleport_distance:
		flags |= DotTimerReplay.FLAG_TELEPORT
	_last_position = position
	_have_last = true

	if recording:
		capture(position, yaw, pitch, flags, buttons)
		return

	if _trailing != null:
		_trailing.append(position, yaw, pitch, flags, buttons)
		_trail_left -= 1
		if _trail_left <= 0:
			_trailing = null
			_trail_done = true
		return

	var cap := int(maxf(pre_roll_seconds, 0.0) * float(maxi(_rate(), 1)))
	if cap <= 0:
		_pre_roll.clear()
		return
	var frame := DotTimerReplay.Frame.new()
	frame.position = position
	frame.yaw = yaw
	frame.pitch = pitch
	frame.flags = flags
	frame.buttons = buttons & 0xFF
	_pre_roll.append(frame)
	while _pre_roll.size() > cap:
		_pre_roll.pop_front()


## Whether a finished replay has just taken the last of its run-out. True once, then false:
## the manager writes the replay to disk at that moment, so the file has the run-out too.
func take_trail_done() -> bool:
	var done := _trail_done
	_trail_done = false
	return done


## Whether a finished replay is still taking its run-out.
func is_trailing() -> bool:
	return _trailing != null


## Stops the run-out where it is: a new run, a player leaving, a map change.
func end_trail() -> void:
	if _trailing != null:
		_trailing = null
		_trail_done = true


## The tick rate for the run-up's cap, before any replay exists to say it.
var tick_rate: int = 128


func _rate() -> int:
	return replay.tick_rate if replay != null else tick_rate


## Finishes and hands back the replay. Null if nothing was recorded.
##
## [param time] is the run's own time rather than the frame count divided by the tick
## rate: the two differ by the sub-tick offsets at each end, and the replay's header
## should agree with the record it belongs to.
func finish(time: float) -> DotTimerReplay:
	recording = false

	if replay == null or replay.frames.is_empty():
		return null

	replay.time = time
	replay.end_frame = replay.frames.size() - 1

	var out := replay
	replay = null

	# The run-out: the same replay object keeps taking frames for post_roll_seconds.
	var trail := int(maxf(post_roll_seconds, 0.0) * float(out.tick_rate))
	if trail > 0:
		_trailing = out
		_trail_left = trail
	_pre_roll.clear()

	return out


## Throws away the recording. For every run that did not beat anything.
func discard() -> void:
	recording = false
	replay = null
	overflowed = 0
	_pre_roll.clear()


func frame_count() -> int:
	return replay.frames.size() if replay != null else 0


func describe() -> Dictionary:
	return {
		"recording": recording,
		"frames": frame_count(),
		"overflowed": overflowed,
	}
