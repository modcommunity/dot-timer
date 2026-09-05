extends Node2D

## Proves the timer works in 2D, end to end, with nothing 3D anywhere in it.
##
## [codeblock]
## godot --headless --path . res://examples/timer_2d_selftest.tscn
## [/codeblock]
##
## [b]The claim under test is the one that decides whether this addon is worth
## having twice.[/b] dot-timer says it is dimension-agnostic — the same timer, the
## same records, the same replay format and the same leaderboard for a 3D surf map
## and a 2D racing course — and that claim is easy to make and easy to be wrong
## about. So this file is a whole 2D game in miniature: a `Node2D` world, zones
## authored as `DotTimerZoneVolume2D` nodes in a scene, a body moved by 2D vectors,
## and a run that starts, splits, finishes and files a record.
##
## Nothing here mentions [Vector3] except where the sample demands one, which is
## exactly what a 2D game has to write:
##
## [codeblock]
## sample.position = Vector3(body.position.x, body.position.y, 0.0)
## [/codeblock]
##
## [b]The trap this exists to catch is the third axis.[/b] A rectangle drawn in the
## 2D editor has zero thickness on Z, and a box with zero thickness contains nothing
## at all — so a zone authored the obvious way never fires, silently, with no error.
## [method DotTimerZone.flatten_for_2d] is what fixes it and
## [DotTimerZoneVolume2D] is what applies it, and both are checked here.

## The host's own units. A 2D game's "metres" are pixels, and the timer does not
## care — but the numbers below have to be self-consistent for the expected times
## to be arithmetic rather than a measurement.
const TICK_RATE := 60
const SPEED := 240.0

## The course: a start box, a finish box, and two stage lines between them.
const START_X := 0.0
const START_W := 100.0
const FINISH_X := 1300.0
const FINISH_W := 100.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-timer 2D self-test")
	print("")

	_test_zones_are_authored_in_2d()
	_test_a_2d_run()
	_test_the_third_axis_trap()
	await _test_a_2d_record()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)


func _check_near(
	value: float, expected: float, epsilon: float, what: String
) -> void:
	_check(
		absf(value - expected) <= epsilon, what,
		"%.4f vs %.4f" % [value, expected]
	)


## Builds the course as a tree of [DotTimerZoneVolume2D] nodes, then collects it.
##
## Built in code here because this is a test; a real 2D game places these nodes in
## the editor and calls the same [method DotTimerZoneVolume2D.collect].
func _build_course() -> Node2D:
	var course := Node2D.new()
	course.name = "Course"
	add_child(course)

	var start := DotTimerZoneVolume2D.new()
	start.name = "Start"
	start.kind = DotTimerZone.Kind.START
	start.size = Vector2(START_W, 400.0)
	start.position = Vector2(START_X + START_W * 0.5, 0.0)
	course.add_child(start)

	var finish := DotTimerZoneVolume2D.new()
	finish.name = "Finish"
	finish.kind = DotTimerZone.Kind.END
	finish.size = Vector2(FINISH_W, 400.0)
	finish.position = Vector2(FINISH_X + FINISH_W * 0.5, 0.0)
	course.add_child(finish)

	for i in range(1, 3):
		var stage := DotTimerZoneVolume2D.new()
		stage.name = "Stage%d" % i
		stage.kind = DotTimerZone.Kind.STAGE
		stage.number = float(i)
		stage.size = Vector2(20.0, 400.0)
		stage.position = Vector2(400.0 * float(i), 0.0)
		course.add_child(stage)

	var spawn := DotTimerZoneVolume2D.new()
	spawn.name = "Spawn"
	spawn.kind = DotTimerZone.Kind.SPAWN
	spawn.position = Vector2(20.0, 0.0)
	course.add_child(spawn)

	return course


func _test_zones_are_authored_in_2d() -> void:
	print("zones authored in the 2D editor")

	var course := _build_course()
	var zones := DotTimerZoneVolume2D.collect(course, &"course_2d")

	_check(zones.zones.size() == 5, "five nodes become five zones",
		"%d" % zones.zones.size())
	_check(zones.problems().is_empty(), "and the set is well formed",
		", ".join(zones.problems()))
	_check(
		zones.playable_tracks() == PackedInt32Array([DotTimerTrack.MAIN]),
		"with one playable track"
	)
	_check(zones.stage_count(DotTimerTrack.MAIN) == 2, "and two stages")

	# The third axis. A 2D game's sample is (x, y, 0), so every zone has to contain
	# that plane — which a rectangle drawn in the editor does not, until it is
	# flattened.
	var start := zones.first_of_kind(DotTimerZone.Kind.START, DotTimerTrack.MAIN)

	_check(
		start.contains(Vector3(START_X + 10.0, 0.0, 0.0)),
		"a point on the z = 0 plane is inside the start zone"
	)
	_check(
		start.size().z > 1e6,
		"because the volume is unbounded on the third axis",
		"%.1f" % start.size().z
	)

	course.queue_free()


func _test_a_2d_run() -> void:
	print("a 2D run")

	var course := _build_course()
	var zones := DotTimerZoneVolume2D.collect(course, &"course_2d")

	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(zones, TICK_RATE)

	var style := DotTimerStyle.new()
	style.minimum_time = 0.0
	timer.style = style

	var finished: Array[DotTimerRun] = []
	timer.run_finished.connect(
		func(run: DotTimerRun) -> void: finished.append(run)
	)

	var stages := PackedInt32Array()
	timer.stage_reached.connect(
		func(number: int, _split: float) -> void: stages.append(number)
	)

	# A body moving right along the X axis at a fixed speed. This is the whole of a
	# 2D game as far as the timer is concerned.
	var body := Node2D.new()
	body.position = Vector2(-100.0, 0.0)
	course.add_child(body)

	var sample := DotTimerSample.new()
	sample.grounded = true
	sample.position = Vector3(body.position.x, body.position.y, 0.0)
	sample.previous_position = sample.position

	var step := SPEED / float(TICK_RATE)

	while body.position.x < FINISH_X + 300.0:
		body.position.x += step

		# The one line a 2D game writes, and the reason the timer needs nothing else.
		sample.position = Vector3(body.position.x, body.position.y, 0.0)
		sample.velocity = Vector3(SPEED, 0.0, 0.0)

		timer.tick(sample)

	_check(timer.runs_started == 1, "one run starts", "%d" % timer.runs_started)
	_check(finished.size() == 1, "and one finishes", "%d" % finished.size())

	if finished.size() != 1:
		course.queue_free()
		return

	var run := finished[0]

	# Leaves the start at x = 100, reaches the finish at x = 1300: 1200 units at
	# 240 units per second. The zones are placed so this is exact arithmetic rather
	# than a measurement, exactly as the 3D corridor's are.
	_check_near(
		run.time(), (FINISH_X - START_W) / SPEED, 0.01,
		"and the time is the distance over the speed"
	)

	_check(stages == PackedInt32Array([1, 2]), "both stages are reached in order",
		str(stages))
	_check(run.split_time(1) > 0.0, "and the first split has a time",
		"%.3f" % run.split_time(1))
	_check(
		run.split_time(2) > run.split_time(1),
		"and the second is later than the first"
	)

	# The sub-tick fractions work here too, which is the point of testing 2D at all:
	# a 2D game with a 60 Hz server and a 2D game with a 120 Hz server must produce
	# comparable times, or the whole shared-records idea is 3D-only.
	var at_120 := _run_at(120)
	var at_60 := run.time()

	_check(
		absf(at_120 - at_60) < 0.002,
		"and 60 Hz and 120 Hz agree to under two milliseconds",
		"%.5f vs %.5f" % [at_60, at_120]
	)

	course.queue_free()


## Runs the same course at another tick rate and returns the time.
func _run_at(tick_rate: int) -> float:
	var course := _build_course()
	var zones := DotTimerZoneVolume2D.collect(course, &"course_2d")

	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(zones, tick_rate)

	var sample := DotTimerSample.new()
	sample.grounded = true
	sample.position = Vector3(-100.0, 0.0, 0.0)
	sample.previous_position = sample.position

	var x := -100.0
	var step := SPEED / float(tick_rate)

	while x < FINISH_X + 300.0:
		x += step
		sample.position = Vector3(x, 0.0, 0.0)
		sample.velocity = Vector3(SPEED, 0.0, 0.0)
		timer.tick(sample)

	var time := timer.run.time()
	course.queue_free()

	return time


func _test_the_third_axis_trap() -> void:
	print("the third-axis trap")

	# What a 2D game gets if it builds a zone by hand from its own coordinates and
	# forgets that a box needs depth. This is the failure the volume node exists to
	# prevent, and it is silent: the zone is drawn, saved, listed and does nothing.
	var naive := DotTimerZone.make(DotTimerZone.Kind.START)
	naive.set_box(Vector3(0.0, 0.0, 0.0), Vector3(100.0, 400.0, 0.0))

	_check(
		not naive.contains(Vector3(50.0, 200.0, 0.0)),
		"a hand-built 2D box contains nothing, with no error anywhere"
	)

	naive.flatten_for_2d()

	_check(
		naive.contains(Vector3(50.0, 200.0, 0.0)),
		"and flatten_for_2d is what fixes it"
	)

	# And the node does it for you, which is why a 2D game should use the node.
	var node := DotTimerZoneVolume2D.new()
	node.kind = DotTimerZone.Kind.START
	node.size = Vector2(100.0, 400.0)
	add_child(node)

	var zone := node.to_zone()

	_check(
		zone.contains(Vector3(0.0, 0.0, 0.0)),
		"DotTimerZoneVolume2D flattens without being asked"
	)

	node.queue_free()


func _test_a_2d_record() -> void:
	print("a 2D record")

	var course := _build_course()
	var zones := DotTimerZoneVolume2D.collect(course, &"course_2d")

	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = TICK_RATE
	manager.store = DotTimerStoreMemory.new()
	# Replays are recorded from a 2D position exactly as from a 3D one — the
	# container quantises three axes and the third is simply always zero.
	manager.record_replays = true
	add_child(manager)

	var styles := DotTimerStyle.defaults()
	styles[0].minimum_time = 0.0
	manager.set_styles(styles)
	manager.set_zones(zones)
	manager.add_player(&"p2d", "Flat Player")

	var filed: Array[DotTimerRecord] = []
	manager.record_accepted.connect(
		func(record: DotTimerRecord, _p: DotTimerRecord, _r: int) -> void:
			filed.append(record)
	)

	var x := -100.0
	var step := SPEED / float(TICK_RATE)

	while x < FINISH_X + 300.0:
		x += step
		manager.tick_player(
			&"p2d",
			Vector3(x, 0.0, 0.0),
			Vector3(SPEED, 0.0, 0.0),
			true,
			true
		)

	_check(filed.size() == 1, "a 2D run is filed as a record", "%d" % filed.size())

	if filed.size() == 1:
		_check(filed[0].map_id == &"course_2d", "against the 2D map")
		_check(filed[0].time > 0.0, "with a time", filed[0].formatted_time())
		_check(filed[0].tick_rate == TICK_RATE, "and the tick rate it was set at")

	var player := manager.player(&"p2d")
	_check(
		player != null and player.last_replay != null,
		"and a replay was recorded from 2D positions"
	)

	if player != null and player.last_replay != null:
		var bytes := player.last_replay.to_bytes()
		var back := DotTimerReplay.from_bytes(bytes)

		_check(back.ok, "which round-trips through the same container 3D uses")

		if back.ok:
			var frames: Array[DotTimerReplay.Frame] = (
				back.value as DotTimerReplay
			).frames
			_check(
				frames.size() == player.last_replay.frames.size(),
				"with every frame"
			)
			_check(
				absf(frames[frames.size() - 1].position.z) < 0.01,
				"and the unused third axis costs nothing but stays zero"
			)

	var top: DotResult = manager.store.top(&"course_2d", 0, &"normal", 10)
	_check(
		top.ok and (top.value as Array).size() == 1,
		"and the 2D board has one row"
	)

	manager.queue_free()
	course.queue_free()
