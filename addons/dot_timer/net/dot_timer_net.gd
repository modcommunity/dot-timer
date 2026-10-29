class_name DotTimerNet
extends RefCounted

## What a timer has to replicate, and how to move it between a [DotTimerRun] and a wire.
## The writer and reader are typed [Variant] and called by name, so dot-net is not a dependency (a missing class_name fails the parse).

## Status, as two bits. [enum DotTimerRun.Status] has four members and always will:
## a fifth would be a different concept, not another state of this one.
const STATUS_BITS := 2

## Ticks, as a field wide enough for a run of several hours at 128 Hz.
##
## 22 bits is 4.19 million ticks, or nine hours. A run longer than that is not a run.
const TICK_BITS := 22

## A style, as an index into the server's own ordered table rather than a name.
## An index is 5 bits but meaningless unless both ends build the style table from the same code in a fixed order.
const STYLE_BITS := 5

## Fractional tick offsets, quantised. 10 bits over 0..1 is a thousandth of a tick,
## which at 128 Hz is 8 microseconds — far below what a leaderboard resolves.
const OFFSET_BITS := 10


## What a client needs to run its own copy of a timer.
##
## Written on every change of state, not every tick. See the class documentation.
class RunState extends RefCounted:
	var status: int = DotTimerRun.Status.STOPPED
	var track: int = DotTimerTrack.MAIN
	var style_index: int = 0

	## The server tick the run began on. The client's own tick counter does the rest.
	var start_tick: int = 0

	## The sub-tick offset the run began with. See [DotTimerRun.start_offset].
	var start_offset: float = 0.0

	## Highest stage reached, so a rejoining client's HUD is not blank.
	var stage: int = 0

	func write(writer: Variant) -> void:
		writer.write_uint(status, STATUS_BITS)
		writer.write_uint(track, DotTimerTrack.BITS)
		writer.write_uint(style_index, STYLE_BITS)
		writer.write_uint(start_tick, TICK_BITS)
		writer.write_float_range(start_offset, 0.0, 1.0, OFFSET_BITS)
		writer.write_uint(stage, 6)

	func read(reader: Variant) -> void:
		status = reader.read_uint(STATUS_BITS)
		track = reader.read_uint(DotTimerTrack.BITS)
		style_index = reader.read_uint(STYLE_BITS)
		start_tick = reader.read_uint(TICK_BITS)
		start_offset = reader.read_float_range(0.0, 1.0, OFFSET_BITS)
		stage = reader.read_uint(6)

	static func estimated_bits() -> int:
		return (
			STATUS_BITS + DotTimerTrack.BITS + STYLE_BITS
			+ TICK_BITS + OFFSET_BITS + 6
		)


## A finished run, as the server announces it.
## Sent as ticks and offsets, not a float, so the client reproduces the server's arithmetic exactly.
class Finish extends RefCounted:
	var track: int = DotTimerTrack.MAIN
	var style_index: int = 0
	var ticks: int = 0
	var start_offset: float = 0.0
	var end_offset: float = 0.0

	## Whether the run was filed, and the rank if it was. 0 means it was not.
	var rank: int = 0

	## The same arithmetic as [method DotTimerRun.time]: the start fraction comes off, the end fraction goes on.
	func time(tick_interval: float) -> float:
		return maxf(
			(float(ticks) - start_offset + end_offset) * tick_interval, 0.0
		)

	func write(writer: Variant) -> void:
		writer.write_uint(track, DotTimerTrack.BITS)
		writer.write_uint(style_index, STYLE_BITS)
		writer.write_uint(ticks, TICK_BITS)
		writer.write_float_range(start_offset, 0.0, 1.0, OFFSET_BITS)
		writer.write_float_range(end_offset, 0.0, 1.0, OFFSET_BITS)
		# 12 bits of rank: a board with more than 4095 entries reports 4095, which is
		# "somewhere down the list" and is what a HUD would say anyway.
		writer.write_uint(mini(rank, 4095), 12)

	func read(reader: Variant) -> void:
		track = reader.read_uint(DotTimerTrack.BITS)
		style_index = reader.read_uint(STYLE_BITS)
		ticks = reader.read_uint(TICK_BITS)
		start_offset = reader.read_float_range(0.0, 1.0, OFFSET_BITS)
		end_offset = reader.read_float_range(0.0, 1.0, OFFSET_BITS)
		rank = reader.read_uint(12)

	static func estimated_bits() -> int:
		return (
			DotTimerTrack.BITS + STYLE_BITS + TICK_BITS
			+ OFFSET_BITS * 2 + 12
		)


## Builds the replicated state for a run.
static func state_of(
	run: DotTimerRun, server_tick: int, style_index: int
) -> RunState:
	var out := RunState.new()

	out.status = run.status
	out.track = run.track
	out.style_index = style_index
	out.start_tick = maxi(server_tick - run.ticks, 0)
	out.start_offset = run.start_offset
	out.stage = mini(run.stage, 63)

	return out


static func finish_of(
	run: DotTimerRun, style_index: int, rank: int
) -> Finish:
	var out := Finish.new()

	out.track = run.track
	out.style_index = style_index
	out.ticks = run.ticks
	out.start_offset = run.start_offset
	out.end_offset = run.end_offset
	out.rank = rank

	return out


## Rebuilds a client-side run from replicated state and the client's own tick.
## The client's clock, not the server's, so the HUD advances between packets instead of stepping once per snapshot.
static func run_from_state(
	state: RunState, current_tick: int, tick_interval: float, style_id: StringName
) -> DotTimerRun:
	var run := DotTimerRun.make(state.track, style_id, tick_interval)

	run.status = state.status as DotTimerRun.Status
	run.ticks = maxi(current_tick - state.start_tick, 0)
	run.start_offset = state.start_offset
	run.stage = state.stage

	return run
