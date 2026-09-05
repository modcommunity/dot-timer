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


## Starts a new recording, discarding anything in progress.
func begin(
	map_id: StringName,
	track: int,
	style_id: StringName,
	player_name: String,
	tick_rate: int
) -> void:
	replay = DotTimerReplay.new()
	replay.map_id = map_id
	replay.track = track
	replay.style_id = style_id
	replay.player_name = player_name
	replay.tick_rate = maxi(tick_rate, 1)
	replay.recorded_at = int(Time.get_unix_time_from_system())

	recording = true
	overflowed = 0


## Takes one frame. Call once per simulated tick while a run is in progress.
func capture(
	position: Vector3,
	yaw: float,
	pitch: float,
	flags: int = 0
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

	replay.append(position, yaw, pitch, flags)


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

	var out := replay
	replay = null

	return out


## Throws away the recording. For every run that did not beat anything.
func discard() -> void:
	recording = false
	replay = null
	overflowed = 0


func frame_count() -> int:
	return replay.frames.size() if replay != null else 0


func describe() -> Dictionary:
	return {
		"recording": recording,
		"frames": frame_count(),
		"overflowed": overflowed,
	}
