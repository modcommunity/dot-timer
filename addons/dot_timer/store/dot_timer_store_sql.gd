class_name DotTimerStoreSql
extends DotTimerStore

## Records in SQLite, PostgreSQL or MySQL, through a dot-sql driver.
##
## [codeblock]
## var made := DotSql.from_config({"driver": "sqlite", "path": "user://g2gfast.db"}, self)
## var store := DotTimerStoreSql.new(made.value)
## var opened := await store.open()     # creates or migrates the tables
## manager.store = store
## [/codeblock]
##
## [b]The driver is duck-typed.[/b] Held untyped and asked for [code]query[/code],
## [code]execute[/code], [code]batch[/code], [code]upsert_sql[/code] and
## [code]migrate[/code], so dot-timer still depends only on dot-core and parses in a
## project without dot-sql. dot-sql's drivers are the ones that exist; anything with the
## same five methods will do.
##
## [b]Several servers can share one database[/b] — the reason to use this rather than
## [DotTimerStoreFile]. Every write is shaped so two of them cannot corrupt a board:
## an improvement is a conditional UPDATE ([code]WHERE time > ?[/code]), so a slower run
## arriving second can never overwrite a faster one that landed first, whatever order
## the two servers' requests reach the database in.
##
## [b]Reads are cached, writes go straight through.[/b] A HUD asks for the record and
## the player's best every frame and a scoreboard asks for the top ten on every open;
## none of that can wait on a network. So the top of a board, a board's size and each
## player's best are kept for [member cache_seconds], and this server's own writes
## update the cache as they land — a record set HERE is on the HUD at once. What the
## cache cannot see is another server's write; that is at most [member cache_seconds]
## old, which is the trade, and 0 turns caching off.

const CHANNEL := "timer.store.sql"

## Schema component, in dot-sql's migration table. A new step is appended to
## [method migration_steps]; an existing one is never edited.
const COMPONENT := "dot_timer"

var driver = null

## Table name prefix. Checked as an identifier before anything is built from it.
var prefix: String = "dot_timer_"

## Seconds a cached read is served before it is fetched again. 0 = no cache.
var cache_seconds: float = 10.0

## How many rows of a board's top the cache holds — what a scoreboard asks for.
var cache_rows: int = 25

## Diagnostics.
var queries: int = 0
var cache_hits: int = 0

var _top_cache: Dictionary = {}
var _count_cache: Dictionary = {}
var _best_cache: Dictionary = {}
var _refreshing: Dictionary = {}


func _init(p_driver = null) -> void:
	driver = p_driver


# --- Schema ----------------------------------------------------------------

func table(name: String) -> String:
	return prefix + name


## The tables, as dot-sql specs. Every one is keyed so its hottest query is an index
## range scan: a board by time, a player's records, the latest history.
func table_specs() -> Array:
	var record_columns := [
		{"name": "map", "type": "key", "null": false},
		{"name": "track", "type": "int", "null": false, "default": 0},
		{"name": "style", "type": "key", "null": false},
		{"name": "stage", "type": "int", "null": false, "default": 0},
		{"name": "player", "type": "key", "null": false},
		{"name": "name", "type": "text"},
		{"name": "time", "type": "real", "null": false},
		{"name": "splits", "type": "json"},
		{"name": "set_at", "type": "bigint", "null": false, "default": 0},
		{"name": "tick_rate", "type": "int", "null": false, "default": 128},
		{"name": "zones", "type": "text"},
		{"name": "stats", "type": "json"},
		{"name": "points", "type": "real", "null": false, "default": 0},
		{"name": "replay", "type": "text"},
		{"name": "extra", "type": "json"},
		{"name": "completions", "type": "int", "null": false, "default": 1},
		{"name": "start_speed", "type": "real", "null": false, "default": 0},
		{"name": "start_speed_z", "type": "real", "null": false, "default": 0},
		{"name": "timescale", "type": "real", "null": false, "default": 1},
	]
	return [
		{
			"name": table("records"),
			"columns": record_columns,
			"primary_key": ["map", "track", "style", "stage", "player"],
			"indexes": [
				# The board, in time order: the record, the top ten, a rank by COUNT.
				{"name": "board", "columns": ["map", "track", "style", "stage", "time"]},
				# A player's own records: a profile, a points total.
				{"name": "player", "columns": ["player", "stage", "points"]},
			],
		},
		{
			"name": table("history"),
			"columns": [
				{"name": "map", "type": "key", "null": false},
				{"name": "track", "type": "int", "null": false, "default": 0},
				{"name": "style", "type": "key", "null": false},
				{"name": "stage", "type": "int", "null": false, "default": 0},
				{"name": "player", "type": "key", "null": false},
				{"name": "set_at", "type": "bigint", "null": false},
				{"name": "time", "type": "real", "null": false},
				{"name": "previous_time", "type": "real", "null": false, "default": -1},
				{"name": "record_time_before", "type": "real", "null": false, "default": -1},
				{"name": "was_record", "type": "bool", "null": false, "default": false},
				{"name": "data", "type": "json"},
			],
			"primary_key": ["map", "track", "style", "stage", "player", "set_at"],
			"indexes": [
				{"name": "latest", "columns": ["was_record", "set_at"]},
				{"name": "when_set", "columns": ["set_at"]},
			],
		},
		{
			"name": table("players"),
			"columns": [
				{"name": "player", "type": "key", "null": false},
				{"name": "name", "type": "text"},
				{"name": "points", "type": "real", "null": false, "default": 0},
				{"name": "first_seen", "type": "bigint", "null": false, "default": 0},
				{"name": "last_seen", "type": "bigint", "null": false, "default": 0},
				{"name": "playtime", "type": "real", "null": false, "default": 0},
			],
			"primary_key": ["player"],
			"indexes": [{"name": "points", "columns": ["points"]}],
		},
		{
			"name": table("maps"),
			"columns": [
				{"name": "map", "type": "key", "null": false},
				{"name": "tier", "type": "int", "null": false, "default": 1},
				{"name": "stages", "type": "int", "null": false, "default": 0},
				{"name": "bonuses", "type": "int", "null": false, "default": 0},
				{"name": "ranked", "type": "bool", "null": false, "default": true},
				{"name": "mapper", "type": "text"},
				{"name": "info", "type": "json"},
				{"name": "updated_at", "type": "bigint", "null": false, "default": 0},
			],
			"primary_key": ["map"],
		},
		{
			"name": table("progress"),
			"columns": [
				{"name": "player", "type": "key", "null": false},
				{"name": "map", "type": "key", "null": false},
				{"name": "track", "type": "int", "null": false, "default": 0},
				{"name": "style", "type": "key", "null": false},
				{"name": "attempts", "type": "int", "null": false, "default": 0},
				{"name": "completions", "type": "int", "null": false, "default": 0},
				{"name": "time_spent", "type": "real", "null": false, "default": 0},
				{"name": "time_to_first", "type": "real", "null": false, "default": -1},
			],
			"primary_key": ["player", "map", "track", "style"],
		},
		{
			"name": table("resume"),
			"columns": [
				{"name": "player", "type": "key", "null": false},
				{"name": "map", "type": "key", "null": false},
				{"name": "state", "type": "json"},
				{"name": "saved_at", "type": "bigint", "null": false, "default": 0},
			],
			"primary_key": ["player", "map"],
		},
	]


func migration_steps() -> Array:
	return [table_specs()]


## Opens the driver and creates or migrates the tables.
##
## [b]A database written by a newer build is refused[/b] (dot-sql's migrator), rather
## than read with columns that have changed meaning underneath this one.
func open() -> DotResult:
	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "No SQL driver.")

	if not prefix.is_valid_ascii_identifier() or prefix.length() > 40:
		return DotResult.fail(DotError.CODE_INVALID, "Unsafe table prefix.", prefix)

	var available: DotResult = driver.is_available()
	if not available.ok:
		return available

	var opened: DotResult = await driver.open()
	if not opened.ok:
		return opened

	var migrated: DotResult = await driver.migrate("%s:%s" % [COMPONENT, prefix], migration_steps())
	if not migrated.ok:
		return migrated.wrap("Could not prepare the records tables.")

	DotLog.info(CHANNEL, "records tables ready", {"prefix": prefix, "driver": driver.driver_name()})
	return DotResult.success(true)


func is_open() -> bool:
	return driver != null and driver.is_open()


# --- Row mapping -----------------------------------------------------------

const RECORD_COLUMNS := [
	"map", "track", "style", "stage", "player", "name", "time", "splits", "set_at",
	"tick_rate", "zones", "stats", "points", "replay", "extra", "completions",
	"start_speed", "start_speed_z", "timescale",
]


static func _record_params(r: DotTimerRecord) -> Array:
	return [
		String(r.map_id), r.track, String(r.style_id), r.stage, String(r.player_id),
		r.player_name, r.time, JSON.stringify(r.splits), r.set_at, r.tick_rate,
		r.zone_fingerprint, JSON.stringify(r.stats), r.points, r.replay_id,
		JSON.stringify(r.extra), r.completions, r.start_speed, r.start_speed_z, r.timescale,
	]


## A row back into a record. Numbers may arrive as floats (a gateway's JSON has one
## number type) and JSON columns as text, so every field is converted explicitly.
static func _record_from(row: Dictionary) -> DotTimerRecord:
	var r := DotTimerRecord.new()
	r.map_id = StringName(str(row.get("map", "")))
	r.track = int(row.get("track", 0))
	r.style_id = StringName(str(row.get("style", "normal")))
	r.stage = int(row.get("stage", 0))
	r.player_id = StringName(str(row.get("player", "")))
	r.player_name = _text(row.get("name"))
	r.time = float(row.get("time", 0.0))
	r.splits = _json_dict(row.get("splits"))
	r.set_at = int(row.get("set_at", 0))
	r.tick_rate = int(row.get("tick_rate", 128))
	r.zone_fingerprint = _text(row.get("zones"))
	r.stats = _json_dict(row.get("stats"))
	r.points = float(row.get("points", 0.0))
	r.replay_id = _text(row.get("replay"))
	r.extra = _json_dict(row.get("extra"))
	r.completions = maxi(int(row.get("completions", 1)), 1)
	r.start_speed = float(row.get("start_speed", 0.0))
	r.start_speed_z = float(row.get("start_speed_z", 0.0))
	r.timescale = float(row.get("timescale", 1.0))
	return r


static func _text(value: Variant) -> String:
	return "" if value == null else str(value)


static func _json_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value == null or str(value) == "":
		return {}
	var parsed: Variant = JSON.parse_string(str(value))
	return parsed if parsed is Dictionary else {}


## A boolean column back. Stored 0/1 everywhere, but a driver may hand back a bool, an
## int, a float or a string, and each backend picks a different one.
static func _bool(value: Variant) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return value != 0
	return str(value).strip_edges().to_lower() in ["1", "true", "t", "yes"]


# --- Statements ------------------------------------------------------------

const BOARD_WHERE := "map = ? AND track = ? AND style = ? AND stage = ?"


static func _board_params(map_id: StringName, track: int, style_id: StringName, stage: int) -> Array:
	return [String(map_id), track, String(style_id), stage]


func _query(sql: String, params: Array = []) -> DotResult:
	queries += 1
	return await driver.query(sql, params)


func _execute(sql: String, params: Array = []) -> DotResult:
	queries += 1
	return await driver.execute(sql, params)


func _select_record(
	map_id: StringName, track: int, style_id: StringName, player_id: StringName, stage: int
) -> DotResult:
	var res := await _query(
		"SELECT * FROM %s WHERE %s AND player = ?" % [table("records"), BOARD_WHERE],
		_board_params(map_id, track, style_id, stage) + [String(player_id)]
	)
	if not res.ok:
		return res
	var rows: Array = res.value
	return DotResult.success(_record_from(rows[0]) if not rows.is_empty() else null)


# --- Boards ----------------------------------------------------------------

func put(record: DotTimerRecord) -> DotResult:
	if record == null:
		return DotResult.fail(DotError.CODE_INVALID, "No record to store.")
	if not is_open():
		return DotResult.fail(DotError.CODE_STATE, "The records database is not open.")

	var prev_res := await _select_record(record.map_id, record.track, record.style_id, record.player_id, record.stage)
	if not prev_res.ok:
		return prev_res.wrap("Could not read the player's best.")
	var previous: DotTimerRecord = prev_res.value

	var leader_res := await _query(
		"SELECT * FROM %s WHERE %s ORDER BY time ASC LIMIT 1" % [table("records"), BOARD_WHERE],
		_board_params(record.map_id, record.track, record.style_id, record.stage)
	)
	if not leader_res.ok:
		return leader_res.wrap("Could not read the board's record.")
	var leader: DotTimerRecord = _record_from(leader_res.value[0]) if not (leader_res.value as Array).is_empty() else null

	var completions := (previous.completions if previous != null else 0) + 1
	var improved := record.beats(previous)
	record.completions = completions
	var key_params := _board_params(record.map_id, record.track, record.style_id, record.stage) + [String(record.player_id)]

	if not improved:
		var bumped := await _execute(
			"UPDATE %s SET completions = completions + 1, name = ? WHERE %s AND player = ?" % [table("records"), BOARD_WHERE],
			[record.player_name] + key_params
		)
		if not bumped.ok:
			return bumped.wrap("Could not count the finish.")
		previous.completions = completions
		_cache_best(record.board_key(), record.player_id, previous)
		return DotResult.success(_put_result(previous, false, leader, completions))

	var statements: Array = []
	if previous == null:
		# Insert-or-ignore, then the conditional update below. Two servers filing a
		# player's first time at once (the same player on two servers is not a thing,
		# but a retried request is) both succeed, and the update keeps the faster.
		statements.append([
			driver.upsert_sql(table("records"), PackedStringArray(RECORD_COLUMNS),
				PackedStringArray(["map", "track", "style", "stage", "player"]), []),
			_record_params(record),
		])

	var sets := PackedStringArray()
	for column in RECORD_COLUMNS:
		if column in ["map", "track", "style", "stage", "player", "completions"]:
			continue
		sets.append("%s = ?" % column)
	var update_params: Array = []
	var all_params := _record_params(record)
	for i in range(RECORD_COLUMNS.size()):
		if RECORD_COLUMNS[i] in ["map", "track", "style", "stage", "player", "completions"]:
			continue
		update_params.append(all_params[i])
	# `time > ?`: only ever replace a slower row. The guard that makes concurrent
	# servers safe — see the class documentation.
	statements.append([
		"UPDATE %s SET %s, completions = ? WHERE %s AND player = ? AND time > ?" % [
			table("records"), ", ".join(sets), BOARD_WHERE],
		update_params + [completions] + key_params + [record.time],
	])

	var wrote: DotResult = await driver.batch(statements)
	queries += statements.size()
	if not wrote.ok:
		return wrote.wrap("Could not file the record.")

	# [b]Read back, then decide.[/b] The conditional UPDATE keeps the faster row whatever
	# order two servers' writes land in, but it cannot tell THIS caller whether its write
	# was the one kept — and a driver's affected-row count is not something every
	# backend gives. So the row is read again: if it is not this run, another server
	# filed a faster one in between, and this run is a completion, not an improvement.
	# The record question is asked of the board as it stands after the write, so two
	# servers beating the same record at once do not both announce it.
	var board := record.board_key()
	var after := await _select_record(record.map_id, record.track, record.style_id, record.player_id, record.stage)
	if not after.ok or after.value == null:
		return after if not after.ok else DotResult.fail(DotError.CODE_IO, "The record vanished as it was filed.")
	var kept: DotTimerRecord = after.value
	if not _same_time(kept.time, record.time):
		_cache_best(board, record.player_id, kept)
		return DotResult.success(_put_result(kept, false, leader, kept.completions))

	var faster: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE %s AND time < ?" % [table("records"), BOARD_WHERE],
		_board_params(record.map_id, record.track, record.style_id, record.stage) + [kept.time], 0
	)
	queries += 1
	var was_record := faster.ok and int(faster.value) == 0
	record.completions = kept.completions

	var logged: DotResult = await _execute(
		driver.upsert_sql(table("history"),
			PackedStringArray(["map", "track", "style", "stage", "player", "set_at", "time",
				"previous_time", "record_time_before", "was_record", "data"]),
			PackedStringArray(["map", "track", "style", "stage", "player", "set_at"])),
		_board_params(record.map_id, record.track, record.style_id, record.stage) + [
			String(record.player_id), record.set_at, kept.time,
			previous.time if previous != null else -1.0,
			leader.time if leader != null else -1.0,
			1 if was_record else 0,
			JSON.stringify(record.to_dictionary(), "", true, true),
		]
	)
	if not logged.ok:
		# The record is filed; only the history line is missing. Not worth refusing a
		# run that IS on the board over.
		DotLog.warn(CHANNEL, "a record was filed but its history line was not", {"why": logged.error.message})

	_top_cache.erase(board)
	_count_cache.erase(board)
	_cache_best(board, record.player_id, kept)

	# `previous_record` is the leader as read before the write, for the message ("beating
	# X by ..."); whether THIS run took first place is `was_record`, from after it.
	var result := _put_result(previous, true, leader, kept.completions)
	result["was_record"] = was_record
	return DotResult.success(result)


## Whether two stored times are the same run. Exactly, unless a float lost its last bits
## on the way to the database and back.
static func _same_time(a: float, b: float) -> bool:
	return absf(a - b) <= 1e-9 * maxf(1.0, absf(b))


func _put_result(
	previous: DotTimerRecord, improved: bool, leader: DotTimerRecord, completions: int
) -> Dictionary:
	return {
		"previous": previous,
		"improved": improved,
		"previous_record": leader,
		"completions": completions,
	}


func top(
	map_id: StringName, track: int, style_id: StringName,
	limit: int = 10, offset: int = 0, stage: int = 0
) -> DotResult:
	var board := DotTimerRecord.board_key_of(map_id, track, style_id, stage)

	if offset == 0 and limit <= cache_rows and _fresh(_top_cache.get(board)):
		cache_hits += 1
		return DotResult.success(_copy_rows(_top_cache[board]["rows"], limit))

	var fetch := maxi(limit, cache_rows) if offset == 0 else limit
	var res := await _query(
		"SELECT * FROM %s WHERE %s ORDER BY time ASC, set_at ASC LIMIT ? OFFSET ?" % [table("records"), BOARD_WHERE],
		_board_params(map_id, track, style_id, stage) + [fetch, maxi(offset, 0)]
	)
	if not res.ok:
		return res

	var rows: Array[DotTimerRecord] = []
	for row in (res.value as Array):
		rows.append(_record_from(row))

	if offset == 0 and cache_seconds > 0.0:
		_top_cache[board] = {"at": _now(), "rows": rows, "limit": fetch}

	return DotResult.success(_copy_rows(rows, limit))


func best_for(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> DotResult:
	var board := DotTimerRecord.board_key_of(map_id, track, style_id, stage)
	var cached: Variant = _best_cache.get("%s|%s" % [board, String(player_id)])
	if _fresh(cached):
		cache_hits += 1
		var value: Variant = cached["record"]
		return DotResult.success((value as DotTimerRecord).duplicate_record() if value is DotTimerRecord else null)

	var res := await _select_record(map_id, track, style_id, player_id, stage)
	if res.ok:
		_cache_best(board, player_id, res.value)
	return res


func rank_of(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> DotResult:
	var mine := await best_for(map_id, track, style_id, player_id, stage)
	if not mine.ok:
		return mine
	if mine.value == null:
		return DotResult.success(0)
	return await rank_for_time(map_id, track, style_id, (mine.value as DotTimerRecord).time, stage)


func rank_for_time(
	map_id: StringName, track: int, style_id: StringName,
	time: float, stage: int = 0
) -> DotResult:
	var res: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE %s AND time < ?" % [table("records"), BOARD_WHERE],
		_board_params(map_id, track, style_id, stage) + [time], 0
	)
	queries += 1
	if not res.ok:
		return res
	return DotResult.success(int(res.value) + 1)


func count_on(
	map_id: StringName, track: int, style_id: StringName, stage: int = 0
) -> DotResult:
	var board := DotTimerRecord.board_key_of(map_id, track, style_id, stage)
	if _fresh(_count_cache.get(board)):
		cache_hits += 1
		return DotResult.success(int(_count_cache[board]["n"]))

	var res: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE %s" % [table("records"), BOARD_WHERE],
		_board_params(map_id, track, style_id, stage), 0
	)
	queries += 1
	if not res.ok:
		return res
	if cache_seconds > 0.0:
		_count_cache[board] = {"at": _now(), "n": int(res.value)}
	return DotResult.success(int(res.value))


func remove(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> DotResult:
	var existing := await _select_record(map_id, track, style_id, player_id, stage)
	if not existing.ok:
		return existing
	if existing.value == null:
		return DotResult.success(false)
	var res := await _execute(
		"DELETE FROM %s WHERE %s AND player = ?" % [table("records"), BOARD_WHERE],
		_board_params(map_id, track, style_id, stage) + [String(player_id)]
	)
	if not res.ok:
		return res
	_forget_board(DotTimerRecord.board_key_of(map_id, track, style_id, stage))
	return DotResult.success(true)


func set_points(records: Array) -> DotResult:
	var statements: Array = []
	for record in records:
		if not (record is DotTimerRecord):
			continue
		var r: DotTimerRecord = record
		statements.append([
			"UPDATE %s SET points = ? WHERE %s AND player = ?" % [table("records"), BOARD_WHERE],
			[r.points] + _board_params(r.map_id, r.track, r.style_id, r.stage) + [String(r.player_id)],
		])
		_top_cache.erase(r.board_key())
		_best_cache.erase("%s|%s" % [r.board_key(), String(r.player_id)])
	if statements.is_empty():
		return DotResult.success(0)
	var res: DotResult = await driver.batch(statements)
	queries += statements.size()
	return res if not res.ok else DotResult.success(statements.size())


func records_of(player_id: StringName, filter: Dictionary = {}) -> DotResult:
	var where := PackedStringArray(["player = ?"])
	var params: Array = [String(player_id)]
	_filter_sql(filter, where, params)
	var res := await _query(
		"SELECT * FROM %s WHERE %s ORDER BY map, track, style, stage" % [table("records"), " AND ".join(where)],
		params
	)
	return _records_result(res)


func records_on_map(map_id: StringName) -> DotResult:
	var res := await _query(
		"SELECT * FROM %s WHERE map = ? ORDER BY track, style, stage, time" % table("records"),
		[String(map_id)]
	)
	return _records_result(res)


func record_count(player_id: StringName, filter: Dictionary = {}) -> DotResult:
	var where := PackedStringArray(["r.player = ?"])
	var params: Array = [String(player_id)]
	_filter_sql(filter, where, params, "r.")
	# A board is held when nobody on it is strictly faster: a tie for first counts.
	var res: DotResult = await driver.query_value(
		("SELECT COUNT(*) AS n FROM %s r WHERE %s AND NOT EXISTS (SELECT 1 FROM %s b "
		+ "WHERE b.map = r.map AND b.track = r.track AND b.style = r.style AND b.stage = r.stage "
		+ "AND b.time < r.time)") % [table("records"), " AND ".join(where), table("records")],
		params, 0
	)
	queries += 1
	if not res.ok:
		return res
	return DotResult.success(int(res.value))


func recent(limit: int = 20, filter: Dictionary = {}) -> DotResult:
	var where := PackedStringArray()
	var params: Array = []
	if bool(filter.get("records_only", true)):
		where.append("was_record = 1")
	_filter_sql(filter, where, params)
	var res := await _query(
		"SELECT * FROM %s%s ORDER BY set_at DESC LIMIT ?" % [
			table("history"), (" WHERE " + " AND ".join(where)) if not where.is_empty() else ""],
		params + [limit]
	)
	if not res.ok:
		return res
	var out: Array[Dictionary] = []
	for row in (res.value as Array):
		var data := _json_dict(row.get("data"))
		var record := DotTimerRecord.from_dictionary(data) if not data.is_empty() else _record_from(row)
		out.append({
			"record": record,
			"previous_time": float(row.get("previous_time", -1.0)),
			"previous_record_time": float(row.get("record_time_before", -1.0)),
			"was_record": _bool(row.get("was_record", 0)),
		})
	return DotResult.success(out)


static func _filter_sql(filter: Dictionary, where: PackedStringArray, params: Array, alias: String = "") -> void:
	if filter.has("map"):
		where.append(alias + "map = ?")
		params.append(str(filter["map"]))
	if filter.has("track"):
		where.append(alias + "track = ?")
		params.append(int(filter["track"]))
	if filter.has("style"):
		where.append(alias + "style = ?")
		params.append(str(filter["style"]))
	var stage := int(filter.get("stage", 0))
	if stage >= 0:
		where.append(alias + "stage = ?")
		params.append(stage)


func _records_result(res: DotResult) -> DotResult:
	if not res.ok:
		return res
	var out: Array[DotTimerRecord] = []
	for row in (res.value as Array):
		out.append(_record_from(row))
	return DotResult.success(out)


func wipe_board(
	map_id: StringName, track: int, style_id: StringName, stage: int = -1
) -> DotResult:
	var where := "map = ? AND track = ? AND style = ?"
	var params: Array = [String(map_id), track, String(style_id)]
	if stage >= 0:
		where += " AND stage = ?"
		params.append(stage)
	var counted: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE %s" % [table("records"), where], params, 0)
	var res := await _execute("DELETE FROM %s WHERE %s" % [table("records"), where], params)
	if not res.ok:
		return res
	_clear_cache()
	return DotResult.success(int(counted.value) if counted.ok else 0)


func wipe_player(player_id: StringName) -> DotResult:
	var id := String(player_id)
	var counted: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE player = ?" % table("records"), [id], 0)
	var res: DotResult = await driver.batch([
		["DELETE FROM %s WHERE player = ?" % table("records"), [id]],
		["DELETE FROM %s WHERE player = ?" % table("history"), [id]],
		["DELETE FROM %s WHERE player = ?" % table("players"), [id]],
		["DELETE FROM %s WHERE player = ?" % table("progress"), [id]],
		["DELETE FROM %s WHERE player = ?" % table("resume"), [id]],
	])
	queries += 5
	if not res.ok:
		return res
	_clear_cache()
	return DotResult.success(int(counted.value) if counted.ok else 0)


func wipe_map(map_id: StringName) -> DotResult:
	var id := String(map_id)
	var counted: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE map = ?" % table("records"), [id], 0)
	var res: DotResult = await driver.batch([
		["DELETE FROM %s WHERE map = ?" % table("records"), [id]],
		["DELETE FROM %s WHERE map = ?" % table("history"), [id]],
		["DELETE FROM %s WHERE map = ?" % table("progress"), [id]],
		["DELETE FROM %s WHERE map = ?" % table("resume"), [id]],
		["DELETE FROM %s WHERE map = ?" % table("maps"), [id]],
	])
	queries += 5
	if not res.ok:
		return res
	_clear_cache()
	return DotResult.success(int(counted.value) if counted.ok else 0)


# --- Players ---------------------------------------------------------------

func note_player(
	player_id: StringName, name: String, seen_at: int, playtime_add: float = 0.0
) -> DotResult:
	var id := String(player_id)
	var existing: DotResult = await driver.query_one(
		"SELECT player FROM %s WHERE player = ?" % table("players"), [id])
	queries += 1
	if not existing.ok:
		return existing
	if existing.value == null:
		var made := await _execute(
			driver.upsert_sql(table("players"),
				PackedStringArray(["player", "name", "points", "first_seen", "last_seen", "playtime"]),
				PackedStringArray(["player"]), []),
			[id, name, 0.0, seen_at, seen_at, maxf(playtime_add, 0.0)]
		)
		return made if not made.ok else DotResult.success(true)
	var sql := "UPDATE %s SET last_seen = ?, playtime = playtime + ?" % table("players")
	var params: Array = [seen_at, maxf(playtime_add, 0.0)]
	if name != "":
		sql += ", name = ?"
		params.append(name)
	var res := await _execute(sql + " WHERE player = ?", params + [id])
	return res if not res.ok else DotResult.success(true)


func player_info(player_id: StringName) -> DotResult:
	var res: DotResult = await driver.query_one(
		"SELECT * FROM %s WHERE player = ?" % table("players"), [String(player_id)])
	queries += 1
	if not res.ok or res.value == null:
		return res
	return DotResult.success(_player_row(res.value))


static func _player_row(row: Dictionary) -> Dictionary:
	return {
		"player": str(row.get("player", "")),
		"name": _text(row.get("name")),
		"points": float(row.get("points", 0.0)),
		"first_seen": int(row.get("first_seen", 0)),
		"last_seen": int(row.get("last_seen", 0)),
		"playtime": float(row.get("playtime", 0.0)),
	}


func refresh_player_points(
	player_ids: Array, weighting: float = 1.0, limit: int = 0
) -> DotResult:
	var ids: Array = []
	for id in player_ids:
		ids.append(str(id))
	var done := 0
	# In chunks: an IN list has a parameter per player, and a board with a thousand
	# finishers re-scored at once would otherwise be one statement past some drivers'
	# parameter limit.
	for start in range(0, ids.size(), 200):
		var chunk := ids.slice(start, start + 200)
		var marks := PackedStringArray()
		for _i in chunk:
			marks.append("?")
		var res := await _query(
			"SELECT player, name, points FROM %s WHERE stage = 0 AND player IN (%s)" % [
				table("records"), ", ".join(marks)],
			chunk
		)
		if not res.ok:
			return res
		var points_by: Dictionary = {}
		var names: Dictionary = {}
		for row in (res.value as Array):
			var p := str(row["player"])
			if not points_by.has(p):
				points_by[p] = []
			(points_by[p] as Array).append(float(row["points"]))
			names[p] = _text(row.get("name"))
		var statements: Array = []
		var now := int(Time.get_unix_time_from_system())
		for p in chunk:
			var total := DotTimerPoints.weighted_total(points_by.get(p, []), weighting, limit)
			statements.append([
				driver.upsert_sql(table("players"),
					PackedStringArray(["player", "name", "points", "first_seen", "last_seen", "playtime"]),
					PackedStringArray(["player"]), ["points"]),
				[p, names.get(p, p), total, now, now, 0.0],
			])
		var wrote: DotResult = await driver.batch(statements)
		queries += statements.size()
		if not wrote.ok:
			return wrote
		done += chunk.size()
	return DotResult.success(done)


func top_players(limit: int = 10, offset: int = 0) -> DotResult:
	var res := await _query(
		"SELECT player, name, points FROM %s WHERE points > 0 ORDER BY points DESC, player ASC LIMIT ? OFFSET ?" % table("players"),
		[limit, maxi(offset, 0)]
	)
	if not res.ok:
		return res
	var rows: Array = res.value
	var out: Array[Dictionary] = []
	if rows.is_empty():
		return DotResult.success(out)
	# Ties share a rank, so the first row of a page needs one COUNT to know where it is.
	var first_points := float(rows[0]["points"])
	var above: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE points > ?" % table("players"), [first_points], 0)
	queries += 1
	var rank := int(above.value) + 1 if above.ok else offset + 1
	for i in range(rows.size()):
		if i > 0 and float(rows[i]["points"]) != float(rows[i - 1]["points"]):
			rank = offset + i + 1
		out.append({
			"player": str(rows[i]["player"]),
			"name": _text(rows[i].get("name")),
			"points": float(rows[i]["points"]),
			"rank": rank,
		})
	return DotResult.success(out)


func player_rank(player_id: StringName) -> DotResult:
	var info := await player_info(player_id)
	if not info.ok:
		return info
	var points := float((info.value as Dictionary)["points"]) if info.value != null else 0.0
	var total: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE points > 0" % table("players"), [], 0)
	queries += 1
	if not total.ok:
		return total
	if points <= 0.0:
		return DotResult.success({"rank": 0, "total": int(total.value), "points": 0.0})
	var above: DotResult = await driver.query_value(
		"SELECT COUNT(*) AS n FROM %s WHERE points > ?" % table("players"), [points], 0)
	queries += 1
	if not above.ok:
		return above
	return DotResult.success({"rank": int(above.value) + 1, "total": int(total.value), "points": points})


# --- Maps ------------------------------------------------------------------

func put_map(info: Dictionary) -> DotResult:
	var id := str(info.get("map", ""))
	if id == "":
		return DotResult.fail(DotError.CODE_INVALID, "A map needs an id.")
	var existing := await map_info(StringName(id))
	var merged: Dictionary = existing.value if existing.ok and existing.value != null else {}
	for key in info:
		merged[key] = info[key]
	var extra := {}
	for key in merged:
		if key not in ["map", "tier", "stages", "bonuses", "ranked", "mapper", "updated_at"]:
			extra[key] = merged[key]
	var res := await _execute(
		driver.upsert_sql(table("maps"),
			PackedStringArray(["map", "tier", "stages", "bonuses", "ranked", "mapper", "info", "updated_at"]),
			PackedStringArray(["map"])),
		[id, int(merged.get("tier", 1)), int(merged.get("stages", 0)), int(merged.get("bonuses", 0)),
			1 if bool(merged.get("ranked", true)) else 0, str(merged.get("mapper", "")),
			JSON.stringify(extra), int(Time.get_unix_time_from_system())]
	)
	return res if not res.ok else DotResult.success(true)


func map_info(map_id: StringName) -> DotResult:
	var res: DotResult = await driver.query_one(
		"SELECT * FROM %s WHERE map = ?" % table("maps"), [String(map_id)])
	queries += 1
	if not res.ok or res.value == null:
		return res
	return DotResult.success(_map_row(res.value))


static func _map_row(row: Dictionary) -> Dictionary:
	var out := _json_dict(row.get("info"))
	out["map"] = str(row.get("map", ""))
	out["tier"] = int(row.get("tier", 1))
	out["stages"] = int(row.get("stages", 0))
	out["bonuses"] = int(row.get("bonuses", 0))
	out["ranked"] = _bool(row.get("ranked", 1))
	out["mapper"] = _text(row.get("mapper"))
	out["updated_at"] = int(row.get("updated_at", 0))
	return out


func maps() -> DotResult:
	var res := await _query("SELECT * FROM %s ORDER BY map" % table("maps"))
	if not res.ok:
		return res
	var out: Array[Dictionary] = []
	for row in (res.value as Array):
		out.append(_map_row(row))
	return DotResult.success(out)


# --- Progress --------------------------------------------------------------

func note_progress(
	player_id: StringName, map_id: StringName, track: int, style_id: StringName,
	attempts: int, seconds: float, finished: bool
) -> DotResult:
	var key := [String(player_id), String(map_id), track, String(style_id)]
	var existing := await progress_for(player_id, map_id, track, style_id)
	if not existing.ok:
		return existing
	if existing.value == null:
		var spent := maxf(seconds, 0.0)
		var made := await _execute(
			driver.upsert_sql(table("progress"),
				PackedStringArray(["player", "map", "track", "style", "attempts", "completions", "time_spent", "time_to_first"]),
				PackedStringArray(["player", "map", "track", "style"]), []),
			key + [maxi(attempts, 0), 1 if finished else 0, spent, spent if finished else -1.0]
		)
		return made if not made.ok else DotResult.success(true)
	var sql := "UPDATE %s SET attempts = attempts + ?, time_spent = time_spent + ?" % table("progress")
	var params: Array = [maxi(attempts, 0), maxf(seconds, 0.0)]
	if finished:
		sql += ", completions = completions + 1"
		if float((existing.value as Dictionary)["time_to_first"]) < 0.0:
			# Computed here rather than as `time_spent + ?` in the statement: MySQL
			# evaluates SET left to right with the values it has already assigned, so
			# there `time_spent` is the NEW total and the finish would be counted twice.
			# Postgres and SQLite read the old row. One spelling that means the same on
			# all three is a bound value.
			sql += ", time_to_first = ?"
			params.append(float((existing.value as Dictionary)["time_spent"]) + maxf(seconds, 0.0))
	var res := await _execute(sql + " WHERE player = ? AND map = ? AND track = ? AND style = ?", params + key)
	return res if not res.ok else DotResult.success(true)


func progress_for(
	player_id: StringName, map_id: StringName, track: int, style_id: StringName
) -> DotResult:
	var res: DotResult = await driver.query_one(
		"SELECT * FROM %s WHERE player = ? AND map = ? AND track = ? AND style = ?" % table("progress"),
		[String(player_id), String(map_id), track, String(style_id)])
	queries += 1
	if not res.ok or res.value == null:
		return res
	var row: Dictionary = res.value
	return DotResult.success({
		"attempts": int(row.get("attempts", 0)),
		"completions": int(row.get("completions", 0)),
		"time_spent": float(row.get("time_spent", 0.0)),
		"time_to_first": float(row.get("time_to_first", -1.0)),
	})


# --- Saved runs ------------------------------------------------------------

func save_resume(player_id: StringName, map_id: StringName, state: Dictionary) -> DotResult:
	var res := await _execute(
		driver.upsert_sql(table("resume"), PackedStringArray(["player", "map", "state", "saved_at"]),
			PackedStringArray(["player", "map"])),
		[String(player_id), String(map_id), JSON.stringify(state), int(Time.get_unix_time_from_system())]
	)
	return res if not res.ok else DotResult.success(true)


func take_resume(player_id: StringName, map_id: StringName) -> DotResult:
	var res: DotResult = await driver.query_one(
		"SELECT state FROM %s WHERE player = ? AND map = ?" % table("resume"),
		[String(player_id), String(map_id)])
	queries += 1
	if not res.ok or res.value == null:
		return res
	var gone := await _execute(
		"DELETE FROM %s WHERE player = ? AND map = ?" % table("resume"),
		[String(player_id), String(map_id)])
	if not gone.ok:
		return gone
	var state := _json_dict((res.value as Dictionary).get("state"))
	return DotResult.success(state if not state.is_empty() else null)


# --- The cache -------------------------------------------------------------

func peek_top(
	map_id: StringName, track: int, style_id: StringName,
	limit: int = 10, stage: int = 0
) -> Variant:
	var board := DotTimerRecord.board_key_of(map_id, track, style_id, stage)
	var cached: Variant = _top_cache.get(board)
	if not _fresh(cached):
		_refresh_top(map_id, track, style_id, stage)
	if cached is Dictionary:
		return _copy_rows(cached["rows"], limit)
	return null


func peek_best(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> Variant:
	var board := DotTimerRecord.board_key_of(map_id, track, style_id, stage)
	var cached: Variant = _best_cache.get("%s|%s" % [board, String(player_id)])
	if not _fresh(cached):
		_refresh_best(map_id, track, style_id, player_id, stage)
	if cached is Dictionary:
		var value: Variant = cached["record"]
		return (value as DotTimerRecord).duplicate_record() if value is DotTimerRecord else false
	return null


## Fetches a board's top in the background. Not awaited by its caller — a HUD that
## peeked — and guarded so a HUD peeking every frame starts one fetch, not sixty.
func _refresh_top(map_id: StringName, track: int, style_id: StringName, stage: int) -> void:
	var key := "top|" + DotTimerRecord.board_key_of(map_id, track, style_id, stage)
	if _refreshing.has(key) or not is_open():
		return
	_refreshing[key] = true
	_top_cache.erase(key.substr(4))
	await top(map_id, track, style_id, cache_rows, 0, stage)
	_refreshing.erase(key)


func _refresh_best(
	map_id: StringName, track: int, style_id: StringName, player_id: StringName, stage: int
) -> void:
	var board := DotTimerRecord.board_key_of(map_id, track, style_id, stage)
	var key := "best|%s|%s" % [board, String(player_id)]
	if _refreshing.has(key) or not is_open():
		return
	_refreshing[key] = true
	_best_cache.erase("%s|%s" % [board, String(player_id)])
	await best_for(map_id, track, style_id, player_id, stage)
	_refreshing.erase(key)


func _cache_best(board: String, player_id: StringName, record: DotTimerRecord) -> void:
	if cache_seconds <= 0.0:
		return
	_best_cache["%s|%s" % [board, String(player_id)]] = {"at": _now(), "record": record}


func _forget_board(board: String) -> void:
	_top_cache.erase(board)
	_count_cache.erase(board)
	for key in _best_cache.keys():
		if String(key).begins_with(board + "|"):
			_best_cache.erase(key)


func _clear_cache() -> void:
	_top_cache.clear()
	_count_cache.clear()
	_best_cache.clear()


## Drops every cached read. For an operator who edited the database by hand.
func invalidate() -> void:
	_clear_cache()


func _fresh(entry: Variant) -> bool:
	return (
		cache_seconds > 0.0 and entry is Dictionary
		and _now() - float((entry as Dictionary)["at"]) < cache_seconds
	)


static func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


static func _copy_rows(rows: Array, limit: int) -> Array[DotTimerRecord]:
	var out: Array[DotTimerRecord] = []
	for i in range(mini(limit, rows.size())):
		out.append((rows[i] as DotTimerRecord).duplicate_record())
	return out


func describe() -> Dictionary:
	var out := super.describe()
	out["prefix"] = prefix
	out["open"] = is_open()
	out["queries"] = queries
	out["cache_hits"] = cache_hits
	out["cached_boards"] = _top_cache.size()
	out["driver"] = driver.describe() if driver != null else {}
	return out
