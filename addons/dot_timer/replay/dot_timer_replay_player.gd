class_name DotTimerReplayPlayer
extends RefCounted

## Plays a [DotTimerReplay] back: seek, scrub, and sample smoothly between frames.
## Sampled at a time, not stepped per rendered frame; yaw is interpolated the short way round.

## The replay being played. Null until [method load_replay].
var replay: DotTimerReplay = null

## Where playback is, in seconds.
var time: float = 0.0

## Playback rate. 0.5 is half speed; negative runs backwards.
var speed: float = 1.0

var playing: bool = false

## Whether playback restarts at the end rather than stopping.
var looping: bool = true


func load_replay(p_replay: DotTimerReplay) -> DotResult:
	if p_replay == null or p_replay.frames.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "That replay has no frames."
		)

	replay = p_replay
	time = 0.0
	playing = false

	return DotResult.success(null)


func duration() -> float:
	return replay.duration() if replay != null else 0.0


func play() -> void:
	playing = replay != null


func pause() -> void:
	playing = false


func seek(seconds: float) -> void:
	time = clampf(seconds, 0.0, duration())


## Advances playback. [param delta] is a frame time, not a tick.
## The one place that takes a frame delta: playback is presentation, not simulation.
func advance(delta: float) -> void:
	if not playing or replay == null:
		return

	time += delta * speed

	var total := duration()

	if total <= 0.0:
		return

	if time > total:
		if looping:
			time = fmod(time, total)
		else:
			time = total
			playing = false
	elif time < 0.0:
		if looping:
			time = total + fmod(time, total)
		else:
			time = 0.0
			playing = false


## The pose at the current time, interpolated between frames.
## Null when nothing is loaded, so a caller checks once.
func sample() -> DotTimerReplay.Frame:
	return sample_at(time)


func sample_at(seconds: float) -> DotTimerReplay.Frame:
	if replay == null or replay.frames.is_empty():
		return null

	var exact := seconds * float(replay.tick_rate)
	var index := int(floor(exact))

	if index < 0:
		return replay.frames[0].duplicate_frame()

	if index >= replay.frames.size() - 1:
		return replay.frames[replay.frames.size() - 1].duplicate_frame()

	var a := replay.frames[index]
	var b := replay.frames[index + 1]
	var t := exact - float(index)

	# Never across a teleport: the player was put there, not carried, and a blend draws them
	# flying through the map between the two places for one tick.
	if b.flags & DotTimerReplay.FLAG_TELEPORT:
		t = 0.0

	var out := DotTimerReplay.Frame.new()
	out.position = a.position.lerp(b.position, t)

	# The short way round. A yaw of 179° and one of -179° are two degrees apart, and
	# lerping them directly spins the model 358° the other way — which reads as the
	# replay being corrupt rather than as an angle-wrapping bug.
	out.yaw = a.yaw + wrapf(b.yaw - a.yaw, -180.0, 180.0) * t
	out.pitch = lerpf(a.pitch, b.pitch, t)

	# Flags are a state, not a quantity: taken from the frame that is actually in
	# force. Interpolating "grounded" would produce a player who is 40% on the floor.
	out.flags = a.flags

	return out


## How fast the replayed player was going at [param seconds], in m/s, from the frames on
## either side, and never across a teleport (0 on the tick of one): a ghost's speed readout
## derived across a 30 m teleport read thousands of metres a second.
func speed_at(seconds: float) -> float:
	if replay == null or replay.frames.size() < 2:
		return 0.0
	var index := clampi(int(floor(seconds * float(replay.tick_rate))), 0, replay.frames.size() - 2)
	var a := replay.frames[index]
	var b := replay.frames[index + 1]
	if b.flags & DotTimerReplay.FLAG_TELEPORT:
		return 0.0
	return a.position.distance_to(b.position) * float(replay.tick_rate)


## The frame index at the current time. For a scrub bar.
func frame_index() -> int:
	if replay == null:
		return 0

	return clampi(
		int(time * float(replay.tick_rate)), 0, maxi(replay.frames.size() - 1, 0)
	)


## How far through, 0..1. For a progress bar.
func progress() -> float:
	var total := duration()
	return clampf(time / total, 0.0, 1.0) if total > 0.0 else 0.0


func describe() -> Dictionary:
	return {
		"loaded": replay != null,
		"playing": playing,
		"time": "%.2f / %.2f s" % [time, duration()],
		"speed": "x%.2f" % speed,
		"frame": frame_index(),
	}
