extends Node

## Counters, check helpers and the replay sections of timer_selftest.gd, split out to keep that file under the size gate.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


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


## A straight corridor along +X: a start box (x in [0, 4]) and a finish box (x in [96, 100]), with stages between.
## The timed distance is exactly 92 metres, so every expected time is arithmetic, not a measurement.
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


func _record(player: StringName, time: float) -> DotTimerRecord:
	var record := DotTimerRecord.new()
	record.map_id = &"m"
	record.track = 0
	record.style_id = &"normal"
	record.player_id = player
	record.player_name = String(player)
	record.time = time
	return record


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


## Stands [param id] still past the end for [param ticks] ticks: a replay's run-out.
func _idle_manager(manager: DotTimerManager, id: StringName, ticks: int) -> void:
	for _i in range(ticks):
		manager.tick_player(id, Vector3(104.0, 0.0, 0.0), Vector3.ZERO, true, true)


func _check_replay_on_disk(manager: DotTimerManager, path: String, record: DotTimerRecord) -> void:
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
			replay.map_id == record.map_id,
			"and the map it was set on"
		)
		_check(replay.start_frame > 0 and replay.run_end_frame() < replay.frames.size() - 100,
			"with the run-up before the start and the run-out after the finish",
			"start %d, end %d, %d frames" % [replay.start_frame, replay.run_end_frame(), replay.frames.size()])
		_check(absf((replay.run_end_seconds() - replay.run_start_seconds()) - replay.time) < 0.05,
			"and the run between them is the run's own time", "%.3f against %.3f" % [replay.run_end_seconds() - replay.run_start_seconds(), replay.time])


func _check_replay_names(manager: DotTimerManager) -> void:
	# Ids differing only where the sanitiser substitutes must not share a file: without the hash suffix surf_kitsune2 and surf_kitsune3 became one leaderboard.
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


func _test_replay_files() -> void:
	print("")
	_section("a kept replay reaches the disk")

	# The half that was missing: the recorder ran and `replays_directory` was read by nothing, so replays were lost at exit. Only a file-exists check tells.
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

	# The replay keeps a second of run-out after the finish, and is written when that ends:
	# not at the finish, which would leave the file without it.
	if accepted.size() == 1:
		_check(not FileAccess.file_exists(manager.replay_path(accepted[0])) and manager.player(&"p1").recorder.is_trailing(),
			"the replay waits for its run-out before it is written")
	_idle_manager(manager, &"p1", 140)

	if accepted.size() == 1:
		var path := manager.replay_path(accepted[0])
		_check(FileAccess.file_exists(path), "and its replay is on disk", path)

		_check_replay_on_disk(manager, path, accepted[0])

	# A slower second run is not kept, so there is nothing to write: the file must
	# still be the record's replay rather than the run that lost to it.
	var before := FileAccess.get_modified_time(manager.replay_path(accepted[0])) \
		if accepted.size() == 1 else 0

	# The walk starts behind the start zone, so running it again is a second run.
	_walk_manager(manager, &"p1", 6.0)
	_idle_manager(manager, &"p1", 140)

	if accepted.size() >= 1:
		_check(
			FileAccess.get_modified_time(manager.replay_path(accepted[0])) == before,
			"a run the store did not keep does not overwrite the replay"
		)

	_check_replay_names(manager)

	# Off means off: no directory, no files, and the run still counts.
	manager.replays_directory = ""
	_walk_manager(manager, &"p1", 20.0)

	var written := DirAccess.get_files_at(directory).size()
	_check(written == 1, "with no directory set nothing more is written",
		"%d file(s)" % written)

	manager.queue_free()
	_done()


func _test_replay_round_trip() -> void:
	_section("replays")

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

	_check_replay_refusals(bytes, replay)
	_done()


func _check_replay_refusals(bytes: PackedByteArray, replay: DotTimerReplay) -> void:
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
	_section("replay playback")

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
	_done()



## Teleports, the declared flags and the buttons (format 2): recorded, kept through bytes,
## and honoured by playback.
func _test_replay_flags() -> void:
	_section("replay flags: teleport, ducked, jumped, buttons")

	var r := DotTimerReplay.new()
	r.tick_rate = 100
	r.append(Vector3(0, 0, 0), 0.0, 0.0, DotTimerReplay.FLAG_DUCKED, 5)
	r.append(Vector3(0.1, 0, 0), 0.0, 0.0, DotTimerReplay.FLAG_JUMPED, 0)
	r.append(Vector3(30.0, 0, 0), 0.0, 0.0, DotTimerReplay.FLAG_TELEPORT, 0)
	r.append(Vector3(30.1, 0, 0), 0.0, 0.0, 0, 0)
	var back := DotTimerReplay.from_bytes(r.to_bytes())
	var got: DotTimerReplay = back.value if back.ok else null
	_check(got != null and got.frames[0].flags & DotTimerReplay.FLAG_DUCKED and got.frames[0].buttons == 5
		and got.frames[1].flags & DotTimerReplay.FLAG_JUMPED and got.frames[2].flags & DotTimerReplay.FLAG_TELEPORT,
		"ducked, jumped, a teleport and the buttons survive the bytes")
	_check(got != null and got.frames[2].position.is_equal_approx(Vector3(30.0, 0, 0)) and got.frames[3].buttons == 0,
		"and the teleport lands where it was, written whole")

	var player := DotTimerReplayPlayer.new()
	var _loaded := player.load_replay(r)
	var mid := player.sample_at(1.5 / 100.0)
	_check(mid != null and mid.position.is_equal_approx(Vector3(0.1, 0, 0)), "playback does not blend across a teleport",
		str(mid.position) if mid != null else "null")
	_check(is_zero_approx(player.speed_at(1.0 / 100.0)) and is_equal_approx(player.speed_at(0.0), 10.0),
		"and no speed is derived across one, where it is across a step", "%.2f / %.2f" % [player.speed_at(1.0 / 100.0), player.speed_at(0.0)])

	var recorder := DotTimerReplayRecorder.new()
	recorder.pre_roll_seconds = 0.0
	recorder.begin(&"m", 0, &"normal", "p", 100)
	recorder.feed(Vector3(0, 0, 0), 0.0, 0.0)
	recorder.feed(Vector3(0.1, 0, 0), 0.0, 0.0)
	recorder.feed(Vector3(20.0, 0, 0), 0.0, 0.0)
	var made := recorder.finish(0.03)
	_check(made != null and made.frames[2].flags & DotTimerReplay.FLAG_TELEPORT and not (made.frames[1].flags & DotTimerReplay.FLAG_TELEPORT),
		"the recorder marks a move too far for a tick as a teleport by itself")

	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.store = DotTimerStoreMemory.new()
	manager.record_replays = true
	add_child(manager)
	manager.set_zones(_corridor())
	manager.add_player(&"f1", "Flags")
	var step := 10.0 / 128.0
	var x := -2.0
	var i := 0
	while x <= 104.0:
		x += step
		i += 1
		var flags := DotTimerReplay.FLAG_DUCKED if i % 2 == 0 else 0
		manager.tick_player(&"f1", Vector3(x, 0.0, 0.0), Vector3(10.0, 0, 0), true, true, 0.0, 0.0, 3, flags)
	var last: DotTimerReplay = manager.player(&"f1").last_replay
	var ducked := 0
	var pressed := 0
	if last != null:
		for frame in last.frames:
			ducked += 1 if frame.flags & DotTimerReplay.FLAG_DUCKED else 0
			pressed += 1 if frame.buttons == 3 else 0
	_check(last != null and ducked > 0 and pressed == last.frames.size(), "the manager records the caller's flags and buttons",
		"%d ducked, %d with buttons of %d" % [ducked, pressed, last.frames.size() if last != null else 0])

	_check_v1_replay_reads()

	manager.queue_free()
	_done()


func _check_v1_replay_reads() -> void:
	# A version-1 file (no start/end, no buttons byte) still reads.
	var v1 := StreamPeerBuffer.new()
	v1.big_endian = false
	v1.put_u32(DotTimerReplay.MAGIC)
	v1.put_u8(1)
	v1.put_u8(0)
	v1.put_u16(128)
	v1.put_float(1.0)
	v1.put_u32(0)
	for text in ["m", "normal", "p"]:
		v1.put_u8(text.length())
		v1.put_data(text.to_utf8_buffer())
	v1.put_u32(1)
	v1.put_u8(DotTimerReplay.FLAG_KEYFRAME)
	v1.put_32(1000)
	v1.put_32(0)
	v1.put_32(0)
	v1.put_16(0)
	v1.put_16(0)
	var old := DotTimerReplay.from_bytes(v1.data_array)
	_check(old.ok and (old.value as DotTimerReplay).frames.size() == 1 and (old.value as DotTimerReplay).start_frame == 0,
		"and a version-1 replay still reads", str(old.error) if not old.ok else "")


func _test_replay_ceiling() -> void:
	_section("replay ceiling")
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
	_done()
