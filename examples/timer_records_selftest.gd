extends Node

## The records half of dot-timer: the store contract against the memory and file stores,
## the points formulas and titles, and every rule and flow the manager runs around a
## finish — rescoring, sections, practice ranks, start rules, stage enforcement, the
## anti-skip zones, pauses, teleports, resuming a dropped run, auto-restart, and the
## file store actually reaching the disk.
##
## [codeblock]
## godot --headless --path . res://examples/timer_records_selftest.tscn
## [/codeblock]
##
## The SQL store runs the same contract in `timer_sql_live`, against real databases.

const Contract := preload("res://examples/timer_store_contract.gd")

const CHECKS := 180
const SECTIONS := 17

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	print("dot-timer records self-test")
	print("")

	await _test_contract_memory()
	await _test_contract_file()
	await _test_file_store_survives_a_restart()
	_test_points_formulas()
	_test_titles()
	_test_run_sections_and_snapshots()
	await _test_filing_and_rescoring()
	await _test_sections_are_filed()
	await _test_practice_rank()
	_test_start_rules()
	_test_stage_enforcement()
	_test_validator_and_checker()
	_test_pause_rules()
	_test_noclip_and_teleport()
	await _test_resume_after_a_drop()
	await _test_auto_restart_and_requests()
	await _test_manager_flushes_the_file_store()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	_finish()


# --- The contract ------------------------------------------------------------

func _test_contract_memory() -> void:
	_section("the store contract: memory")
	await Contract.new().run(DotTimerStoreMemory.new(), _check)
	_done()


func _scratch(name: String) -> String:
	var dir := "user://timer_records_selftest/%s" % name
	_rm_rf(dir)
	return dir


func _rm_rf(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		dir.remove(file)
	DirAccess.remove_absolute(path)


func _test_contract_file() -> void:
	_section("the store contract: file")
	var store := DotTimerStoreFile.at(_scratch("contract"))
	store.flush_batch = 1000
	await Contract.new().run(store, _check)
	_done()


func _test_file_store_survives_a_restart() -> void:
	_section("the file store survives a restart")
	var dir := _scratch("restart")
	var store := DotTimerStoreFile.at(dir)
	store.put(Contract.rec(&"alice", 30.0))
	store.put(Contract.rec(&"alice", 35.0))
	store.put(Contract.rec(&"bob", 9.0, &"normal", 0, 1))
	store.note_player(&"alice", "Alice", 1790000000, 12.0)
	store.put_map({"map": "surf_contract", "tier": 3})
	var flushed := store.flush()
	_check("everything pending is written", flushed.ok and not store.has_pending())

	var again := DotTimerStoreFile.at(dir)
	var best: DotTimerRecord = again.best_for(Contract.M, 0, &"normal", &"alice").value
	_check("a new store reads the board back", best != null and is_equal_approx(best.time, 30.0))
	_check("with its completion count", best != null and best.completions == 2)
	_check("and the section board, from its own file", int(again.count_on(Contract.M, 0, &"normal", 1).value) == 1)
	_check("and the players, maps and history", again.player_info(&"alice").value != null and again.map_info(Contract.M).value != null and (again.recent(10, {"records_only": false}).value as Array).size() == 1)
	_check("and a cross-board question reads every board", (again.records_of(&"alice").value as Array).size() == 1)
	_check("a board written before sections existed keeps its filename", store.path_for(Contract.M, 0, &"normal").ends_with("surf_contract.0.normal.json"))
	_done()


# --- Points ------------------------------------------------------------------

func _test_points_formulas() -> void:
	_section("points formulas")
	var points := DotTimerPoints.new()

	# CURVE is DotTimerStyle.points_for, restated: nothing already scored may move.
	var style := DotTimerStyle.new()
	_check("curve agrees with the style's own formula", is_equal_approx(points.points_for(40.0, 30.0, 5, 0, 1.0), style.points_for(40.0, 5, 30.0)))
	_check("the record scores more than a slower run", points.points_for(30.0, 30.0, 5, 0, 1.0) > points.points_for(40.0, 30.0, 5, 0, 1.0))

	points.formula = DotTimerPoints.Formula.TIERED
	var tier5 := points.points_for(60.0, 60.0, 5, 0, 1.0)
	_check("tiered: the record on tier 5 is 375 plus a fifteenth of its length", is_equal_approx(tier5, 50.0 * 5.0 * 1.5 + 60.0 / 15.0))
	_check("tiered: a bonus counts as a fraction of a tier-one map", is_equal_approx(points.points_for(60.0, 60.0, 5, 2, 1.0), (75.0 + 4.0) * 0.25))
	_check("tiered: the style multiplier applies", is_equal_approx(points.points_for(60.0, 60.0, 5, 0, 2.0), tier5 * 2.0))

	points.formula = DotTimerPoints.Formula.PLACEMENT
	var record := points.points_for(30.0, 30.0, 3, 0, 1.0, 1, 100)
	var second := points.points_for(31.0, 30.0, 3, 0, 1.0, 2, 100)
	_check("placement: a record is worth its tier floor plus the completion award", is_equal_approx(record, 750.0 + 100.0))
	_check("placement: second is worth 80% of the record's share", is_equal_approx(second, ceilf(750.0 * 0.8) + 100.0))
	_check("placement: past the top ten it is a slice of the board", DotTimerPoints.placement_points(3, 11, 100) > 0.0 and DotTimerPoints.placement_points(3, 11, 100) < ceilf(750.0 * 0.4))
	_check("placement: far down a board earns only the completion award", is_equal_approx(points.points_for(99.0, 30.0, 3, 0, 1.0, 400, 400), 100.0))
	_check("placement: the record grows with the board", DotTimerPoints.record_worth(6, 2000) > DotTimerPoints.record_worth(6, 10))
	_check("placement: a bonus is paid by its own ladder", is_equal_approx(points.points_for(9.0, 9.0, 8, 1, 1.0, 1, 5), 250.0))
	_check("any change re-scores a placement board", points.rescore_on_any_change())

	_check("a weighted total decays down the list, best first", is_equal_approx(DotTimerPoints.weighted_total([10.0, 100.0, 40.0], 0.5), 100.0 + 20.0 + 2.5))
	_check("and a limit keeps only the best", is_equal_approx(DotTimerPoints.weighted_total([10.0, 100.0, 40.0], 1.0, 2), 140.0))
	_check("formula names round-trip, and an unknown one is refused", DotTimerPoints.formula_from_name("placement") == DotTimerPoints.Formula.PLACEMENT and DotTimerPoints.formula_from_name("nonsense") < 0)
	_done()


func _test_titles() -> void:
	_section("rank titles")
	var titles := DotTimerRankTitles.defaults()
	_check("first is the record holder", str(titles.title_for(1, 500, 9000.0).get("title", "")) == "Record Holder")
	_check("the top ten come next", str(titles.title_for(7, 500, 5000.0).get("title", "")) == "Elite")
	_check("then a share of the board", str(titles.title_for(20, 500, 3000.0).get("title", "")) == "Expert")
	_check("then points", str(titles.title_for(400, 500, 50.0).get("title", "")) == "Regular")
	_check("and no points is unranked", str(titles.title_for(0, 500, 0.0).get("title", "")) == "Unranked")
	var custom := DotTimerRankTitles.from_array([{"title": "Big", "points": [1000, 0]}, {"title": "Small", "points": [1, 999]}])
	_check("a ladder from data is read top to bottom", str(custom.title_for(3, 10, 1500.0)["title"]) == "Big" and str(custom.title_for(3, 10, 10.0)["title"]) == "Small")
	_done()


# --- The run -----------------------------------------------------------------

func _test_run_sections_and_snapshots() -> void:
	_section("sections and snapshots")
	var run := DotTimerRun.make(0, &"normal", 0.01)
	run.begin(0.0)
	for i in range(100):
		run.advance(10.0)
	run.mark_stage(1)
	for i in range(150):
		run.advance(10.0)
	run.mark_stage(2)
	for i in range(50):
		run.advance(10.0)
	run.finish(0.0)
	_check("section 1 runs from the start to line 1", is_equal_approx(run.section_time(1, 3), 1.0))
	_check("section 2 from line 1 to line 2", is_equal_approx(run.section_time(2, 3), 1.5))
	_check("and the last from line 2 to the finish", is_equal_approx(run.section_time(3, 3), 0.5))
	var skipped := DotTimerRun.make(0, &"normal", 0.01)
	skipped.begin(0.0)
	for i in range(10):
		skipped.advance(1.0)
	skipped.mark_stage(2)
	_check("a section whose first line was skipped has no time", skipped.section_time(2, 3) < 0.0)

	var slow := DotTimerRun.make(0, &"slowmo", 0.01)
	slow.time_scale = 0.5
	slow.begin(0.0)
	for i in range(200):
		slow.advance(1.0)
	_check("a timescaled run counts its own time", is_equal_approx(slow.time(), 1.0))

	var snap := run.to_snapshot()
	var back := DotTimerRun.from_snapshot(JSON.parse_string(JSON.stringify(snap)))
	_check("a snapshot survives JSON and comes back paused", back != null and back.status == DotTimerRun.Status.PAUSED)
	_check("with its ticks and splits", back != null and back.ticks == run.ticks and is_equal_approx(back.split_time(2), run.split_time(2)))
	_check("and nonsense is not a snapshot", DotTimerRun.from_snapshot({"x": 1}) == null)
	_done()


# --- Filing ------------------------------------------------------------------

func _corridor() -> DotTimerZoneSet:
	var set := DotTimerZoneSet.new()
	set.map_id = &"test_corridor"
	set.meta["tier"] = 3
	set.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(Vector3(0.0, -2.0, -4.0), Vector3(4.0, 4.0, 4.0)))
	set.add(DotTimerZone.make(DotTimerZone.Kind.END).set_box(Vector3(96.0, -2.0, -4.0), Vector3(100.0, 4.0, 4.0)))
	var spawn := DotTimerZone.make(DotTimerZone.Kind.SPAWN)
	spawn.destination = Vector3(2.0, 0.0, 0.0)
	set.add(spawn)
	for i in range(1, 4):
		var stage := DotTimerZone.make(DotTimerZone.Kind.STAGE)
		stage.number = float(i)
		stage.set_box(Vector3(float(i) * 24.0, -2.0, -4.0), Vector3(float(i) * 24.0 + 2.0, 4.0, 4.0))
		set.add(stage)
	return set


func _manager(store: DotTimerStore = null) -> DotTimerManager:
	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.record_replays = false
	manager.store = store if store != null else DotTimerStoreMemory.new()
	add_child(manager)
	var styles := DotTimerStyle.defaults()
	for style in styles:
		style.minimum_time = 0.0
	manager.set_styles(styles)
	manager.set_zones(_corridor())
	return manager


func _walk(manager: DotTimerManager, id: StringName, speed: float, from_x: float = -2.0, to_x: float = 104.0) -> void:
	var step := speed / float(manager.tick_rate)
	var x := from_x
	while x <= to_x:
		x += step
		manager.tick_player(id, Vector3(x, 0.0, 0.0), Vector3(speed, 0.0, 0.0), true, true)


func _test_filing_and_rescoring() -> void:
	_section("filing, and re-scoring when the record moves")
	var manager := _manager()
	manager.add_player(&"a", "Alice")
	manager.add_player(&"b", "Bob")
	var results: Array[Dictionary] = []
	manager.run_filed.connect(func(result: Dictionary) -> void: results.append(result))

	_walk(manager, &"a", 10.0)
	await get_tree().process_frame
	_check("a first finish is a record", results.size() == 1 and bool(results[0]["world_record"]) and bool(results[0]["first"]))
	_check("ranked 1 of 1", results.size() == 1 and int(results[0]["rank"]) == 1 and int(results[0]["total"]) == 1)
	var alice_first := float(results[0]["points"]) if results.size() == 1 else 0.0
	_check("and worth points", alice_first > 0.0)

	_walk(manager, &"b", 12.0)
	await get_tree().process_frame
	_check("a faster run by somebody else takes the record", results.size() == 2 and bool(results[1]["world_record"]) and (results[1]["previous_record"] as DotTimerRecord).player_id == &"a")

	# The record moved, so alice's row was re-scored against the new one.
	var alice_now: DotTimerRecord = manager.store.best_for(&"test_corridor", 0, &"normal", &"a").value
	_check("and the old record holder's points were re-scored down", alice_now != null and alice_now.points < alice_first)
	var standing: Dictionary = manager.store.player_rank(&"b").value
	_check("the new holder leads the players", int(standing["rank"]) == 1 and float(standing["points"]) > 0.0)
	_check("with a title", str((results[1]["title"] as Dictionary).get("title", "")) != "")

	_walk(manager, &"a", 9.0)
	await get_tree().process_frame
	_check("a slower finish is filed as a completion, not an improvement", results.size() == 3 and not bool(results[2]["improved"]) and int(results[2]["completions"]) == 2)

	var progress: Dictionary = manager.store.progress_for(&"a", &"test_corridor", 0, &"normal").value
	_check("and both attempts were counted", int(progress["attempts"]) == 2 and int(progress["completions"]) == 2)

	var catalogue: Dictionary = manager.store.map_info(&"test_corridor").value
	_check("the map was catalogued with its stages and tier", catalogue != null and int(catalogue["stages"]) == 3 and int(catalogue["tier"]) == 3)

	var tiered := await manager.set_map_tier(6)
	var bob_after: DotTimerRecord = manager.store.best_for(&"test_corridor", 0, &"normal", &"b").value
	_check("an admin's tier re-scores the map", tiered.ok and manager.map_tier() == 6 and bob_after.points > float(results[1]["points"]))

	var profile: DotResult = await manager.profile(&"b")
	_check("a profile has the player's standing", profile.ok and int(profile.value["rank"]) == 1 and int(profile.value["record_holds"]) == 1 and int(profile.value["maps_done"]) == 1)
	var left: DotResult = await manager.maps_left(&"b")
	_check("and nothing left on a one-map server", left.ok and (left.value as Array).is_empty())
	var recent: DotResult = await manager.recent_records(5)
	_check("the latest records are bob's then alice's", recent.ok and (recent.value as Array).size() == 2 and ((recent.value[0] as Dictionary)["record"] as DotTimerRecord).player_id == &"b")
	manager.queue_free()
	_done()


func _test_sections_are_filed() -> void:
	_section("sections are filed as their own records")
	var manager := _manager()
	manager.add_player(&"a", "Alice")
	var sections: Array[Dictionary] = []
	manager.section_filed.connect(func(result: Dictionary) -> void: sections.append(result))
	_walk(manager, &"a", 10.0)
	await get_tree().process_frame
	_check("one per section, the last at the finish", sections.size() == 4)
	var total := 0.0
	for s in sections:
		total += (s["record"] as DotTimerRecord).time
	var whole: DotTimerRecord = manager.store.best_for(&"test_corridor", 0, &"normal", &"a").value
	_check("and the sections add up to the run", whole != null and absf(total - whole.time) < 0.001)
	var records: DotResult = await manager.section_records()
	_check("the section records list one per section", records.ok and (records.value as Array).size() == 4 and records.value[0] != null)
	_check("sections earn no points", sections.size() > 0 and is_equal_approx(float(sections[0]["points"]), 0.0))
	manager.queue_free()
	_done()


func _test_practice_rank() -> void:
	_section("a refused finish is told where it would have placed")
	var manager := _manager()
	manager.add_player(&"a", "Alice")
	manager.add_player(&"b", "Bob")
	_walk(manager, &"a", 10.0)
	await get_tree().process_frame
	var told: Array = []
	manager.practice_finished.connect(func(_id: StringName, _run: DotTimerRun, would: int, total: int, _why: String) -> void: told.append([would, total]))
	manager.timer_for(&"b").authoritative = true
	var unranked := DotTimerStyle.new()
	unranked.id = &"joke"
	unranked.ranked = false
	unranked.minimum_time = 0.0
	var list := manager.styles_in_order()
	list.append(unranked)
	manager.set_styles(list)
	manager.set_player_style(&"b", &"joke")
	_walk(manager, &"b", 12.0)
	await get_tree().process_frame
	_check("an unranked finish is told its would-be rank", told.size() == 1 and int(told[0][0]) == 1)
	manager.queue_free()
	_done()


# --- Rules -------------------------------------------------------------------

func _timer(style: DotTimerStyle = null) -> DotTimer:
	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(_corridor(), 128)
	timer.style = style if style != null else DotTimerStyle.new()
	timer.style.minimum_time = 0.0
	return timer


func _step(timer: DotTimer, sample: DotTimerSample, x: float, velocity: Vector3, grounded: bool = true) -> void:
	sample.position = Vector3(x, 0.0, 0.0)
	sample.velocity = velocity
	sample.grounded = grounded
	timer.tick(sample)


func _test_start_rules() -> void:
	_section("start rules")
	var style := DotTimerStyle.new()
	style.start_speed_cap = 8.0
	var timer := _timer(style)
	var reasons: Array = []
	timer.start_refused.connect(func(reason: String) -> void: reasons.append(reason))
	var sample := DotTimerSample.new()
	for i in range(80):
		_step(timer, sample, -1.0 + float(i) * 0.1, Vector3(12.0, 0.0, 0.0))
	_check("leaving the start too fast does not begin a run", not timer.run.is_active() and reasons.size() == 1 and String(reasons[0]).contains("Too fast"))

	var walker := _timer(style)
	var s2 := DotTimerSample.new()
	for i in range(80):
		_step(walker, s2, -1.0 + float(i) * 0.1, Vector3(6.0, 0.0, 0.0))
	_check("under the cap it does", walker.run.is_active())
	_check("and the start speed is kept", walker.run.is_active() and is_equal_approx(walker.run.start_speed, 6.0))

	var grounded := DotTimerStyle.new()
	grounded.start_ground_seconds = 0.5
	var hopper := _timer(grounded)
	# Air starts allowed, so it is the ground-time rule that refuses this and not the
	# older "no airborne start" one.
	hopper.style.allow_air_start = true
	var s3 := DotTimerSample.new()
	# Lands in the start for a few ticks, then leaves airborne: a hop through it.
	for i in range(30):
		_step(hopper, s3, 1.0 + float(i) * 0.05, Vector3(6.0, 0.0, 0.0), i < 25 and i > 20)
	for i in range(40):
		_step(hopper, s3, 2.5 + float(i) * 0.1, Vector3(6.0, 1.0, 0.0), false)
	_check("hopping straight through the start does not begin a run", not hopper.run.is_active())

	var patient := _timer(grounded)
	patient.style.allow_air_start = true
	var s4 := DotTimerSample.new()
	for i in range(100):
		_step(patient, s4, 1.0, Vector3.ZERO)
	for i in range(40):
		_step(patient, s4, 1.0 + float(i) * 0.1, Vector3(6.0, 0.0, 0.0), i < 20)
	_check("standing still first, then leaving, does", patient.run.is_active())

	var zone_cap := _timer()
	var start: DotTimerZone = zone_cap.zones.first_of_kind(DotTimerZone.Kind.START, 0)
	start.payload["prespeed"] = 3.0
	var s5 := DotTimerSample.new()
	for i in range(80):
		_step(zone_cap, s5, -1.0 + float(i) * 0.1, Vector3(5.0, 0.0, 0.0))
	_check("a start zone's own cap overrides the style's", not zone_cap.run.is_active())
	_done()


func _test_stage_enforcement() -> void:
	_section("every stage must be passed")
	var timer := _timer()
	var sample := DotTimerSample.new()
	# Walk to just before stage 2, then jump past stage 2 and on to the end.
	for i in range(500):
		_step(timer, sample, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	timer.expect_teleport()
	for i in range(300):
		_step(timer, sample, 60.0 + float(i) * 0.15, Vector3(12.8, 0.0, 0.0))
	_check("the run finishes", timer.runs_finished == 1)
	var verdict := timer.can_record(timer.run)
	_check("but is not filed: it missed stage 2", not verdict.ok and verdict.error.message.contains("stage 2"))
	timer.enforce_stages = false
	_check("unless the map allows other routes", timer.can_record(timer.run).ok)
	_done()


func _test_validator_and_checker() -> void:
	_section("validator and checker zones close a shortcut")
	var set := _corridor()
	var validator := DotTimerZone.make(DotTimerZone.Kind.VALIDATOR)
	validator.number = 1.0
	validator.set_box(Vector3(40.0, -2.0, 6.0), Vector3(42.0, 4.0, 10.0))
	set.add(validator)
	var checker := DotTimerZone.make(DotTimerZone.Kind.CHECKER)
	checker.number = 1.0
	checker.set_box(Vector3(60.0, -2.0, -4.0), Vector3(62.0, 4.0, 4.0))
	set.add(checker)

	var timer := DotTimer.new()
	timer.authoritative = true
	timer.bind(set, 128)
	timer.style = DotTimerStyle.new()
	timer.style.minimum_time = 0.0
	timer.enforce_stages = false
	var requested: Array = []
	timer.effect_requested.connect(func(zone: DotTimerZone) -> void: requested.append(zone.kind))
	var sample := DotTimerSample.new()
	for i in range(1060):
		_step(timer, sample, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	_check("a checker reached without its validator sends the player back", requested.has(DotTimerZone.Kind.CHECKER))
	_check("and the run cannot be filed", timer.runs_finished == 1 and not timer.can_record(timer.run).ok)

	var honest := DotTimer.new()
	honest.authoritative = true
	honest.bind(set, 128)
	honest.style = DotTimerStyle.new()
	honest.style.minimum_time = 0.0
	honest.enforce_stages = false
	var asked: Array = []
	honest.effect_requested.connect(func(zone: DotTimerZone) -> void: asked.append(zone.kind))
	var s2 := DotTimerSample.new()
	for i in range(420):
		_step(honest, s2, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	# A detour through the validator, off the line and back.
	s2.position = Vector3(41.0, 0.0, 8.0)
	honest.expect_teleport()
	honest.tick(s2)
	for i in range(640):
		_step(honest, s2, 41.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	_check("a player who passed the validator goes through", not asked.has(DotTimerZone.Kind.CHECKER) and honest.runs_finished == 1 and honest.can_record(honest.run).ok)
	_done()


func _test_pause_rules() -> void:
	_section("pausing has rules, and resuming puts you back")
	var timer := _timer()
	var sample := DotTimerSample.new()
	for i in range(200):
		_step(timer, sample, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	_check("a moving player cannot pause", not timer.pause_checked(sample).ok)
	sample.velocity = Vector3.ZERO
	sample.grounded = false
	_check("nor one in the air", not timer.pause_checked(sample).ok)
	sample.grounded = true
	var paused := timer.pause_checked(sample)
	_check("a still, grounded one can", paused.ok and timer.run.status == DotTimerRun.Status.PAUSED)
	var at := sample.position
	var resumed := timer.resume_checked()
	_check("and resuming hands back where they were", resumed.ok and (resumed.value["position"] as Vector3).is_equal_approx(at) and timer.run.is_running())

	# Out of the start, so the run begins, then back into it: the run keeps going (it
	# only starts on leaving), and a pause there would be a free restart.
	var in_start := _timer()
	var s2 := DotTimerSample.new()
	for i in range(100):
		_step(in_start, s2, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	for i in range(60):
		_step(in_start, s2, 8.0 - float(i) * 0.1, Vector3(-12.8, 0.0, 0.0))
	s2.velocity = Vector3.ZERO
	_check("nobody pauses in the start zone", in_start.run.is_active() and in_start.in_zone(DotTimerZone.Kind.START) and not in_start.pause_checked(s2).ok)
	_done()


func _test_noclip_and_teleport() -> void:
	_section("no clip and unexplained teleports end a run")
	var timer := _timer()
	var reasons: Array = []
	timer.run_stopped.connect(func(_run: DotTimerRun, reason: StringName) -> void: reasons.append(reason))
	var sample := DotTimerSample.new()
	for i in range(100):
		_step(timer, sample, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	sample.noclip = true
	_step(timer, sample, 8.0, Vector3(12.8, 0.0, 0.0))
	_check("no clip stops the run", reasons.has(DotTimer.REASON_NOCLIP))

	var jumpy := _timer()
	jumpy.teleport_stop_distance = 5.0
	var why: Array = []
	jumpy.run_stopped.connect(func(_run: DotTimerRun, reason: StringName) -> void: why.append(reason))
	var s2 := DotTimerSample.new()
	for i in range(100):
		_step(jumpy, s2, -2.0 + float(i) * 0.1, Vector3(12.8, 0.0, 0.0))
	jumpy.expect_teleport()
	_step(jumpy, s2, 20.0, Vector3(12.8, 0.0, 0.0))
	_check("an expected teleport does not", why.is_empty() and jumpy.run.is_active())
	_step(jumpy, s2, 20.1, Vector3(12.8, 0.0, 0.0))
	_step(jumpy, s2, 20.2, Vector3(12.8, 0.0, 0.0))
	_step(jumpy, s2, 50.0, Vector3(12.8, 0.0, 0.0))
	_check("an unexplained one does", why.has(DotTimer.REASON_TELEPORT))
	_done()


# --- Resume, restart ----------------------------------------------------------

func _test_resume_after_a_drop() -> void:
	_section("a dropped run is kept and given back")
	var store := DotTimerStoreMemory.new()
	var manager := _manager(store)
	manager.add_player(&"a", "Alice")
	var step := 10.0 / 128.0
	var x := -2.0
	while x < 50.0:
		x += step
		manager.tick_player(&"a", Vector3(x, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), true, true)
	var ticks_before := manager.run_for(&"a").ticks
	manager.remove_player(&"a")

	var offered: Array = []
	manager.resume_available.connect(func(_id: StringName, state: Dictionary) -> void: offered.append(state))
	manager.add_player(&"a", "Alice")
	await get_tree().process_frame
	_check("the returning player is offered their run", offered.size() == 1)
	var restored := manager.restore_player(&"a")
	_check("it comes back paused, with where they were", restored.ok and manager.run_for(&"a").status == DotTimerRun.Status.PAUSED and (restored.value["position"] as Vector3).x > 49.0)
	_check("with its ticks intact", manager.run_for(&"a").ticks == ticks_before)
	var resumed := manager.resume_player(&"a")
	var filed: Array = []
	manager.run_filed.connect(func(result: Dictionary) -> void: filed.append(result))
	while x <= 104.0:
		x += step
		manager.tick_player(&"a", Vector3(x, 0.0, 0.0), Vector3(10.0, 0.0, 0.0), true, true)
	await get_tree().process_frame
	_check("and finishes as one run", resumed.ok and filed.size() == 1 and absf((filed[0]["record"] as DotTimerRecord).time - 9.2) < 0.02)
	_check("marked as resumed", filed.size() == 1 and (filed[0]["record"] as DotTimerRecord).stats.has("resumed"))
	_check("and the saved run is gone", store.take_resume(&"a", &"test_corridor").value == null)
	manager.queue_free()
	_done()


func _test_auto_restart_and_requests() -> void:
	_section("auto-restart, restart and end")
	var manager := _manager()
	manager.add_player(&"a", "Alice")
	_walk(manager, &"a", 12.0)
	await get_tree().process_frame
	manager.set_auto_restart(&"a", true)
	var asked: Array = []
	manager.teleport_requested.connect(func(_id: StringName, zone: DotTimerZone, why: StringName) -> void: asked.append([why, zone]))
	_walk(manager, &"a", 6.0, -2.0, 104.0)
	_check("a run behind the player's best is stopped and they are sent back", asked.size() >= 1 and asked[0][0] == &"auto_restart" and asked[0][1] != null)

	asked.clear()
	var restart := manager.request_restart(&"a")
	_check("a restart asks for the spawn", restart.ok and asked.size() == 1 and asked[0][0] == &"restart")
	var end := manager.request_end(&"a")
	_check("and an end for the end zone", end.ok and asked.size() == 2 and (asked[1][1] as DotTimerZone).kind == DotTimerZone.Kind.END)
	var limit := await manager.suggest_time_limit()
	_check("one finisher is not enough to suggest a time limit", limit.ok and int(limit.value) == 0)
	manager.queue_free()
	_done()


func _test_manager_flushes_the_file_store() -> void:
	_section("the manager writes the file store to disk")
	var dir := _scratch("flush")
	var store := DotTimerStoreFile.at(dir)
	var manager := _manager(store)
	manager.flush_seconds = 0.5
	manager.add_player(&"a", "Alice")
	_walk(manager, &"a", 10.0)
	await get_tree().process_frame
	_check("a filed record is pending", store.has_pending())
	await get_tree().create_timer(0.7).timeout
	_check("and written within the interval", not store.has_pending() and FileAccess.file_exists(store.path_for(&"test_corridor", 0, &"normal")))
	store.note_player(&"b", "Bob", 1790000000)
	manager.queue_free()
	await get_tree().process_frame
	_check("and what is left is written when the manager leaves", not store.has_pending())
	_done()


# --- Plumbing ----------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print(title)


func _done() -> void:
	_completed += 1


func _check(what: String, passed: bool) -> void:
	if passed:
		_passed += 1
		print("  %-64s ok" % what)
		return
	_failed += 1
	print("  %-64s FAILED" % what)


func _finish() -> void:
	if not DotPlatform.is_headless():
		return
	await get_tree().process_frame
	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)
