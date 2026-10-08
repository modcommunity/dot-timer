extends Node

## The SQL store against a real database, through dot-sql's gateway.
##
## The same contract the memory and file stores pass (`timer_store_contract.gd`), then
## what only a shared database can show: two servers writing one board, and the cache.
## Run by dot-sql's runner, once per dialect:
##
## [codeblock]
## ../dot-sql/tools/test_live.sh . res://examples/timer_sql_live.tscn
## [/codeblock]

const Contract := preload("res://examples/timer_store_contract.gd")

const CHECKS := Contract.CHECKS + 12

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)

	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var token_file := OS.get_environment("DOT_SQL_TOKEN_FILE")
	if dialect < 0 or token_file == "":
		print("set DOT_SQL_URL, DOT_SQL_DIALECT and DOT_SQL_TOKEN_FILE; see dot-sql/tools/test_live.sh")
		get_tree().quit(2)
		return
	print("dot-timer live: %s" % DotSqlDialect.name_of(dialect))

	var a := await _store("dot_tlive_")
	await _drop(a)
	a = await _store("dot_tlive_")
	if a == null:
		get_tree().quit(1)
		return

	await Contract.new().run(a, _check)

	# --- two servers, one board ------------------------------------------------
	var b := await _store("dot_tlive_")
	await a.put(Contract.rec(&"zed", 40.0))
	await b.best_for(Contract.M, 0, &"normal", &"zed")   # b caches zed at 40
	await a.put(Contract.rec(&"zed", 30.0))               # a improves to 30
	var late: DotResult = await b.put(Contract.rec(&"zed", 35.0))  # b files 35, believing 40
	var truth: DotResult = await a.best_for(Contract.M, 0, &"normal", &"zed")
	_check("a slower run filed by a stale server never overwrites a faster one", late.ok and truth.ok and truth.value is DotTimerRecord and is_equal_approx((truth.value as DotTimerRecord).time, 30.0))
	var count_res: DotResult = await a.count_on(Contract.M, 0, &"normal")
	_check("and the board still has one row for the player", count_res.ok and int(count_res.value) == 1)

	# --- the cache ---------------------------------------------------------------
	var c := await _store("dot_tlive_")
	c.cache_seconds = 30.0
	await c.top(Contract.M, 0, &"normal", 10)
	var before := c.queries
	await c.top(Contract.M, 0, &"normal", 10)
	await c.top(Contract.M, 0, &"normal", 5)
	_check("a board read twice is read from the database once", c.queries == before and c.cache_hits >= 2)
	await c.put(Contract.rec(&"yan", 20.0))
	var after_write: DotResult = await c.top(Contract.M, 0, &"normal", 1)
	_check("this server's own write is on the board at once", after_write.ok and (after_write.value[0] as DotTimerRecord).player_id == &"yan")
	var peeked: Variant = c.peek_top(Contract.M, 0, &"normal", 1)
	_check("and a HUD can peek it without waiting", peeked is Array and ((peeked as Array)[0] as DotTimerRecord).player_id == &"yan")
	var cold: Variant = c.peek_top(&"never_read", 0, &"normal", 1)
	_check("a board nobody has read peeks as unknown, not as empty", cold == null)
	await get_tree().create_timer(0.3).timeout
	var warmed: Variant = c.peek_top(&"never_read", 0, &"normal", 1)
	_check("and is fetched in the background for the next peek", warmed is Array and (warmed as Array).is_empty())
	c.cache_seconds = 0.0
	var q := c.queries
	await c.top(Contract.M, 0, &"normal", 10)
	await c.top(Contract.M, 0, &"normal", 10)
	_check("with the cache off every read goes to the database", c.queries == q + 2)

	# --- a manager on SQL ----------------------------------------------------------
	var manager := DotTimerManager.new()
	manager.authoritative = true
	manager.tick_rate = 128
	manager.record_replays = false
	# Its own tables: the contract's players are still in the first set, and a ranking
	# question asked of those tables would be answered against them.
	var fresh := await _store("dot_tlivem_")
	await _drop(fresh)
	manager.store = await _store("dot_tlivem_")
	add_child(manager)
	var styles := DotTimerStyle.defaults()
	styles[0].minimum_time = 0.0
	manager.set_styles(styles)
	var set := DotTimerZoneSet.new()
	set.map_id = &"live_corridor"
	set.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(Vector3(0, -2, -4), Vector3(4, 4, 4)))
	set.add(DotTimerZone.make(DotTimerZone.Kind.END).set_box(Vector3(96, -2, -4), Vector3(100, 4, 4)))
	manager.set_zones(set)
	manager.add_player(&"p1", "Player One")
	var filed: Array = []
	manager.run_filed.connect(func(result: Dictionary) -> void: filed.append(result))
	var x := -2.0
	while x <= 104.0:
		x += 10.0 / 128.0
		manager.tick_player(&"p1", Vector3(x, 0, 0), Vector3(10, 0, 0), true, true)
	for i in range(60):
		await get_tree().process_frame
		if not filed.is_empty():
			break
	_check("a manager files through the SQL store", filed.size() == 1 and bool(filed[0]["world_record"]))
	var rank: DotResult = await manager.store.player_rank(&"p1")
	_check("and the player is ranked", rank.ok and int(rank.value["rank"]) == 1)
	var profile: DotResult = await manager.profile(&"p1")
	_check("and has a profile", profile.ok and int(profile.value["maps_done"]) == 1)
	_check("and the map was catalogued", (await manager.store.map_info(&"live_corridor")).value != null)

	print("%d passed, %d failed" % [_passed, _failed])
	await _drop(a)
	await _drop(manager.store)
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _store(prefix: String) -> DotTimerStoreSql:
	var dialect := DotSqlDialect.from_name(OS.get_environment("DOT_SQL_DIALECT"))
	var made := DotSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("DOT_SQL_URL"),
		"dialect": DotSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("DOT_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	var store := DotTimerStoreSql.new(made.value)
	store.prefix = prefix
	var opened: DotResult = await store.open()
	if not opened.ok:
		print("could not open: %s (%s)" % [opened.error.message, opened.error.detail])
		return null
	return store


func _drop(store: DotTimerStoreSql) -> void:
	if store == null:
		return
	for name in ["records", "history", "players", "maps", "progress", "resume"]:
		await store.driver.execute("DROP TABLE IF EXISTS %s" % store.table(name))
	await store.driver.execute("DELETE FROM dot_sql_migrations WHERE component = ?", ["dot_timer:%s" % store.prefix])


func _check(what: String, passed: bool) -> void:
	if passed:
		_passed += 1
		print("  %-72s ok" % what)
		return
	_failed += 1
	print("  %-72s FAILED" % what)
