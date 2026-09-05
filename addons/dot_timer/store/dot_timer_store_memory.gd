class_name DotTimerStoreMemory
extends DotTimerStore

## Records in a dictionary. For tests, for a scratch server, and as the reference
## implementation of the interface.
##
## [b]The board index is kept sorted on write, not on read.[/b] A leaderboard is read
## far more often than it is written — a HUD asks for the top ten every time somebody
## finishes, and a scoreboard asks on every open — so paying the sort on the write is
## the right side of the trade. It also makes [method rank_of] a search rather than a
## sort, which is what turns "am I first" from a per-request sort of a thousand rows
## into a lookup.

## board key -> player id -> record.
var _rows: Dictionary = {}

## board key -> sorted array of records, fastest first.
var _boards: Dictionary = {}


static func _key(map_id: StringName, track: int, style_id: StringName) -> String:
	return "%s/%d/%s" % [String(map_id), track, String(style_id)]


func put(record: DotTimerRecord) -> DotResult:
	if record == null:
		return DotResult.fail(DotError.CODE_INVALID, "No record to store.")

	var board := record.board_key()

	if not _rows.has(board):
		_rows[board] = {}
		_boards[board] = []

	var by_player: Dictionary = _rows[board]
	var previous_value: Variant = by_player.get(record.player_id)
	var previous: DotTimerRecord = (
		previous_value if previous_value is DotTimerRecord else null
	)

	if not record.beats(previous):
		# Not an error. Most finished runs are slower than the player's own best, and
		# treating that as a failure would make every HUD have to tell the two apart.
		return DotResult.success(previous)

	by_player[record.player_id] = record

	var board_rows: Array = _boards[board]

	if previous != null:
		board_rows.erase(previous)

	board_rows.append(record)
	DotTimerRecord.sort_fastest_first(board_rows)

	return DotResult.success(previous)


func top(
	map_id: StringName,
	track: int,
	style_id: StringName,
	limit: int = 10
) -> DotResult:
	var board_value: Variant = _boards.get(_key(map_id, track, style_id), [])
	var rows: Array = board_value if board_value is Array else []

	var out: Array[DotTimerRecord] = []

	for i in range(mini(limit, rows.size())):
		out.append(rows[i])

	return DotResult.success(out)


func best_for(
	map_id: StringName,
	track: int,
	style_id: StringName,
	player_id: StringName
) -> DotResult:
	var by_player_value: Variant = _rows.get(_key(map_id, track, style_id), {})
	var by_player: Dictionary = (
		by_player_value if by_player_value is Dictionary else {}
	)

	var found: Variant = by_player.get(player_id)

	return DotResult.success(found if found is DotTimerRecord else null)


func rank_of(
	map_id: StringName,
	track: int,
	style_id: StringName,
	player_id: StringName
) -> DotResult:
	var board_value: Variant = _boards.get(_key(map_id, track, style_id), [])
	var rows: Array = board_value if board_value is Array else []

	for i in range(rows.size()):
		if (rows[i] as DotTimerRecord).player_id == player_id:
			return DotResult.success(i + 1)

	return DotResult.success(0)


func count_on(
	map_id: StringName,
	track: int,
	style_id: StringName
) -> DotResult:
	var board_value: Variant = _boards.get(_key(map_id, track, style_id), [])
	var rows: Array = board_value if board_value is Array else []

	return DotResult.success(rows.size())


func remove(
	map_id: StringName,
	track: int,
	style_id: StringName,
	player_id: StringName
) -> DotResult:
	var board := _key(map_id, track, style_id)
	var by_player_value: Variant = _rows.get(board, {})
	var by_player: Dictionary = (
		by_player_value if by_player_value is Dictionary else {}
	)

	var found: Variant = by_player.get(player_id)

	if not (found is DotTimerRecord):
		return DotResult.success(false)

	by_player.erase(player_id)

	var board_value: Variant = _boards.get(board, [])
	if board_value is Array:
		(board_value as Array).erase(found)

	return DotResult.success(true)


## Every record, for a bulk export or a migration into another store.
func all_records() -> Array[DotTimerRecord]:
	var out: Array[DotTimerRecord] = []

	for board in _boards:
		for record in (_boards[board] as Array):
			out.append(record)

	return out


func clear() -> void:
	_rows.clear()
	_boards.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["boards"] = _boards.size()

	var total := 0
	for board in _boards:
		total += (_boards[board] as Array).size()

	out["records"] = total
	return out
