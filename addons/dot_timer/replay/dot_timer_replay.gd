class_name DotTimerReplay
extends RefCounted

## A recorded run: one frame per simulated tick, packed small enough to keep.
##
## [b]Why a replay is the feature that makes a timer worth having.[/b] A leaderboard
## says somebody was fast; a replay shows how, and on a surf or bhop server the
## world-record replay is the tutorial. It is also the only way a disputed record can
## be adjudicated: a time on its own cannot be checked, and a run that took an
## impossible line is obvious in three seconds of playback.
##
## [b]Frames are quantised and delta-encoded, and the reason is arithmetic.[/b] A
## six-minute run at 128 Hz is 46,000 frames. At a naive 32 bytes each — three floats
## of position, two of view, a flags word — that is 1.5 MB per record, times six styles
## times nine tracks times every map on the server. Quantising position to a
## millimetre and view to a tenth of a degree, and storing the difference between
## consecutive frames, brings a typical frame to five or six bytes: about 250 KB for
## the same run, which is a file a browser client can download before the map loads.
##
## [b]Nothing here interpolates or plays anything back.[/b] That is
## [DotTimerReplayPlayer]'s job, and keeping the container dumb is what lets a replay
## be recorded on a server that never renders one and played on a client that never
## records one.

## Magic, so a truncated or wrong file is refused rather than misread.
const MAGIC := 0x44525031  # "DRP1"

const FORMAT_VERSION := 1

## Position quantisation, in metres. A millimetre is far below anything visible and
## keeps a 4 km map inside 22 bits.
const POSITION_SCALE := 1000.0

## View quantisation, in degrees.
const ANGLE_SCALE := 10.0

## A frame that cannot be expressed as a delta is written whole.
##
## Needed for the first frame and for a teleport. Without it a single large jump would
## either overflow the delta fields or force them to be wide enough for the worst case
## on every frame of every replay.
const FLAG_KEYFRAME := 1 << 0
const FLAG_GROUNDED := 1 << 1
const FLAG_DUCKED := 1 << 2
const FLAG_JUMPED := 1 << 3

## Largest delta a short frame can carry, in quantised units.
##
## 16 bits signed: ±32 metres of movement in one tick, which is beyond anything a
## legitimate run reaches at 128 Hz and comfortably above a laggy 64 Hz one.
const MAX_DELTA := 32767

var map_id: StringName = &""
var track: int = DotTimerTrack.MAIN
var style_id: StringName = &"normal"
var player_name: String = ""
var tick_rate: int = 128

## The time the run took, in seconds. Denormalised so a replay browser needs no join.
var time: float = 0.0

## Unix seconds.
var recorded_at: int = 0

## One entry per tick: position, yaw, pitch, flags.
var frames: Array[Frame] = []


## One tick of a recorded run.
class Frame extends RefCounted:
	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var pitch: float = 0.0
	var flags: int = 0

	func duplicate_frame() -> Frame:
		var f := Frame.new()
		f.position = position
		f.yaw = yaw
		f.pitch = pitch
		f.flags = flags
		return f


func duration() -> float:
	return float(frames.size()) / float(maxi(tick_rate, 1))


func append(
	position: Vector3, yaw: float, pitch: float, flags: int = 0
) -> void:
	var frame := Frame.new()
	frame.position = position
	frame.yaw = yaw
	frame.pitch = pitch
	frame.flags = flags
	frames.append(frame)


# --- Encoding --------------------------------------------------------------

static func _quantise(value: float, scale: float) -> int:
	return int(round(value * scale))


static func _dequantise(value: int, scale: float) -> float:
	return float(value) / scale


## Packs the replay into bytes.
##
## Header, then frames. Each frame is one flags byte and then either three 32-bit
## absolute coordinates (a keyframe) or three 16-bit deltas, plus a quantised yaw and
## pitch.
func to_bytes() -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	out.big_endian = false

	out.put_u32(MAGIC)
	out.put_u8(FORMAT_VERSION)
	out.put_u8(clampi(track, 0, 255))
	out.put_u16(clampi(tick_rate, 0, 65535))
	out.put_float(time)
	out.put_u32(recorded_at)
	_put_string(out, String(map_id))
	_put_string(out, String(style_id))
	_put_string(out, player_name)
	out.put_u32(frames.size())

	var previous_x := 0
	var previous_y := 0
	var previous_z := 0
	var have_previous := false

	for frame in frames:
		var x := _quantise(frame.position.x, POSITION_SCALE)
		var y := _quantise(frame.position.y, POSITION_SCALE)
		var z := _quantise(frame.position.z, POSITION_SCALE)

		var keyframe := not have_previous

		if have_previous:
			# A jump larger than the delta field is a teleport, and there is no
			# encoding of it that is not a keyframe. Detected rather than assumed
			# from the flags, because a teleport a game performs itself does not
			# necessarily set one.
			keyframe = (
				absi(x - previous_x) > MAX_DELTA
				or absi(y - previous_y) > MAX_DELTA
				or absi(z - previous_z) > MAX_DELTA
			)

		var flags := frame.flags | (FLAG_KEYFRAME if keyframe else 0)

		out.put_u8(flags & 0xFF)

		if keyframe:
			out.put_32(x)
			out.put_32(y)
			out.put_32(z)
		else:
			out.put_16(x - previous_x)
			out.put_16(y - previous_y)
			out.put_16(z - previous_z)

		out.put_16(_quantise(wrapf(frame.yaw, -180.0, 180.0), ANGLE_SCALE))
		out.put_16(_quantise(clampf(frame.pitch, -90.0, 90.0), ANGLE_SCALE))

		previous_x = x
		previous_y = y
		previous_z = z
		have_previous = true

	return out.data_array


static func _put_string(out: StreamPeerBuffer, text: String) -> void:
	var bytes := text.to_utf8_buffer()

	# Capped rather than refused. A player name arrives from a client and a map id
	# from a manifest; a 64 KB name should cost that one field, not the replay.
	if bytes.size() > 255:
		bytes = bytes.slice(0, 255)

	out.put_u8(bytes.size())
	out.put_data(bytes)


## Reads a length-prefixed string, or returns null if the buffer runs out.
##
## [b]Null rather than an empty string, and that distinction is a real bug.[/b]
## [StreamPeerBuffer] reads past its end by returning zeros rather than failing, so a
## file truncated inside the header produced empty strings, a frame count of zero and
## a perfectly valid-looking replay of nothing. Returning null lets the caller tell
## "the name was blank" from "the file ends here".
static func _get_string(reader: StreamPeerBuffer) -> Variant:
	if reader.get_available_bytes() < 1:
		return null

	var length := reader.get_u8()

	if length == 0:
		return ""

	if reader.get_available_bytes() < length:
		return null

	var data := reader.get_data(length)

	if data[0] != OK:
		return null

	return (data[1] as PackedByteArray).get_string_from_utf8()


static func from_bytes(bytes: PackedByteArray) -> DotResult:
	if bytes.size() < 16:
		return DotResult.fail(
			DotError.CODE_PARSE, "Too short to be a replay.", "%d bytes" % bytes.size()
		)

	var reader := StreamPeerBuffer.new()
	reader.big_endian = false
	reader.data_array = bytes

	if reader.get_u32() != MAGIC:
		return DotResult.fail(
			DotError.CODE_PARSE, "That is not a dot-timer replay."
		)

	var version := reader.get_u8()

	if version > FORMAT_VERSION:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"That replay was written by a newer version of dot-timer.",
			"format %d, this build reads %d" % [version, FORMAT_VERSION]
		)

	# Track, tick rate, time and recorded_at: 1 + 2 + 4 + 4.
	if reader.get_available_bytes() < 11:
		return DotResult.fail(
			DotError.CODE_PARSE, "The replay header is truncated."
		)

	var replay := DotTimerReplay.new()
	replay.track = reader.get_u8()
	replay.tick_rate = reader.get_u16()
	replay.time = reader.get_float()
	replay.recorded_at = reader.get_u32()

	var map_text: Variant = _get_string(reader)
	var style_text: Variant = _get_string(reader)
	var name_text: Variant = _get_string(reader)

	if map_text == null or style_text == null or name_text == null:
		return DotResult.fail(
			DotError.CODE_PARSE, "The replay header is truncated."
		)

	replay.map_id = StringName(map_text)
	replay.style_id = StringName(style_text)
	replay.player_name = name_text

	if reader.get_available_bytes() < 4:
		return DotResult.fail(
			DotError.CODE_PARSE, "The replay ends before its frame count."
		)

	var count := reader.get_u32()

	# A frame is at least 11 bytes, so a count implying more than the buffer can hold
	# is a corrupt or hostile file. Checked before allocating, because the count is
	# 32 bits and allocating what it asks for is how a malformed replay exhausts
	# memory on a server that was only trying to list it.
	if count > bytes.size():
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The replay claims more frames than its size allows.",
			"%d frames in %d bytes" % [count, bytes.size()]
		)

	var x := 0
	var y := 0
	var z := 0

	for _i in range(count):
		if reader.get_available_bytes() < 5:
			return DotResult.fail(
				DotError.CODE_PARSE,
				"The replay ends in the middle of a frame.",
				"%d of %d frames read" % [replay.frames.size(), count]
			)

		var flags := reader.get_u8()

		if flags & FLAG_KEYFRAME:
			x = reader.get_32()
			y = reader.get_32()
			z = reader.get_32()
		else:
			x += reader.get_16()
			y += reader.get_16()
			z += reader.get_16()

		var yaw := _dequantise(reader.get_16(), ANGLE_SCALE)
		var pitch := _dequantise(reader.get_16(), ANGLE_SCALE)

		replay.append(
			Vector3(
				_dequantise(x, POSITION_SCALE),
				_dequantise(y, POSITION_SCALE),
				_dequantise(z, POSITION_SCALE)
			),
			yaw,
			pitch,
			flags & ~FLAG_KEYFRAME
		)

	return DotResult.success(replay)


func save(path: String) -> DotResult:
	var directory := path.get_base_dir()

	if directory != "" and not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return DotResult.failure(DotError.from_engine(made, directory))

	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return DotResult.failure(
			DotError.from_engine(FileAccess.get_open_error(), path)
		)

	file.store_buffer(to_bytes())
	file.close()

	DotWeb.sync_filesystem()

	return DotResult.success(null)


static func load_from(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "No replay there.", path)

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return DotResult.failure(
			DotError.from_engine(FileAccess.get_open_error(), path)
		)

	var bytes := file.get_buffer(file.get_length())
	file.close()

	return from_bytes(bytes)


func describe() -> Dictionary:
	return {
		"map": String(map_id),
		"track": DotTimerTrack.short_name_of(track),
		"style": String(style_id),
		"player": player_name,
		"time": DotTimerRun.format_time(time),
		"frames": frames.size(),
		"bytes": to_bytes().size(),
	}


func _to_string() -> String:
	return "DotTimerReplay(%s %s, %d frames)" % [
		String(map_id), DotTimerRun.format_time(time), frames.size()
	]
