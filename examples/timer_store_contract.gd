extends RefCounted

## What every [DotTimerStore] must do, as one script run against all of them (memory, file, and SQL through dot-sql).
## Usage: [code]await contract.run(store, _check)[/code] with [code]_check(what: String, passed: bool)[/code].

## How many checks [method run] makes, so a caller can count them in.
const CHECKS := 47

const M := &"surf_contract"

var _check: Callable


static func rec(player: StringName, time: float, style: StringName = &"normal", track: int = 0, stage: int = 0, map_id: StringName = M) -> DotTimerRecord:
	var r := DotTimerRecord.new()
	r.map_id = map_id
	r.track = track
	r.style_id = style
	r.stage = stage
	r.player_id = player
	r.player_name = String(player).capitalize()
	r.time = time
	r.splits = {"1": time * 0.4}
	r.stats = {"jumps": 12}
	r.set_at = 1790000000 + int(time * 10.0)
	r.start_speed = 7.5
	return r


func run(store: DotTimerStore, check: Callable) -> void:
	_check = check

	var first: DotResult = await store.put(rec(&"alice", 30.0))
	_c("a first finish is filed", first.ok and bool(first.value["improved"]))
	_c("with no previous best and no previous record", first.ok and first.value["previous"] == null and first.value["previous_record"] == null)
	_c("as completion 1", first.ok and int(first.value["completions"]) == 1)

	var slower: DotResult = await store.put(rec(&"alice", 35.0))
	_c("a slower finish is not an improvement", slower.ok and not bool(slower.value["improved"]))
	_c("and reports the best it did not beat", slower.ok and slower.value["previous"] is DotTimerRecord and is_equal_approx((slower.value["previous"] as DotTimerRecord).time, 30.0))
	_c("but still counts: completion 2", slower.ok and int(slower.value["completions"]) == 2)

	var best: DotResult = await store.best_for(M, 0, &"normal", &"alice")
	_c("the best is still the faster run", best.ok and best.value is DotTimerRecord and is_equal_approx((best.value as DotTimerRecord).time, 30.0))
	_c("and carries the completion count", best.ok and best.value is DotTimerRecord and (best.value as DotTimerRecord).completions == 2)
	_c("and its fields round-trip", best.ok and best.value is DotTimerRecord and is_equal_approx((best.value as DotTimerRecord).start_speed, 7.5) and int((best.value as DotTimerRecord).stats.get("jumps", 0)) == 12)

	var faster: DotResult = await store.put(rec(&"alice", 25.0))
	_c("a faster finish replaces it", faster.ok and bool(faster.value["improved"]) and int(faster.value["completions"]) == 3)
	_c("and names the previous record (their own)", faster.ok and faster.value["previous_record"] is DotTimerRecord and (faster.value["previous_record"] as DotTimerRecord).player_id == &"alice")

	await store.put(rec(&"bob", 27.0))
	await store.put(rec(&"carol", 40.0))
	await store.put(rec(&"dave", 27.0))

	var top: DotResult = await store.top(M, 0, &"normal", 10)
	var order := []
	for r in (top.value as Array) if top.ok else []:
		order.append(String((r as DotTimerRecord).player_id))
	_c("the board is fastest first", top.ok and order.size() == 4 and order[0] == "alice" and order[3] == "carol")
	var page: DotResult = await store.top(M, 0, &"normal", 2, 2)
	_c("and pages", page.ok and (page.value as Array).size() == 2 and (page.value[1] as DotTimerRecord).player_id == &"carol")

	var rank_bob: DotResult = await store.rank_of(M, 0, &"normal", &"bob")
	var rank_dave: DotResult = await store.rank_of(M, 0, &"normal", &"dave")
	var rank_carol: DotResult = await store.rank_of(M, 0, &"normal", &"carol")
	_c("a tie shares a rank", rank_bob.ok and rank_dave.ok and int(rank_bob.value) == 2 and int(rank_dave.value) == 2)
	_c("and the next rank skips past it", rank_carol.ok and int(rank_carol.value) == 4)
	var nobody: DotResult = await store.rank_of(M, 0, &"normal", &"nobody")
	_c("a player with no time has rank 0", nobody.ok and int(nobody.value) == 0)
	var would: DotResult = await store.rank_for_time(M, 0, &"normal", 26.0)
	_c("a time would rank one past everybody faster", would.ok and int(would.value) == 2)
	var counted: DotResult = await store.count_on(M, 0, &"normal")
	_c("the board counts its players", counted.ok and int(counted.value) == 4)

	await store.put(rec(&"bob", 9.5, &"normal", 0, 2))
	var section_count: DotResult = await store.count_on(M, 0, &"normal", 2)
	var whole_count: DotResult = await store.count_on(M, 0, &"normal")
	_c("a section is its own board", section_count.ok and int(section_count.value) == 1 and int(whole_count.value) == 4)
	await store.put(rec(&"alice", 50.0, &"sideways"))
	var other_style: DotResult = await store.count_on(M, 0, &"sideways")
	_c("and so is another style", other_style.ok and int(other_style.value) == 1)
	await store.put(rec(&"alice", 12.0, &"normal", 1))

	var scored := [rec(&"alice", 25.0), rec(&"bob", 27.0), rec(&"alice", 12.0, &"normal", 1), rec(&"alice", 50.0, &"sideways")]
	scored[0].points = 100.0
	scored[1].points = 90.0
	scored[2].points = 40.0
	scored[3].points = 60.0
	var set_res: DotResult = await store.set_points(scored)
	_c("points can be rewritten", set_res.ok)
	var refreshed: DotResult = await store.refresh_player_points(["alice", "bob"], 0.5)
	_c("and totals recomputed", refreshed.ok)
	var alice_rank: DotResult = await store.player_rank(&"alice")
	# alice: 100, 60, 40 at 0.5 decay = 100 + 30 + 10 = 140. The section's points do not
	# count; only whole runs do.
	_c("as a decayed sum, best first", alice_rank.ok and is_equal_approx(float(alice_rank.value["points"]), 140.0))
	_c("and ranked", alice_rank.ok and int(alice_rank.value["rank"]) == 1 and int(alice_rank.value["total"]) == 2)
	var players: DotResult = await store.top_players(10)
	_c("the players list is by points", players.ok and (players.value as Array).size() == 2 and str(players.value[0]["player"]) == "alice" and str(players.value[1]["player"]) == "bob")

	var mine: DotResult = await store.records_of(&"alice")
	_c("a player's records are every whole-run board they are on", mine.ok and (mine.value as Array).size() == 3)
	var mine_normal: DotResult = await store.records_of(&"alice", {"style": "normal", "track": 0})
	_c("and filter", mine_normal.ok and (mine_normal.value as Array).size() == 1)
	var holds: DotResult = await store.record_count(&"alice")
	_c("alice holds three records", holds.ok and int(holds.value) == 3)
	var bob_holds: DotResult = await store.record_count(&"bob")
	_c("bob holds none on whole runs", bob_holds.ok and int(bob_holds.value) == 0)
	var on_map: DotResult = await store.records_on_map(M)
	_c("a map's records include its sections", on_map.ok and (on_map.value as Array).size() == 7)

	var latest: DotResult = await store.recent(10)
	var first_latest: Dictionary = latest.value[0] if latest.ok and not (latest.value as Array).is_empty() else {}
	_c("the latest records are newest first and only records", latest.ok and not first_latest.is_empty() and bool(first_latest["was_record"]) and (first_latest["record"] as DotTimerRecord).player_id == &"alice")
	var everything: DotResult = await store.recent(50, {"records_only": false})
	_c("every improvement is in the history, sections excluded by default", everything.ok and (everything.value as Array).size() == 7)

	await store.note_player(&"erin", "Erin", 1790000000)
	await store.note_player(&"erin", "Erin B", 1790000100, 30.0)
	await store.note_player(&"erin", "", 1790000200, 15.5)
	var erin: DotResult = await store.player_info(&"erin")
	_c("a player's row keeps their latest name", erin.ok and erin.value is Dictionary and str(erin.value["name"]) == "Erin B")
	_c("and adds up their play time", erin.ok and erin.value is Dictionary and is_equal_approx(float(erin.value["playtime"]), 45.5) and int(erin.value["last_seen"]) == 1790000200 and int(erin.value["first_seen"]) == 1790000000)

	await store.put_map({"map": String(M), "tier": 4, "stages": 3, "mapper": "someone", "tier_source": "admin"})
	await store.put_map({"map": String(M), "bonuses": 1})
	var info: DotResult = await store.map_info(M)
	_c("a map's info merges and keeps what it was not told", info.ok and info.value is Dictionary and int(info.value["tier"]) == 4 and int(info.value["bonuses"]) == 1 and str(info.value.get("tier_source", "")) == "admin")
	var listed: DotResult = await store.maps()
	_c("and the catalogue lists it", listed.ok and (listed.value as Array).size() == 1)

	await store.note_progress(&"erin", M, 0, &"normal", 1, 20.0, false)
	await store.note_progress(&"erin", M, 0, &"normal", 1, 31.0, true)
	await store.note_progress(&"erin", M, 0, &"normal", 1, 29.0, true)
	var progress: DotResult = await store.progress_for(&"erin", M, 0, &"normal")
	_c("progress counts attempts and finishes", progress.ok and progress.value is Dictionary and int(progress.value["attempts"]) == 3 and int(progress.value["completions"]) == 2)
	_c("and fixes the time it took to the first finish", progress.ok and progress.value is Dictionary and is_equal_approx(float(progress.value["time_to_first"]), 51.0) and is_equal_approx(float(progress.value["time_spent"]), 80.0))

	await store.save_resume(&"erin", M, {"ticks": 500, "tick_interval": 0.0078125})
	var taken: DotResult = await store.take_resume(&"erin", M)
	var again: DotResult = await store.take_resume(&"erin", M)
	_c("a saved run comes back once", taken.ok and taken.value is Dictionary and int(taken.value["ticks"]) == 500 and again.ok and again.value == null)

	await store.best_for(M, 0, &"normal", &"bob")
	var peeked: Variant = store.peek_best(M, 0, &"normal", &"bob")
	_c("a best already read can be peeked without waiting", peeked is DotTimerRecord and is_equal_approx((peeked as DotTimerRecord).time, 27.0))

	var removed: DotResult = await store.remove(M, 0, &"normal", &"carol")
	var after_remove: DotResult = await store.count_on(M, 0, &"normal")
	_c("a record can be removed", removed.ok and bool(removed.value) and after_remove.ok and int(after_remove.value) == 3)
	var removed_again: DotResult = await store.remove(M, 0, &"normal", &"carol")
	_c("and removing it twice says so", removed_again.ok and not bool(removed_again.value))
	var wiped_board: DotResult = await store.wipe_board(M, 0, &"normal")
	var whole_left: DotResult = await store.count_on(M, 0, &"normal")
	var section_left: DotResult = await store.count_on(M, 0, &"normal", 2)
	_c("a board wipe takes its sections with it", wiped_board.ok and int(wiped_board.value) == 4 and int(whole_left.value) == 0 and int(section_left.value) == 0)
	var wiped_player: DotResult = await store.wipe_player(&"alice")
	var alice_left: DotResult = await store.records_of(&"alice", {"stage": -1})
	_c("a player wipe takes everything of theirs", wiped_player.ok and alice_left.ok and (alice_left.value as Array).is_empty())
	var wiped_map: DotResult = await store.wipe_map(M)
	var map_left: DotResult = await store.records_on_map(M)
	var map_gone: DotResult = await store.map_info(M)
	_c("a map wipe empties the map and forgets it", wiped_map.ok and map_left.ok and (map_left.value as Array).is_empty() and map_gone.ok and map_gone.value == null)

	# A time with every digit: a gateway that serialised floats to fifteen digits stored a
	# slightly different time than it cached, and the player ranked behind their own row.
	var precise := rec(&"hal", 25.123456789012345, &"normal", 0, 0, &"precise_map")
	await store.put(precise)
	var precise_rank: DotResult = await store.rank_of(&"precise_map", 0, &"normal", &"hal")
	var precise_best: DotResult = await store.best_for(&"precise_map", 0, &"normal", &"hal")
	_c("a time keeps every digit, and ranks as itself right after filing", precise_rank.ok and int(precise_rank.value) == 1 and precise_best.ok and precise_best.value is DotTimerRecord and (precise_best.value as DotTimerRecord).time == 25.123456789012345)
	await store.wipe_map(&"precise_map")

	# The catalogue lists maps by id as text (SQL's ORDER BY); Godot orders StringNames by interning, so a memory store's sort() listed differently.
	# Random lowercase a-z ids filed out of order, so no order passes by accident and every collation agrees.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261011
	var filed: Array[String] = []
	while filed.size() < 20:
		var id := "order_"
		for _i in range(6):
			id += char(97 + rng.randi() % 26)
		if not filed.has(id):
			filed.append(id)
			await store.put_map({"map": id, "tier": 1})
	var catalogue: DotResult = await store.maps()
	var in_order: Array[String] = []
	if catalogue.ok:
		for row in (catalogue.value as Array):
			if str(row["map"]).begins_with("order_"):
				in_order.append(str(row["map"]))
	var by_text := filed.duplicate()
	by_text.sort()
	_c("the catalogue lists maps by id as text", in_order == by_text)
	for id in filed:
		await store.wipe_map(StringName(id))


func _c(what: String, passed: bool) -> void:
	_check.call(what, passed)
