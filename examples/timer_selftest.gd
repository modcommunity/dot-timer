extends Node

## Proves the timer does what a leaderboard depends on.
##
## [codeblock]
## godot --headless --path . res://examples/timer_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The most important test here is [method _test_tickrate_agreement].[/b] Everything
## else checks that the timer does what it says; that one checks the claim the whole
## design rests on — that the same run timed on a 64 Hz server and a 128 Hz server
## produces the same time to well under a millisecond, so two servers can share a
## records table. If the sub-tick crossing fractions are wrong, every other test here
## still passes and the leaderboard is decided by the tickrate.
##
## The runs are synthetic: a player is moved along a straight line at a fixed speed,
## one tick at a time, and the timer is ticked with each position. That is deliberate
## — the property under test belongs to [DotTimer], and against a hand-computed path a
## failure has exactly one possible cause.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-timer self-test")
	print("")

	_test_track_names()
	_test_zone_geometry()
	_test_zone_set_validation()
	_test_zone_set_round_trip()
	_test_zone_index()
	_test_basic_run()
	_test_start_on_leaving()
	_test_tickrate_agreement()
	_test_exact_boundary_landing()
	_test_stages_and_splits()
	_test_other_track_ignored()
	_test_stop_and_death()
	_test_style_change_abandons()
	_test_minimum_time()
	_test_checkpoints()
	_test_effect_zones()
	_test_entry_zones_reach_the_host()
	_test_store()
	_test_store_filenames()
	_test_manager()
	_test_tick_rate_configuration()
	_test_checkpoints_practice()
	_test_replay_files()
	_test_replay_round_trip()
	_test_replay_ceiling()
	_test_replay_playback()
	_test_rules()
	_test_points()
	_test_painter()
	_test_time_formatting()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Helpers ---------------------------------------------------------------

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
		absf(value - expected) <= epsilon,
		what,
		"%.6f vs %.6f" % [value, expected]
	)


## A straight corridor along +X: a start box, a finish box, and stages between.
##
## Start occupies x in [0, 4]; the finish x in [96, 100]. So the timed distance from
## leaving the start to reaching the finish is exactly 92 metres, which makes every
## expected time in this file arithmetic rather than a measurement.
func _corridor() -> DotTimerZoneSet:
	var set := DotTimerZoneSet.new()
	set.map_id = &"test_corridor"

	set.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3(0.0, -2.0, -4.0), Vector3(4.0, 4.0, 4.0)
	))
	set.add(DotTimerZone.make(DotTimerZone.Kind.END).set_box(
		Vector3(96.0, -2.0, -4.0), Vector3(100.0, 4.0, 4.0)
	))

	for i in range(1, 4):
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE)
		stage.number = float(i)
		stage.set_box(
			Vector3(float(i) * 24.0, -2.0, -4.0),
			Vector3(float(i) * 24.0 + 2.0, 4.0, 4.0)
		)
		set.add(stage)

	return set


## Walks a player from [param from_x] to [param to_x] at [param speed], ticking the
## timer once per tick. Returns the timer.
##
## Sub-tick positions are deliberate: the player does NOT land exactly on the zone
## boundaries, which is the case the crossing fractions exist for and the case a whole-
## tick timer gets wrong.
func _walk(
	set: DotTimerZoneSet,
	tick_rate: int,
	speed: float,
	from_x: float = -2.0,
	to_x: float = 104.0,
	style: DotTimerStyle = null
) -> DotTimer:
	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(set, tick_rate)
	timer.style = style

	var sample := DotTimerSample.new()
	var step := speed / float(tick_rate)

	var x := from_x
	sample.position = Vector3(x, 0.0, 0.0)
	sample.previous_position = sample.position
	sample.grounded = true

	while x <= to_x:
		x += step
		sample.position = Vector3(x, 0.0, 0.0)
		sample.velocity = Vector3(speed, 0.0, 0.0)
		timer.tick(sample)

	return timer


# --- Tracks ----------------------------------------------------------------

func _test_track_names() -> void:
	print("tracks")

	_check(DotTimerTrack.parse("main") == DotTimerTrack.MAIN, "\"main\" is the main track")
	_check(DotTimerTrack.parse("bonus 3") == 3, "\"bonus 3\" is track 3")
	_check(DotTimerTrack.parse("b2") == 2, "\"b2\" is track 2")
	_check(DotTimerTrack.parse("") == DotTimerTrack.MAIN, "an empty string is main")

	# The refusal matters more than the parses: a console command that read "bonus 9"
	# as "main" would file a record on a track the player did not run.
	_check(DotTimerTrack.parse("bonus 9") == -1, "an out-of-range bonus is refused")
	_check(DotTimerTrack.parse("nonsense") == -1, "and so is nonsense")

	_check(DotTimerTrack.is_bonus(1), "track 1 is a bonus")
	_check(not DotTimerTrack.is_bonus(0), "track 0 is not")


# --- Zones -----------------------------------------------------------------

func _test_zone_geometry() -> void:
	print("zone geometry")

	var box := DotTimerZone.make(DotTimerZone.Kind.START)
	box.set_box(Vector3(4.0, 0.0, 4.0), Vector3(0.0, -2.0, 0.0))

	_check(
		box.from == Vector3(0.0, -2.0, 0.0) and box.to == Vector3(4.0, 0.0, 4.0),
		"set_box normalises the corners whichever way round they are given",
		"%s .. %s" % [str(box.from), str(box.to)]
	)
	_check(box.contains(Vector3(2.0, -1.0, 2.0)), "and contains a point inside")
	_check(not box.contains(Vector3(5.0, -1.0, 2.0)), "and not one outside")

	# Half-open on the upper bound, so two zones sharing a face do not both fire.
	_check(box.contains(Vector3(0.0, -2.0, 0.0)), "the lower corner is inside")
	_check(not box.contains(Vector3(4.0, 0.0, 4.0)), "the upper corner is not")

	_check_near(
		box.signed_distance(Vector3(6.0, -1.0, 2.0)), 2.0, 0.0001,
		"the signed distance outside is the gap"
	)
	_check(
		box.signed_distance(Vector3(2.0, -1.0, 2.0)) < 0.0,
		"and is negative inside"
	)

	var sphere := DotTimerZone.make(DotTimerZone.Kind.END)
	sphere.set_sphere(Vector3(10.0, 0.0, 0.0), 3.0)

	_check(sphere.contains(Vector3(12.0, 0.0, 0.0)), "a sphere contains a near point")
	_check(not sphere.contains(Vector3(14.0, 0.0, 0.0)), "and not a far one")
	_check_near(
		sphere.signed_distance(Vector3(15.0, 0.0, 0.0)), 2.0, 0.0001,
		"and its signed distance is exact"
	)

	# A 2D zone is one whose third axis is unbounded, which is the one thing a 2D
	# game has to get right and the one place it is easy to get wrong.
	var flat := DotTimerZone.make(DotTimerZone.Kind.START)
	flat.set_box(Vector3(0.0, 0.0, 0.0), Vector3(10.0, 10.0, 0.0))

	_check(
		not flat.contains(Vector3(5.0, 5.0, 0.0)),
		"a zero-thickness box contains nothing, which is the 2D trap"
	)

	flat.flatten_for_2d()

	_check(
		flat.contains(Vector3(5.0, 5.0, 0.0)),
		"and flatten_for_2d is what fixes it"
	)


func _test_zone_set_validation() -> void:
	print("zone set validation")

	var good := _corridor()
	_check(good.problems().is_empty(), "a well-formed corridor has no problems",
		", ".join(good.problems()))
	_check(good.playable_tracks() == PackedInt32Array([0]), "and one playable track")
	_check(good.stage_count(DotTimerTrack.MAIN) == 3, "and three stages")

	var no_end := DotTimerZoneSet.new()
	no_end.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3.ZERO, Vector3.ONE
	))

	var problems := no_end.problems()
	_check(problems.size() == 1, "a start with no end is one problem", str(problems))
	_check(
		no_end.playable_tracks().is_empty(),
		"and the track is not offered as playable"
	)

	var two_starts := _corridor()
	two_starts.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3(50.0, 0.0, 0.0), Vector3(52.0, 2.0, 2.0)
	))
	_check(
		two_starts.problems().size() == 1,
		"two start zones on one track is a problem"
	)

	var gap := _corridor()
	gap.add(DotTimerZone.make(DotTimerZone.Kind.STAGE).set_box(
		Vector3(80.0, 0.0, 0.0), Vector3(82.0, 2.0, 2.0)
	))
	gap.zones[gap.zones.size() - 1].number = 9.0

	_check(
		gap.problems().size() > 0,
		"a stage numbered out of sequence is reported"
	)

	# The thin-zone check: a finish thinner than one tick of travel is the classic
	# "my run never ended".
	var thin := DotTimerZoneSet.new()
	thin.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3.ZERO, Vector3(0.05, 3.0, 3.0)
	))

	_check(
		thin.thin_zones(30.0, 128).size() == 1,
		"a 5 cm zone is flagged for a 30 m/s player at 128 Hz"
	)
	_check(
		thin.thin_zones(1.0, 128).is_empty(),
		"and is fine for a slow one"
	)


func _test_zone_set_round_trip() -> void:
	print("zone sets survive JSON")

	var set := _corridor()
	set.meta["tier"] = 4

	var parsed := DotTimerZoneSet.from_json(set.to_json())

	_check(parsed.ok, "a zone set round-trips through JSON",
		parsed.error.message if not parsed.ok else "")

	if not parsed.ok:
		return

	var back: DotTimerZoneSet = parsed.value

	_check(back.zones.size() == set.zones.size(), "with every zone")
	_check(back.map_id == set.map_id, "and the map id")
	_check(int(back.meta.get("tier", 0)) == 4, "and the metadata")
	_check(
		back.fingerprint() == set.fingerprint(),
		"and the same fingerprint",
		"%s vs %s" % [back.fingerprint(), set.fingerprint()]
	)

	# The fingerprint is what a records table is keyed against, so it must ignore a
	# comment and must not ignore a moved finish line.
	var commented := _corridor()
	commented.zones[0].comment = "the start"

	_check(
		commented.fingerprint() == _corridor().fingerprint(),
		"a mapper's comment does not change the fingerprint"
	)

	var moved := _corridor()
	moved.zones[1].from.x += 1.0

	_check(
		moved.fingerprint() != _corridor().fingerprint(),
		"but moving the finish line does"
	)

	var newer := DotTimerZoneSet.from_dictionary({"format": 999, "zones": []})
	_check(not newer.ok, "a file from a newer format is refused")


func _test_zone_index() -> void:
	print("the zone index")

	var set := _corridor()
	var index := DotTimerZoneIndex.of(set)

	var found: Array[DotTimerZone] = []

	index.zones_at(Vector3(2.0, 0.0, 0.0), found)
	_check(found.size() == 1, "a point in the start finds one zone", str(found.size()))
	_check(
		found.size() == 1 and found[0].kind == DotTimerZone.Kind.START,
		"and it is the start"
	)

	index.zones_at(Vector3(50.0, 0.0, 0.0), found)
	_check(found.is_empty(), "a point in open corridor finds none")

	index.zones_at(Vector3(98.0, 0.0, 0.0), found)
	_check(
		found.size() == 1 and found[0].kind == DotTimerZone.Kind.END,
		"and a point in the finish finds the finish"
	)

	# A map-wide volume goes on the "always test" list rather than into a hundred
	# thousand cells.
	var wide := _corridor()
	var gravity := DotTimerZone.make(DotTimerZone.Kind.GRAVITY)
	gravity.number = 0.5
	gravity.set_box(Vector3(-5000.0, -5000.0, -5000.0), Vector3(5000.0, 5000.0, 5000.0))
	wide.add(gravity)

	var wide_index := DotTimerZoneIndex.of(wide)
	wide_index.zones_at(Vector3(50.0, 0.0, 0.0), found)

	_check(found.size() == 1, "a map-wide zone is still found in open space")
	_check(
		int(wide_index.describe()["everywhere"]) == 1,
		"without being written into every cell"
	)


# --- Running ---------------------------------------------------------------

func _test_basic_run() -> void:
	print("a run from start to finish")

	var timer := _walk(_corridor(), 128, 10.0)

	_check(timer.runs_started == 1, "one run started", "%d" % timer.runs_started)
	_check(timer.runs_finished == 1, "and one finished", "%d" % timer.runs_finished)
	_check(
		timer.run.status == DotTimerRun.Status.FINISHED,
		"and the run is in the finished state"
	)

	# 92 metres at 10 m/s. The zones are placed so this is exact arithmetic and not a
	# measurement: leaving x=4 and reaching x=96.
	_check_near(timer.run.time(), 9.2, 0.005, "and the time is the distance over the speed")


func _test_start_on_leaving() -> void:
	print("the run begins on leaving the start zone")

	var set := _corridor()
	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(set, 128)

	var sample := DotTimerSample.new()
	sample.grounded = true
	sample.position = Vector3(-2.0, 0.0, 0.0)
	sample.previous_position = sample.position

	# Sit in the start zone for a hundred ticks. This is the run-up, and none of it
	# is the player's time — which is the whole reason the timer starts on the way
	# out rather than on the way in.
	for i in range(100):
		sample.position = Vector3(-2.0 + float(i) * 0.05, 0.0, 0.0)
		sample.velocity = Vector3(6.4, 0.0, 0.0)
		timer.tick(sample)

	_check(
		timer.run.status == DotTimerRun.Status.STOPPED,
		"a hundred ticks inside the start zone does not start the timer"
	)

	for i in range(200):
		sample.position = Vector3(3.0 + float(i) * 0.1, 0.0, 0.0)
		sample.velocity = Vector3(12.8, 0.0, 0.0)
		timer.tick(sample)

	_check(timer.runs_started == 1, "and leaving it does")

	# The air-start rule.
	var strict := DotTimerStyle.new()
	strict.allow_air_start = false

	var airborne := DotTimer.new()
	airborne.authoritative = true
	airborne.bind(set, 128)
	airborne.style = strict

	var air_sample := DotTimerSample.new()
	air_sample.grounded = false

	for i in range(200):
		air_sample.position = Vector3(2.0 + float(i) * 0.1, 0.0, 0.0)
		air_sample.velocity = Vector3(12.8, 0.0, 0.0)
		airborne.tick(air_sample)

	_check(
		airborne.runs_started == 0,
		"a style that forbids air starts does not begin one in mid-air"
	)

	strict.allow_air_start = true

	var permissive := DotTimer.new()
	permissive.authoritative = true
	permissive.bind(set, 128)
	permissive.style = strict

	var air_sample2 := DotTimerSample.new()
	air_sample2.grounded = false

	for i in range(200):
		air_sample2.position = Vector3(2.0 + float(i) * 0.1, 0.0, 0.0)
		air_sample2.velocity = Vector3(12.8, 0.0, 0.0)
		permissive.tick(air_sample2)

	_check(permissive.runs_started == 1, "and one that allows them does")


func _test_tickrate_agreement() -> void:
	print("two tickrates, one time")

	# The claim the whole design rests on. The same run — same speed, same distance —
	# timed at 64 Hz, 100 Hz and 128 Hz must produce the same number, or a shared
	# leaderboard is decided by whichever server ticks faster.
	#
	# A speed that is not a whole number of ticks per metre on purpose: a run that
	# happened to land exactly on tick boundaries would pass this test with the
	# sub-tick fractions removed entirely.
	var speed := 13.37

	var at_64 := _walk(_corridor(), 64, speed).run.time()
	var at_100 := _walk(_corridor(), 100, speed).run.time()
	var at_128 := _walk(_corridor(), 128, speed).run.time()

	var expected := 92.0 / speed

	_check_near(at_128, expected, 0.001, "128 Hz gives the arithmetic answer")
	_check_near(at_64, expected, 0.001, "so does 64 Hz")
	_check_near(at_100, expected, 0.001, "and so does 100 Hz")

	_check(
		absf(at_64 - at_128) < 0.001,
		"64 Hz and 128 Hz agree to under a millisecond",
		"%.6f vs %.6f, %.1f ms apart" % [
			at_64, at_128, absf(at_64 - at_128) * 1000.0
		]
	)

	# The negative control, and the reason this test is worth its length: a timer
	# that counted whole ticks would be out by up to one tick at each end. At 64 Hz
	# that is 31 ms — thirty times the margin above, and enough to decide any record
	# in this genre.
	var whole_ticks_64 := _walk(_corridor(), 64, speed).run.ticks * (1.0 / 64.0)
	var whole_ticks_128 := _walk(_corridor(), 128, speed).run.ticks * (1.0 / 128.0)

	_check(
		absf(whole_ticks_64 - whole_ticks_128) > 0.002,
		"while counting whole ticks would not",
		"%.1f ms apart" % (absf(whole_ticks_64 - whole_ticks_128) * 1000.0)
	)


func _test_exact_boundary_landing() -> void:
	print("landing exactly on a zone boundary")

	# The case a synthetic course hits every time and a real one hits whenever the
	# numbers are round: a speed whose per-tick step divides the distance to the
	# line, so the player's position lands on it exactly rather than straddling it.
	#
	# A signed distance of zero is the BOUNDARY, not a side. Folding it into
	# "inside" — the obvious spelling — throws the crossing fraction away and makes
	# every run exactly one tick long, at every tickrate. dot-timer's 2D suite found
	# it; this is the 3D control.
	#
	# The corridor's start ends at x = 4 and its finish begins at x = 96. At 120 m/s
	# and 60 Hz the step is exactly 2 m, so a player starting at x = -2 lands on
	# both lines to the metre.
	var timer := _walk(_corridor(), 60, 120.0, -2.0, 120.0)

	_check(timer.runs_finished == 1, "the run finishes")
	_check_near(
		timer.run.time(), 92.0 / 120.0, 0.0005,
		"and a run that lands on both lines exactly is still exact"
	)

	# And at another tickrate, which is the property that actually matters.
	var faster := _walk(_corridor(), 120, 120.0, -2.0, 120.0)

	_check(
		absf(faster.run.time() - timer.run.time()) < 0.0005,
		"and two tickrates that both land on the line still agree",
		"%.6f vs %.6f" % [timer.run.time(), faster.run.time()]
	)


func _test_stages_and_splits() -> void:
	print("stages and splits")

	var timer := _walk(_corridor(), 128, 10.0)
	var run := timer.run

	_check(run.splits.size() == 3, "three stages were recorded", "%d" % run.splits.size())
	_check(run.stage == 3, "and the highest is 3")

	# Stage 1 is at x = 24, so 20 metres past the start line at 10 m/s.
	_check_near(run.split_time(1), 2.0, 0.02, "the first split is the distance to it")
	_check_near(run.split_time(2), 4.4, 0.02, "and the second")
	_check(run.split_time(9) < 0.0, "an unreached stage reports no time")

	# Walking back through a stage must not overwrite the split with a later one.
	var reached := DotTimerRun.make(0, &"normal", 1.0 / 128.0)
	reached.begin(0.0)
	reached.ticks = 100
	reached.mark_stage(1)
	reached.ticks = 500

	_check(not reached.mark_stage(1), "re-entering a stage does not re-mark it")
	_check_near(
		float(reached.splits[1]), 100.0, 0.001, "and the original split stands"
	)


func _test_other_track_ignored() -> void:
	print("a bonus finish does not end a main run")

	var set := _corridor()

	# A bonus finish sitting in the middle of the main corridor. Real maps do this
	# constantly — a bonus route crosses the main one — and a timer that reacted to
	# any finish line would end every main run halfway through.
	var bonus_end := DotTimerZone.make(DotTimerZone.Kind.END, DotTimerTrack.of_bonus(1))
	bonus_end.set_box(Vector3(40.0, -2.0, -4.0), Vector3(44.0, 4.0, 4.0))
	set.add(bonus_end)

	var bonus_start := DotTimerZone.make(
		DotTimerZone.Kind.START, DotTimerTrack.of_bonus(1)
	)
	bonus_start.set_box(Vector3(30.0, -2.0, -4.0), Vector3(32.0, 4.0, 4.0))
	set.add(bonus_start)

	var timer := _walk(set, 128, 10.0)

	_check(timer.runs_finished == 1, "the main run finishes exactly once")
	_check_near(
		timer.run.time(), 9.2, 0.005,
		"and at the main finish line, not the bonus one"
	)


func _test_stop_and_death() -> void:
	print("stopping a run")

	var set := _corridor()
	var stop := DotTimerZone.make(DotTimerZone.Kind.STOP)
	stop.set_box(Vector3(50.0, -2.0, -4.0), Vector3(52.0, 4.0, 4.0))
	set.add(stop)

	var timer := _walk(set, 128, 10.0)

	_check(timer.runs_started == 1, "a run starts")
	_check(timer.runs_finished == 0, "and a stop zone ends it before the finish")

	# Death.
	var dying := DotTimer.new()
	dying.authoritative = true
	dying.bind(_corridor(), 128)

	var reasons := PackedStringArray()
	dying.run_stopped.connect(
		func(_run: DotTimerRun, reason: StringName) -> void:
			reasons.append(String(reason))
	)

	var sample := DotTimerSample.new()
	sample.grounded = true

	for i in range(200):
		sample.position = Vector3(2.0 + float(i) * 0.1, 0.0, 0.0)
		sample.velocity = Vector3(12.8, 0.0, 0.0)
		sample.alive = i < 150
		dying.tick(sample)

	_check(dying.runs_started == 1, "a run starts")
	_check(dying.runs_finished == 0, "and dying ends it")
	_check(
		reasons.size() == 1 and reasons[0] == "death",
		"with the reason reported as a death",
		str(reasons)
	)


func _test_style_change_abandons() -> void:
	print("changing style mid-run")

	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(_corridor(), 128)
	timer.style = DotTimerStyle.defaults()[0]

	var sample := DotTimerSample.new()
	sample.grounded = true

	for i in range(100):
		sample.position = Vector3(2.0 + float(i) * 0.1, 0.0, 0.0)
		sample.velocity = Vector3(12.8, 0.0, 0.0)
		timer.tick(sample)

	_check(timer.run.is_running(), "a run is going")

	var stopped := [0]
	timer.run_stopped.connect(
		func(_run: DotTimerRun, _reason: StringName) -> void: stopped[0] += 1
	)

	timer.set_style(DotTimerStyle.defaults()[1])

	_check(stopped[0] == 1, "switching style abandons it")
	_check(not timer.run.is_active(), "and there is no run in progress")

	timer.set_track(DotTimerTrack.of_bonus(1))
	_check(
		timer.track == DotTimerTrack.of_bonus(1), "switching track works"
	)


func _test_minimum_time() -> void:
	print("the minimum-time floor")

	# A start and a finish drawn overlapping, which is the classic way to
	# manufacture an unbeatable world record.
	var cheat := DotTimerZoneSet.new()
	cheat.map_id = &"cheat"
	cheat.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(
		Vector3(0.0, -2.0, -4.0), Vector3(2.0, 4.0, 4.0)
	))
	# Twenty metres apart, so at 10 m/s the run takes two seconds: under the main
	# track's 3.5 second floor and over a bonus's, which is what makes the pair of
	# checks below a test of the floor rather than of zero.
	cheat.add(DotTimerZone.make(DotTimerZone.Kind.END).set_box(
		Vector3(22.0, -2.0, -4.0), Vector3(24.0, 4.0, 4.0)
	))

	var style := DotTimerStyle.new()
	style.minimum_time = 3.5

	var timer := _walk(cheat, 128, 10.0, -2.0, 30.0, style)

	_check(timer.runs_finished == 1, "the run does finish")
	_check(timer.run.time() < 3.5, "in under the floor", timer.run.formatted_time())

	var allowed := timer.can_record(timer.run)

	_check(not allowed.ok, "and the record is refused")
	_check(
		allowed.ok or allowed.code() == DotError.CODE_INVALID,
		"as invalid rather than as an internal error"
	)

	# A bonus has its own, much lower floor, because bonuses really are that short.
	style.minimum_bonus_time = 0.5
	timer.track = DotTimerTrack.of_bonus(1)
	timer.run.track = DotTimerTrack.of_bonus(1)

	_check(
		timer.can_record(timer.run).ok,
		"while a bonus with a lower floor is accepted"
	)


func _test_checkpoints() -> void:
	print("practice checkpoints")

	var style := DotTimerStyle.new()
	style.minimum_time = 0.0
	style.allow_checkpoints = true

	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(_corridor(), 128)
	timer.style = style

	var sample := DotTimerSample.new()
	sample.grounded = true

	for i in range(1400):
		sample.position = Vector3(2.0 + float(i) * 0.1, 0.0, 0.0)
		sample.velocity = Vector3(12.8, 0.0, 0.0)

		if i == 200:
			timer.note_checkpoint_used()

		timer.tick(sample)

	_check(timer.runs_finished == 1, "the run finishes")
	_check(timer.run.used_checkpoints, "and is flagged as having used a checkpoint")
	_check(
		not timer.can_record(timer.run).ok,
		"so it cannot be filed as a record"
	)

	# On a style that does not allow them at all, using one abandons the run rather
	# than timing four more minutes that can never be filed.
	style.allow_checkpoints = false

	var strict := DotTimer.new()
	strict.authoritative = true
	strict.bind(_corridor(), 128)
	strict.style = style

	var sample2 := DotTimerSample.new()
	sample2.grounded = true

	for i in range(400):
		sample2.position = Vector3(2.0 + float(i) * 0.1, 0.0, 0.0)
		sample2.velocity = Vector3(12.8, 0.0, 0.0)

		if i == 100:
			strict.note_checkpoint_used()

		strict.tick(sample2)

	_check(
		strict.runs_finished == 0,
		"a style that forbids them abandons the run instead"
	)


func _test_effect_zones() -> void:
	print("effect zones")

	var set := _corridor()

	var gravity := DotTimerZone.make(DotTimerZone.Kind.GRAVITY)
	gravity.number = 0.4
	gravity.set_box(Vector3(20.0, -2.0, -4.0), Vector3(40.0, 8.0, 4.0))
	set.add(gravity)

	var no_jump := DotTimerZone.make(DotTimerZone.Kind.NO_JUMP)
	no_jump.set_box(Vector3(60.0, -2.0, -4.0), Vector3(70.0, 8.0, 4.0))
	set.add(no_jump)

	var timer := DotTimer.new()
	timer.bind(set, 128)

	var changes := [0]
	timer.effects_changed.connect(func() -> void: changes[0] += 1)

	var sample := DotTimerSample.new()
	sample.grounded = true

	var seen_gravity := false
	var seen_no_jump := false
	var both_at_once := false

	for i in range(1100):
		sample.position = Vector3(-2.0 + float(i) * 0.1, 0.0, 0.0)
		sample.velocity = Vector3(12.8, 0.0, 0.0)
		timer.tick(sample)

		if timer.is_inside(DotTimerZone.Kind.GRAVITY):
			seen_gravity = true
			if timer.is_inside(DotTimerZone.Kind.NO_JUMP):
				both_at_once = true

		if timer.is_inside(DotTimerZone.Kind.NO_JUMP):
			seen_no_jump = true

	_check(seen_gravity, "the gravity zone comes into force")
	_check(seen_no_jump, "and so does the no-jump zone")
	_check(not both_at_once, "and they do not overlap, as drawn")
	_check(changes[0] == 4, "four changes: two entries and two exits", "%d" % changes[0])
	_check(
		timer.active_effects().is_empty(),
		"and nothing is in force at the end of the corridor"
	)


## RESPAWN, SLAY and TELEPORT reach the host, once, on the right track.
##
## [b]For a long time none of them did.[/b] `effect_requested` was declared, the
## manager forwarded it and both games connected a handler, and nothing anywhere
## emitted it — so a RESPAWN zone under a surf map did nothing and a player who fell
## off fell for ever. Nothing errored. This test would have caught it on the day, and
## every check in it fails without the fix.
func _test_entry_zones_reach_the_host() -> void:
	print("zones that ask the host to act")

	var set := _corridor()

	var pit := DotTimerZone.make(DotTimerZone.Kind.RESPAWN)
	pit.set_box(Vector3(30.0, -2.0, -4.0), Vector3(36.0, 4.0, 4.0))
	set.add(pit)

	var door := DotTimerZone.make(DotTimerZone.Kind.TELEPORT)
	door.set_box(Vector3(60.0, -2.0, -4.0), Vector3(64.0, 4.0, 4.0))
	door.destination = Vector3(80.0, 0.0, 0.0)
	set.add(door)

	# On a bonus track, so the track filter is under test rather than assumed. A
	# main-track runner walking past it must not be respawned by somebody else's pit.
	var other := DotTimerZone.make(
		DotTimerZone.Kind.RESPAWN, DotTimerTrack.BONUS_FIRST
	)
	other.set_box(Vector3(70.0, -2.0, -4.0), Vector3(74.0, 4.0, 4.0))
	set.add(other)

	var timer := DotTimer.new()
	timer.bind(set, 128)

	# An Array, not an int: a lambda captures locals by value, so a counter
	# incremented in a handler reads zero outside it and the test reports a failure
	# for a signal that fired perfectly.
	var seen: Array[DotTimerZone] = []
	timer.effect_requested.connect(
		func(zone: DotTimerZone) -> void: seen.append(zone)
	)

	var sample := DotTimerSample.new()
	sample.grounded = true

	# Walked through all four volumes in one pass, at a speed that puts several ticks
	# inside each: an effect that fired per tick rather than per entry would be
	# counted here as a dozen.
	for i in range(900):
		sample.position = Vector3(-2.0 + float(i) * 0.1, 0.0, 0.0)
		sample.velocity = Vector3(12.8, 0.0, 0.0)
		timer.tick(sample)

	var kinds: Array[int] = []
	for zone in seen:
		kinds.append(zone.kind)

	_check(
		kinds.has(DotTimerZone.Kind.RESPAWN),
		"a respawn zone asks the host to act"
	)
	_check(
		kinds.has(DotTimerZone.Kind.TELEPORT),
		"and so does a teleport zone"
	)
	_check(seen.size() == 2, "once each, on entry", "%d requests" % seen.size())
	_check(
		not kinds.has(DotTimerZone.Kind.START)
		and not kinds.has(DotTimerZone.Kind.STAGE),
		"and the zones the timer acts on itself are not sent to the host"
	)

	for zone in seen:
		_check(
			zone.track == DotTimerTrack.MAIN,
			"a bonus track's pit does not respawn a main-track runner"
		)

	# The destination travels with it: a host that had to look the zone up again
	# would be reading a set that may have changed under a map vote.
	for zone in seen:
		if zone.kind == DotTimerZone.Kind.TELEPORT:
			_check(
				zone.destination.is_equal_approx(Vector3(80.0, 0.0, 0.0)),
				"and a teleport carries where it sends the player"
			)

	# A dead player is not asked about: death abandons the run before the zones are
	# looked at, and a corpse being respawned by a pit it slid into is the host's
	# own respawn to decide on.
	seen.clear()
	sample.alive = false

	for i in range(60):
		sample.position = Vector3(31.0 + float(i) * 0.01, 0.0, 0.0)
		timer.tick(sample)

	_check(seen.is_empty(), "nothing is requested for a dead player")


# --- Records ---------------------------------------------------------------

func _test_store() -> void:
	print("the records store")

	var store := DotTimerStoreMemory.new()

	var first := _record(&"alice", 30.0)
	var wrote := store.put(first)

	_check(wrote.ok, "a first record is accepted")
	_check(wrote.value == null, "with no previous best")

	var slower := _record(&"alice", 35.0)
	var second := store.put(slower)

	_check(second.ok, "a slower run by the same player is not an error")
	_check(second.value == first, "and reports the record it did not beat")

	var top := store.top(&"m", 0, &"normal", 10)
	_check((top.value as Array).size() == 1, "the board still has one row")
	_check_near(
		(top.value[0] as DotTimerRecord).time, 30.0, 0.0001,
		"and it is the faster time"
	)

	var faster := _record(&"alice", 25.0)
	store.put(faster)

	top = store.top(&"m", 0, &"normal", 10)
	_check_near(
		(top.value[0] as DotTimerRecord).time, 25.0, 0.0001,
		"a faster run replaces it"
	)

	store.put(_record(&"bob", 27.0))
	store.put(_record(&"carol", 40.0))

	top = store.top(&"m", 0, &"normal", 10)
	_check((top.value as Array).size() == 3, "three players, three rows")
	_check(
		(top.value[0] as DotTimerRecord).player_id == &"alice"
		and (top.value[1] as DotTimerRecord).player_id == &"bob"
		and (top.value[2] as DotTimerRecord).player_id == &"carol",
		"sorted fastest first"
	)

	_check(int(store.rank_of(&"m", 0, &"normal", &"bob").value) == 2, "bob is second")
	_check(
		int(store.rank_of(&"m", 0, &"normal", &"nobody").value) == 0,
		"a player with no time has no rank"
	)
	_check(int(store.count_on(&"m", 0, &"normal").value) == 3, "and the board counts three")

	# A tie does not displace the incumbent: an equal time is not an improvement.
	store.put(_record(&"dave", 25.0))
	top = store.top(&"m", 0, &"normal", 10)
	_check(
		(top.value[0] as DotTimerRecord).player_id == &"alice"
		or (top.value[0] as DotTimerRecord).time == 25.0,
		"a tie sits alongside rather than overwriting"
	)

	var best := store.best_for(&"m", 0, &"normal", &"alice")
	_check(best.ok and best.value != null, "a player's own best is found")

	var missing := store.best_for(&"m", 0, &"normal", &"nobody")
	_check(
		missing.ok and missing.value == null,
		"and an absent one is a success carrying null, not a failure"
	)

	# Boards are separate: a record on one style must not appear on another.
	var other_style := _record(&"alice", 1.0)
	other_style.style_id = &"sideways"
	store.put(other_style)

	_check(
		int(store.count_on(&"m", 0, &"normal").value) == 4,
		"a record on another style stays off this board"
	)
	_check(
		int(store.count_on(&"m", 0, &"sideways").value) == 1,
		"and appears on its own"
	)


func _test_store_filenames() -> void:
	print("records files cannot collide")

	var store := DotTimerStoreFile.at("user://test_records")

	# The bug this guards: `is_valid_identifier()` is false for a digit on a
	# single-character string, so using it as the filter replaced every digit in a
	# map id with an underscore — and in a genre whose maps are called
	# `surf_kitsune2` and `surf_kitsune3`, those two then shared one records file
	# with their times merged into one leaderboard, silently.
	var a := store.path_for(&"surf_kitsune2", 0, &"normal")
	var b := store.path_for(&"surf_kitsune3", 0, &"normal")

	_check(a != b, "two maps differing only by a digit get different files",
		"%s vs %s" % [a, b])
	_check(a.contains("surf_kitsune2"), "and the digit survives into the name", a)

	# Substitution is many-to-one, so anything it changes gets a hash of the
	# original — otherwise two awkward names still collide.
	var c := store.path_for(&"surf/one", 0, &"normal")
	var d := store.path_for(&"surf\\one", 0, &"normal")

	_check(c != d, "two ids that sanitise to the same string still differ",
		"%s vs %s" % [c, d])
	_check(not c.contains("/surf/"), "and neither can escape the directory", c)

	# A clean id keeps its plain readable name, which is what somebody looking in
	# the directory wants.
	_check(
		store.path_for(&"surf_beginner", 0, &"normal").contains(
			"/surf_beginner.0.normal.json"
		),
		"a clean id is left alone"
	)

	# Traversal and hidden files.
	var dots := store.path_for(&"..", 0, &"normal")
	_check(not dots.contains("/.."), "a `..` id cannot become a parent directory",
		dots)

	var tracks := {}
	for track in range(DotTimerTrack.COUNT):
		tracks[store.path_for(&"m", track, &"normal")] = true

	_check(
		tracks.size() == DotTimerTrack.COUNT,
		"and every track has its own file"
	)


func _record(player: StringName, time: float) -> DotTimerRecord:
	var record := DotTimerRecord.new()
	record.map_id = &"m"
	record.track = 0
	record.style_id = &"normal"
	record.player_id = player
	record.player_name = String(player)
	record.time = time
	return record


func _test_manager() -> void:
	print("the manager")

	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.store = DotTimerStoreMemory.new()
	manager.record_replays = true
	add_child(manager)

	manager.set_zones(_corridor())

	var styles := DotTimerStyle.defaults()
	styles[0].minimum_time = 0.0
	manager.set_styles(styles)

	manager.add_player(&"p1", "Player One")

	var accepted: Array[DotTimerRecord] = []
	var refused := PackedStringArray()

	manager.record_accepted.connect(
		func(record: DotTimerRecord, _previous: DotTimerRecord, _rank: int) -> void:
			accepted.append(record)
	)
	manager.record_refused.connect(
		func(_id: StringName, _run: DotTimerRun, reason: String) -> void:
			refused.append(reason)
	)

	_walk_manager(manager, &"p1", 10.0)

	_check(accepted.size() == 1, "a completed run is filed", str(refused))

	if accepted.size() == 1:
		_check_near(accepted[0].time, 9.2, 0.005, "with the run's time")
		_check(accepted[0].map_id == &"test_corridor", "and the map id")
		_check(accepted[0].tick_rate == 128, "and the tick rate it was set at")
		_check(
			accepted[0].zone_fingerprint != "",
			"and the fingerprint of the zones it was set against"
		)
		_check(accepted[0].points > 0.0, "and points", "%.2f" % accepted[0].points)

	var player := manager.player(&"p1")
	_check(player != null and player.last_replay != null, "and a replay was kept")

	if player != null and player.last_replay != null:
		_check(
			player.last_replay.frames.size() > 1000,
			"with a frame per tick",
			"%d" % player.last_replay.frames.size()
		)

	# An unranked style times and refuses, and says so.
	var unranked := DotTimerStyle.new()
	unranked.id = &"joke"
	unranked.ranked = false

	var list := manager.styles_in_order()
	list.append(unranked)
	manager.set_styles(list)
	manager.set_player_style(&"p1", &"joke")

	refused.clear()
	_walk_manager(manager, &"p1", 10.0)

	_check(refused.size() == 1, "an unranked style refuses the record")
	_check(
		refused.size() == 1 and refused[0].contains("not ranked"),
		"and says why",
		str(refused)
	)

	manager.remove_player(&"p1")
	_check(manager.player_count() == 0, "a player can be removed")

	manager.queue_free()


func _test_replay_files() -> void:
	print("")
	print("a kept replay reaches the disk")

	# [b]The half that had been missing.[/b] The recorder ran, the winner sat in
	# `last_replay`, and `replays_directory` was read by nothing — so a records server
	# lost every replay at exit and nothing anywhere failed. A check that the file
	# exists is the only thing that can tell the two apart.
	var directory := "user://test_replays"
	DotPaths.remove_tree(directory)

	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.store = DotTimerStoreMemory.new()
	manager.record_replays = true
	manager.replays_directory = directory
	add_child(manager)

	manager.set_zones(_corridor())

	var styles := DotTimerStyle.defaults()
	styles[0].minimum_time = 0.0
	manager.set_styles(styles)

	manager.add_player(&"p1", "Player One")

	var accepted: Array[DotTimerRecord] = []
	manager.record_accepted.connect(
		func(record: DotTimerRecord, _previous: DotTimerRecord, _rank: int) -> void:
			accepted.append(record)
	)

	_walk_manager(manager, &"p1", 10.0)

	_check(accepted.size() == 1, "a run is filed")

	if accepted.size() == 1:
		var path := manager.replay_path(accepted[0])
		_check(FileAccess.file_exists(path), "and its replay is on disk", path)

		var loaded := DotTimerReplay.load_from(path)
		_check(loaded.ok, "which loads back", str(loaded.error))

		if loaded.ok:
			var replay: DotTimerReplay = loaded.value
			var kept: DotTimerReplay = manager.player(&"p1").last_replay
			_check(
				kept != null and replay.frames.size() == kept.frames.size(),
				"with every frame that was recorded",
				"%d on disk" % replay.frames.size()
			)
			_check(
				replay.map_id == accepted[0].map_id,
				"and the map it was set on"
			)

	# A slower second run is not kept, so there is nothing to write: the file must
	# still be the record's replay rather than the run that lost to it.
	var before := FileAccess.get_modified_time(manager.replay_path(accepted[0])) \
		if accepted.size() == 1 else 0

	# The walk starts behind the start zone, so running it again is a second run.
	_walk_manager(manager, &"p1", 6.0)

	if accepted.size() >= 1:
		_check(
			FileAccess.get_modified_time(manager.replay_path(accepted[0])) == before,
			"a run the store did not keep does not overwrite the replay"
		)

	# Two ids that differ only where the sanitiser substitutes must not share a file.
	# This is the records-filename bug one directory over: substitution is
	# many-to-one, and without the hash suffix surf_kitsune2 and surf_kitsune3 became
	# one leaderboard.
	var a := _record(&"p1", 1.0)
	var b := _record(&"p1", 1.0)
	a.map_id = &"surf/one"
	b.map_id = &"surf:one"

	_check(
		manager.replay_path(a) != manager.replay_path(b),
		"two ids the sanitiser flattens still get two files",
		manager.replay_path(a)
	)
	_check(
		not manager.replay_path(a).contains(".."),
		"and a traversal in an id cannot leave the directory"
	)

	# Off means off: no directory, no files, and the run still counts.
	manager.replays_directory = ""
	_walk_manager(manager, &"p1", 20.0)

	var written := DirAccess.get_files_at(directory).size()
	_check(written == 1, "with no directory set nothing more is written",
		"%d file(s)" % written)

	manager.queue_free()


func _walk_manager(
	manager: DotTimerManager, id: StringName, speed: float
) -> void:
	var step := speed / float(manager.tick_rate)
	var x := -2.0

	while x <= 104.0:
		x += step
		manager.tick_player(
			id, Vector3(x, 0.0, 0.0), Vector3(speed, 0.0, 0.0), true, true
		)


func _test_tick_rate_configuration() -> void:
	print("the tick rate is configuration, not a constant")

	var config := DotTimerConfig.new()

	_check(config.validate().ok, "the default configuration is valid")
	_check(
		config.effective_tick_rate(0) == config.default_tick_rate,
		"with nothing to go on it falls back to the default",
		"%d" % config.effective_tick_rate(0)
	)
	_check(
		config.effective_tick_rate(64) == 64,
		"and takes the engine's rate when there is one — which on a dot-server is sv_tickrate"
	)

	config.tick_rate = 100
	_check(
		config.effective_tick_rate(64) == 100,
		"an explicit rate overrides the engine, for a client or a test"
	)

	config.tick_rate = -1
	_check(not config.validate().ok, "and a negative rate is refused")

	# The layering every DotConfig has, which is the whole reason this is a
	# DotConfig: an operator changes it in a file or on the command line without an
	# editor and without a rebuild.
	var layered := DotTimerConfig.new()

	# apply_dictionary returns the keys it CHANGED, not a DotResult — a layer that
	# matched nothing is not a failure, it is a layer that had nothing to say.
	var applied := layered.apply_dictionary({
		"tick_rate": 64, "record_replays": false, "records_directory": ""
	})

	_check(applied.size() == 3, "a dictionary layer applies three keys",
		str(applied))
	_check(layered.tick_rate == 64, "and moves the tick rate")
	_check(not layered.record_replays, "and the replay switch")
	_check(
		layered.unknown_keys.is_empty(),
		"with nothing left unrecognised",
		str(layered.unknown_keys)
	)

	# The manager half: changing the rate must abandon runs rather than reinterpret
	# the ticks already banked.
	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.store = DotTimerStoreMemory.new()
	add_child(manager)

	manager.set_zones(_corridor())
	manager.set_styles(DotTimerStyle.defaults())
	manager.add_player(&"p1", "One")

	var abandoned := [0]
	manager.player_stopped.connect(
		func(_id: StringName, _run: DotTimerRun, _reason: StringName) -> void:
			abandoned[0] += 1
	)

	# Get a run going.
	var x := -2.0
	for _i in range(400):
		x += 10.0 / 128.0
		manager.tick_player(&"p1", Vector3(x, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), true)

	_check(
		manager.run_for(&"p1").is_active(), "a run is in progress at 128 Hz"
	)

	_check(manager.set_tick_rate(64), "the rate can be changed")
	_check(manager.tick_rate == 64, "and moves")
	_check(
		abandoned[0] == 1,
		"and the run in progress is abandoned rather than reinterpreted",
		"%d" % abandoned[0]
	)
	_check(
		absf(manager.timer_for(&"p1").tick_interval() - 1.0 / 64.0) < 1e-9,
		"and every player's timer is rebound to it"
	)

	_check(not manager.set_tick_rate(64), "setting the same rate does nothing")
	_check(not manager.set_tick_rate(0), "and zero is refused")

	# The check that catches the one misconfiguration producing plausible wrong
	# times instead of an error.
	Engine.physics_ticks_per_second = 64
	_check(manager.tick_rate_matches_engine(), "the timer agrees with the engine")

	Engine.physics_ticks_per_second = 128
	_check(
		not manager.tick_rate_matches_engine(),
		"and disagreeing is detectable rather than silent"
	)

	_check(manager.adopt_engine_tick_rate(), "adopting the engine's rate works")
	_check(manager.tick_rate == 128, "and takes it")
	_check(manager.tick_rate_matches_engine(), "leaving them in agreement")

	# A record carries the rate it was set at, which is what lets a dispute be
	# settled afterwards.
	var run := DotTimerRun.make(0, &"normal", 1.0 / 64.0)
	run.begin(0.0)
	run.ticks = 640
	run.finish(0.0)

	var record := DotTimerRecord.from_run(run, &"m", &"p", "P")
	_check(record.tick_rate == 64, "and a record records it", "%d" % record.tick_rate)
	_check_near(record.time, 10.0, 0.001, "with the time that rate implies")

	manager.queue_free()


func _test_checkpoints_practice() -> void:
	print("practice checkpoints")

	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.store = DotTimerStoreMemory.new()
	add_child(manager)

	manager.set_zones(_corridor())

	var styles := DotTimerStyle.defaults()
	styles[0].minimum_time = 0.0
	styles[0].allow_checkpoints = true
	manager.set_styles(styles)

	manager.add_player(&"p1", "One")

	var checkpoints := manager.checkpoints_for(&"p1")
	_check(checkpoints != null, "a player gets a checkpoint set")

	if checkpoints == null:
		manager.queue_free()
		return

	_check(checkpoints.is_empty(), "which starts empty")
	_check(checkpoints.load_current() == null, "and restores nothing")

	checkpoints.save(Vector3(10.0, 0.0, 0.0), Vector3(5.0, 0.0, 0.0), 90.0)
	checkpoints.save(Vector3(20.0, 0.0, 0.0), Vector3.ZERO, 0.0, 0.0, true)

	_check(checkpoints.count() == 2, "two are saved")
	_check(
		checkpoints.peek().position.x == 20.0,
		"and the cursor is on the newest, which is what the key press meant"
	)

	var previous := checkpoints.previous()
	_check(previous.position.x == 10.0, "cycling back reaches the older one")
	_check_near(previous.yaw, 90.0, 0.0001, "with the view it was saved with")
	_check(checkpoints.next().position.x == 20.0, "and forward returns")

	# Grounded is restored, because on a surf map it decides which acceleration runs
	# on the very next tick.
	_check(checkpoints.peek().grounded, "and whether they were on the ground")

	# The cap drops the OLDEST, and the cursor moves with it.
	checkpoints.limit = 3
	for i in range(6):
		checkpoints.save(Vector3(float(100 + i), 0.0, 0.0), Vector3.ZERO)

	_check(checkpoints.count() == 3, "the set is capped", "%d" % checkpoints.count())
	_check(
		checkpoints.peek().position.x == 105.0,
		"keeping the newest, not the oldest"
	)

	# The taint. Saving is free; restoring is not.
	var x := -2.0
	for _i in range(400):
		x += 10.0 / 128.0
		manager.tick_player(&"p1", Vector3(x, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), true)

	var run := manager.run_for(&"p1")
	_check(run.is_active(), "a run is going")

	checkpoints.save(Vector3(x, 0.0, 0.0), Vector3.ZERO)
	_check(not run.used_checkpoints, "saving during a run does not taint it")

	checkpoints.load_current()
	_check(run.used_checkpoints, "but restoring one does")

	# And it is sticky: clearing the set must not clear the flag.
	checkpoints.clear()
	_check(checkpoints.is_empty(), "the set can be cleared")
	_check(
		run.used_checkpoints,
		"and clearing it does not launder the run"
	)

	# A style change does NOT take the set away. Practice mode is how somebody
	# learns a map, and confiscating their saved positions because they switched to
	# sideways would be confiscating the reason they switched. What the style
	# decides is what using one costs.
	var strict := DotTimerStyle.new()
	strict.id = &"strict"
	strict.allow_checkpoints = false

	var list := manager.styles_in_order()
	list.append(strict)
	manager.set_styles(list)

	checkpoints.save(Vector3(1.0, 0.0, 0.0), Vector3.ZERO)
	manager.set_player_style(&"p1", &"strict")

	_check(
		not checkpoints.is_empty(),
		"switching style keeps the saved checkpoints"
	)
	_check(checkpoints.enabled, "and practice mode is still available")

	# On a style that does not rank them, restoring one abandons the run rather
	# than timing four more minutes that can never be filed.
	var x2 := -2.0
	for _i in range(400):
		x2 += 10.0 / 128.0
		manager.tick_player(&"p1", Vector3(x2, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), true)

	_check(manager.run_for(&"p1").is_active(), "a run starts on the strict style")

	checkpoints.load_current()

	_check(
		not manager.run_for(&"p1").is_active(),
		"and restoring a checkpoint abandons it"
	)

	# The server's own switch is separate, and turns the feature off entirely.
	manager.allow_checkpoints = false
	checkpoints.enabled = false

	_check(
		not checkpoints.save(Vector3.ZERO, Vector3.ZERO).ok,
		"the server can turn practice mode off altogether"
	)

	manager.allow_checkpoints = true
	checkpoints.enabled = true

	# The round trip, so a set survives a map change or a reconnect.
	manager.set_player_style(&"p1", &"normal")
	checkpoints.save(Vector3(7.0, 8.0, 9.0), Vector3(1.0, 2.0, 3.0), 45.0, -10.0)

	var back := DotTimerCheckpoints.from_dictionary(checkpoints.to_dictionary())

	_check(back.count() == checkpoints.count(), "a set round-trips")
	_check(
		back.peek().position.is_equal_approx(Vector3(7.0, 8.0, 9.0)),
		"with its positions"
	)
	_check_near(back.peek().pitch, -10.0, 0.0001, "and its view")

	manager.queue_free()


# --- Replays ---------------------------------------------------------------

func _test_replay_round_trip() -> void:
	print("replays")

	var replay := DotTimerReplay.new()
	replay.map_id = &"test_corridor"
	replay.track = DotTimerTrack.of_bonus(2)
	replay.style_id = &"sideways"
	replay.player_name = "Player One"
	replay.tick_rate = 128
	replay.time = 12.345

	# A path with a curve in it, so the delta encoding is exercised rather than a
	# straight line of identical deltas.
	for i in range(2000):
		var t := float(i) * 0.01
		replay.append(
			Vector3(t * 3.0, sin(t) * 2.0, cos(t) * 2.0),
			wrapf(t * 40.0, -180.0, 180.0),
			sin(t) * 30.0,
			DotTimerReplay.FLAG_GROUNDED if i % 3 == 0 else 0
		)

	var bytes := replay.to_bytes()
	var parsed := DotTimerReplay.from_bytes(bytes)

	_check(parsed.ok, "a replay round-trips through bytes",
		parsed.error.message if not parsed.ok else "")

	if not parsed.ok:
		return

	var back: DotTimerReplay = parsed.value

	_check(back.frames.size() == replay.frames.size(), "with every frame")
	_check(back.map_id == replay.map_id, "and the map")
	_check(back.track == replay.track, "and the track")
	_check(back.style_id == replay.style_id, "and the style")
	_check(back.player_name == replay.player_name, "and the name")
	_check_near(back.time, replay.time, 0.001, "and the time")

	var worst := 0.0
	var worst_yaw := 0.0

	for i in range(replay.frames.size()):
		worst = maxf(
			worst, back.frames[i].position.distance_to(replay.frames[i].position)
		)
		worst_yaw = maxf(
			worst_yaw,
			absf(wrapf(back.frames[i].yaw - replay.frames[i].yaw, -180.0, 180.0))
		)

	_check(worst < 0.002, "within a millimetre of the original", "%.5f m" % worst)
	_check(worst_yaw < 0.06, "and a twentieth of a degree", "%.4f°" % worst_yaw)

	# The size claim from the class documentation. 2000 frames of curved motion.
	var per_frame := float(bytes.size()) / float(replay.frames.size())
	_check(
		per_frame < 12.0,
		"and costs under twelve bytes a frame",
		"%.1f bytes" % per_frame
	)

	# Refusals.
	_check(
		not DotTimerReplay.from_bytes(PackedByteArray([1, 2, 3])).ok,
		"a short buffer is refused"
	)

	var corrupt := bytes.duplicate()
	corrupt[0] = 0
	_check(
		not DotTimerReplay.from_bytes(corrupt).ok,
		"and one with the wrong magic"
	)

	# A hostile frame count must not be believed before allocating for it.
	var lying := replay.to_bytes()
	_check(
		DotTimerReplay.from_bytes(lying.slice(0, 40)).ok == false,
		"and a truncated file is refused rather than half-read"
	)


func _test_replay_playback() -> void:
	print("replay playback")

	var replay := DotTimerReplay.new()
	replay.tick_rate = 100

	for i in range(1000):
		replay.append(Vector3(float(i), 0.0, 0.0), 0.0, 0.0)

	var player := DotTimerReplayPlayer.new()
	var loaded := player.load_replay(replay)

	_check(loaded.ok, "a replay loads")
	_check_near(player.duration(), 10.0, 0.001, "and reports its duration")

	# Sampled at a time, not stepped per frame: the pose at 5 s is frame 500 whatever
	# the viewer's frame rate is.
	var middle := player.sample_at(5.0)
	_check(middle != null, "a pose can be sampled")
	_check_near(middle.position.x, 500.0, 0.001, "at the right frame")

	var between := player.sample_at(5.005)
	_check_near(
		between.position.x, 500.5, 0.001, "and interpolated between two"
	)

	# The wrapping test: a yaw going from 179 to -179 is two degrees, not 358.
	var wrapping := DotTimerReplay.new()
	wrapping.tick_rate = 100
	wrapping.append(Vector3.ZERO, 179.0, 0.0)
	wrapping.append(Vector3.ZERO, -179.0, 0.0)
	wrapping.append(Vector3.ZERO, -179.0, 0.0)

	var spinner := DotTimerReplayPlayer.new()
	spinner.load_replay(wrapping)

	var halfway := spinner.sample_at(0.005)
	_check(
		absf(wrapf(halfway.yaw - 180.0, -180.0, 180.0)) < 0.01,
		"a yaw crossing ±180 interpolates the short way round",
		"%.2f°" % halfway.yaw
	)

	player.play()
	player.advance(3.0)
	_check_near(player.time, 3.0, 0.001, "playback advances")
	_check_near(player.progress(), 0.3, 0.001, "and reports progress")

	player.speed = -1.0
	player.advance(1.0)
	_check_near(player.time, 2.0, 0.001, "and can run backwards")

	player.looping = true
	player.seek(9.9)
	player.speed = 1.0
	player.advance(0.5)
	_check(player.time < 1.0, "and loops at the end")


# --- Rules and points ------------------------------------------------------

func _test_rules() -> void:
	print("velocity rules")

	var fast := Vector3(30.0, -10.0, 40.0)
	var clamped := DotTimerRules.clamp_prespeed(fast, 25.0)

	_check_near(
		Vector2(clamped.x, clamped.z).length(), 25.0, 0.001,
		"prespeed caps the horizontal speed"
	)
	_check_near(
		clamped.y, -10.0, 0.0001,
		"and leaves the fall alone, or a player dropping in would hang in the air"
	)

	_check(
		DotTimerRules.clamp_prespeed(fast, 0.0) == fast,
		"a limit of zero does nothing"
	)
	_check(
		DotTimerRules.clamp_prespeed(Vector3(1.0, 0.0, 0.0), 25.0)
			== Vector3(1.0, 0.0, 0.0),
		"and a slow player is untouched"
	)

	var flat := DotTimerRules.clamp_prespeed_2d(Vector3(30.0, 40.0, 7.0), 25.0)
	_check_near(
		Vector2(flat.x, flat.y).length(), 25.0, 0.001,
		"the 2D form caps the XY plane instead"
	)

	var push_zone := DotTimerZone.make(DotTimerZone.Kind.PUSH)
	push_zone.direction = Vector3(0.0, 100.0, 0.0)

	var pushed := DotTimerRules.apply_push(Vector3.ZERO, push_zone, 1.0 / 128.0)
	_check_near(pushed.y, 100.0 / 128.0, 0.0001, "a push adds acceleration for a tick")

	_check(
		DotTimerRules.may_start(true, true, false),
		"a grounded living player may start"
	)
	_check(
		not DotTimerRules.may_start(false, true, false),
		"an airborne one may not, unless the style allows it"
	)
	_check(
		not DotTimerRules.may_start(true, false, true),
		"and a dead one never may"
	)


func _test_points() -> void:
	print("ranking points")

	var style := DotTimerStyle.new()

	var tier1 := style.points_for(60.0, 1, 60.0)
	var tier10 := style.points_for(60.0, 10, 60.0)

	_check(
		tier10 > tier1 * 20.0,
		"a tier 10 map is worth far more than twenty tier 1 maps' worth of one run",
		"%.1f vs %.1f" % [tier10, tier1]
	)

	var record := style.points_for(30.0, 5, 30.0)
	var double := style.points_for(60.0, 5, 30.0)

	_check(record > double, "the record scores more than twice its time")
	_check(
		double > record * 0.5,
		"but a slow completion is still worth well over half",
		"%.1f vs %.1f" % [double, record]
	)

	var far := style.points_for(3000.0, 5, 30.0)
	_check(far > 0.0, "and an appalling one is still worth something", "%.2f" % far)

	style.ranked = false
	_check(style.points_for(30.0, 5, 30.0) == 0.0, "an unranked style scores nothing")

	style.ranked = true
	style.points_multiplier = 2.0
	_check_near(
		style.points_for(30.0, 5, 30.0), record * 2.0, 0.001,
		"and the multiplier scales it"
	)

	_check_near(
		style.minimum_time_for(DotTimerTrack.MAIN), 3.5, 0.001,
		"the main-track floor is the long one"
	)
	_check_near(
		style.minimum_time_for(DotTimerTrack.of_bonus(1)), 0.5, 0.001,
		"and a bonus has its own"
	)


func _test_painter() -> void:
	print("drawing zones from inside the game")

	var set := DotTimerZoneSet.new()
	set.map_id = &"drawn"

	var painter := DotTimerZonePainter.on(set)
	painter.begin(DotTimerZone.Kind.START, DotTimerTrack.MAIN)

	var first := painter.mark(Vector3(0.0, 0.0, 0.0))
	_check(first.ok and first.value == null, "the first corner is taken")
	_check(painter.is_drawing(), "and the painter is mid-zone")

	var second := painter.mark(Vector3(4.0, 0.0, 4.0))
	_check(second.ok and second.value != null, "the second completes the zone")
	_check(not painter.is_drawing(), "and the painter is idle again")

	var zone: DotTimerZone = second.value

	# Both corners are marked at the player's feet, so without the added height every
	# zone drawn this way would be a flat sheet nothing ever enters. This is the
	# single most common mistake in hand-drawn zones.
	_check(
		zone.size().y >= DotTimerZonePainter.DEFAULT_HEIGHT,
		"with height added above the marked corners",
		"%.2f m" % zone.size().y
	)
	_check(
		zone.contains(Vector3(2.0, 1.0, 2.0)),
		"so a standing player is inside it"
	)

	painter.begin(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	painter.mark(Vector3(50.0, 0.0, 0.0))
	painter.mark(Vector3(54.0, 0.0, 4.0))

	_check(set.problems().is_empty(), "a start and an end make a valid track",
		", ".join(set.problems()))
	_check(set.playable_tracks() == PackedInt32Array([0]), "and it is playable")

	var undone := painter.undo()
	_check(undone.ok, "the last zone can be undone")
	_check(set.zones.size() == 1, "and is gone")

	# Ids are never reused, so a replay's crossing marks keep meaning what they meant.
	painter.begin(DotTimerZone.Kind.END, DotTimerTrack.MAIN)
	painter.mark(Vector3(60.0, 0.0, 0.0))
	var redrawn := painter.mark(Vector3(64.0, 0.0, 4.0))

	_check(
		(redrawn.value as DotTimerZone).id != (undone.value as DotTimerZone).id,
		"and a redrawn zone gets a new id rather than the deleted one's"
	)

	var spawn := painter.mark_point(Vector3(1.0, 0.0, 1.0), 90.0)
	_check(spawn.ok, "a spawn point can be marked")

	painter.mark_point(Vector3(2.0, 0.0, 2.0), 0.0)
	_check(
		set.of_kind(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN).size() == 1,
		"and re-marking it replaces rather than adds"
	)

	_check(
		not painter.begin(DotTimerZone.Kind.START, 99).ok,
		"an invalid track is refused"
	)


func _test_time_formatting() -> void:
	print("time formatting")

	_check(DotTimerRun.format_time(0.0) == "0:00.000", "zero")
	_check(DotTimerRun.format_time(9.2) == "0:09.200", "under a minute")
	_check(DotTimerRun.format_time(83.456) == "1:23.456", "over a minute")
	_check(DotTimerRun.format_time(3723.5) == "1:02:03.500", "over an hour")

	_check(
		DotTimerRun.format_time(-1.25, true) == "-0:01.250",
		"a negative split reads as ahead"
	)
	_check(
		DotTimerRun.format_time(1.25, true) == "+0:01.250",
		"and a positive one as behind"
	)

	# Three decimals, always: these leaderboards are decided by thousandths, and a
	# display that rounded to two would make ties out of runs that were not tied.
	_check(
		DotTimerRun.format_time(9.2001) != DotTimerRun.format_time(9.2011),
		"a millisecond is visible"
	)


func _test_replay_ceiling() -> void:
	print("replay ceiling")
	var recorder := DotTimerReplayRecorder.new()
	recorder.max_seconds = 0.5
	recorder.begin(&"bhop_cap", DotTimerTrack.MAIN, &"normal", "Ada", 128)
	for i in range(100):
		recorder.capture(Vector3(0.0, 0.0, float(i)), 0.0, 0.0, 0)
	_check(recorder.frame_count() == 64, "frames past max_seconds are not kept", str(recorder.frame_count()))
	_check(recorder.overflowed == 36, "and are counted as overflow", str(recorder.overflowed))
	var replay := recorder.finish(0.78)
	_check(replay != null and replay.frames.size() == 64, "a capped replay still finishes")

	var config := DotTimerConfig.new()
	config.max_replay_seconds = 10.0
	var manager := DotTimerManager.new()
	manager.config = config
	add_child(manager)
	manager.add_player(&"capped", "Capped")
	var player := manager.player(&"capped")
	_check(player != null and player.recorder != null and player.recorder.max_seconds == 10.0,
		"the config's ceiling reaches every recorder")
	manager.queue_free()
