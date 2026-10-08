class_name DotTimerStoreFile
extends DotTimerStoreMemory

## Records in JSON files under a directory, one file per board.
##
## [b]A file per board, not one file for everything.[/b] A busy server holds records
## for hundreds of maps across six styles and nine tracks; rewriting all of them
## because somebody finished one is both slow and the thing that loses the lot when
## the process is killed halfway through. One board is a few kilobytes and is written
## atomically.
##
## [b]Extends the in-memory store rather than reimplementing it.[/b] The sorting, the
## "did it beat the previous", the ranking — all of that is the same code, and a
## second copy of it is a second place for the comparison to be the wrong way round.
## This adds loading, saving and a write budget.
##
## [b]Everything else is five small files beside the boards[/b] — players, maps,
## history, progress and saved runs — each written whole and atomically, like a board.
## Their names begin with an underscore, which no board file's can (a board file is
## [code]map.track.style.json[/code], and a map id cannot be empty).
##
## [b]Not for a server with thousands of players.[/b] It reads a whole board to answer
## a query and writes a whole board to file a record, which is correct and is O(board);
## and a profile or a points re-total reads every board on disk once. Past a few
## thousand rows, use [DotTimerStoreSql] — the interface is the same and nothing above
## it changes.

const FILE_CHANNEL := "timer.store.file"

## Where the boards live. Created on first write.
var directory: String = "user://records"

## Boards written per [method flush] before the rest wait for the next one.
##
## Bounded because a map change can dirty every board on the map at once, and writing
## forty files inside one frame is a stall a player feels. What is left stays dirty
## and goes on the next flush.
var flush_batch: int = 16

## Boards changed since the last flush: board key -> [map, track, style, stage].
var _dirty: Dictionary = {}

## Whether a board has been read off disk yet.
var _loaded: Dictionary = {}

## Whether every board on disk has been read — what a cross-board query needs first.
var _all_loaded: bool = false

## Whether the five side files have been read, and which need writing.
var _extras_loaded: bool = false
var _extras_dirty: Dictionary = {}

const EXTRAS := ["players", "maps", "history", "progress", "resume"]


static func at(path: String) -> DotTimerStoreFile:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var store := new()
	store.directory = path
	return store


## The file a board lives in.
##
## [b]Every component is sanitised, not just checked.[/b] A map id arrives from a
## content manifest and a style id from a config file, and either could contain a
## slash or a [code]..[/code] — which without this writes a records file wherever the
## attacker liked.
func path_for(
	map_id: StringName, track: int, style_id: StringName, stage: int = 0
) -> String:
	# Stage 0 keeps the original name, so every board written before sections existed
	# is found where it was left.
	return "%s/%s.%d.%s%s.json" % [
		directory.rstrip("/"),
		safe_component(String(map_id)),
		clampi(track, 0, DotTimerTrack.BONUS_LAST),
		safe_component(String(style_id)),
		(".s%d" % stage) if stage > 0 else "",
	]


## Characters allowed in a path component. Everything else is substituted.
const SAFE_CHARS := (
	"abcdefghijklmnopqrstuvwxyz"
	+ "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	+ "0123456789_-."
)


## A path component that cannot escape [member directory] and cannot collide.
##
## [b]Public, and the only one in this addon[/b] — [DotTimerManager] builds replay
## filenames out of the same wire-supplied ids and calls this rather than growing a
## second sanitiser. Two of them is how one gets the hash suffix and the other does
## not, and the one that does not silently merges two maps into one file.
##
## [b]An explicit alphabet, and not [method String.is_valid_identifier].[/b] That
## method answers "is this a legal GDScript identifier", and an identifier may not
## BEGIN with a digit — so on a single character it is false for every digit, and
## using it here replaced every digit in a map id with an underscore. In a genre
## whose maps are called [code]surf_kitsune2[/code] and [code]bhop_arcane_v3[/code]
## that is not a cosmetic bug: [code]surf_kitsune2[/code] and
## [code]surf_kitsune3[/code] both became [code]surf_kitsune_[/code] and shared one
## records file, silently, with two maps' times merged into one leaderboard.
##
## [b]The hash suffix is what makes a collision impossible[/b] rather than merely
## unlikely. Substitution is many-to-one by construction — any two ids differing only
## in characters this replaces map to the same string — so when sanitising changed
## anything, eight hex characters of the ORIGINAL id go on the end. Two different ids
## then always have different files, and an id that needed no substitution keeps its
## plain readable name, which is what a server operator looking in the directory
## wants.
static func safe_component(text: String) -> String:
	var out := ""

	for i in range(mini(text.length(), 96)):
		var c := text[i]
		out += c if SAFE_CHARS.contains(c) else "_"

	# A leading dot is the one surviving substitution that means something to a
	# filesystem: `..` is a directory and `.name` is hidden. Neither can traverse
	# once every separator has been replaced, but a records file nobody can see in
	# `ls` is a support question nobody enjoys.
	while out.begins_with("."):
		out = "_" + out.substr(1)

	if out == "":
		return "unnamed"

	if out == text:
		return out

	return "%s-%s" % [out, DotHash.sha256_text(text).substr(0, 8)]


## Reads a board off disk if it has not been read yet.
##
## [b]Lazy, per board.[/b] A server with four hundred maps installed would otherwise
## read four hundred files at boot to serve the one map it is running.
func _ensure_loaded(
	map_id: StringName, track: int, style_id: StringName, stage: int = 0
) -> void:
	var board := _key(map_id, track, style_id, stage)

	if _loaded.has(board):
		return

	_loaded[board] = true
	_read_board_file(path_for(map_id, track, style_id, stage))


func _read_board_file(path: String) -> void:
	if not FileAccess.file_exists(path):
		return

	var parsed: Variant = _read_json(path)

	if not (parsed is Dictionary):
		DotLog.warn(FILE_CHANNEL, "a records file is not a JSON object", {"path": path})
		return

	var rows_value: Variant = (parsed as Dictionary).get("records", [])

	if not (rows_value is Array):
		return

	for entry in (rows_value as Array):
		if entry is Dictionary:
			var record := DotTimerRecord.from_dictionary(entry)
			_loaded[record.board_key()] = true
			_insert_loaded(record)


## Reads every board on disk. What a profile, a points total or a "maps done" list
## needs, because each of those is a question about every board at once.
func _ensure_all_loaded() -> void:
	if _all_loaded:
		return
	_all_loaded = true

	var dir := DirAccess.open(directory)
	if dir == null:
		return

	for name in dir.get_files():
		if not name.ends_with(".json") or name.begins_with("_"):
			continue
		var path := directory.path_join(name)
		# A board already in memory may have unflushed changes; the file is older.
		var parsed: Variant = _read_json(path)
		if not (parsed is Dictionary):
			continue
		var data: Dictionary = parsed
		var board := DotTimerRecord.board_key_of(
			StringName(str(data.get("map", ""))), int(data.get("track", 0)),
			StringName(str(data.get("style", "normal"))), int(data.get("stage", 0))
		)
		if _loaded.has(board):
			continue
		_loaded[board] = true
		_read_board_file(path)


func _ensure_extras() -> void:
	if _extras_loaded:
		return
	_extras_loaded = true

	for name in EXTRAS:
		var parsed: Variant = _read_json(_extra_path(name))
		if not (parsed is Dictionary):
			continue
		var data: Dictionary = parsed
		match name:
			"players":
				for id in data:
					_players[StringName(id)] = data[id]
			"maps":
				for id in data:
					_maps[StringName(id)] = data[id]
			"progress":
				_progress = data
			"resume":
				_resume = data
			"history":
				var list: Variant = data.get("entries", [])
				if list is Array:
					for entry in list:
						if entry is Dictionary and entry.get("record") is Dictionary:
							var copy: Dictionary = (entry as Dictionary).duplicate()
							copy["record"] = DotTimerRecord.from_dictionary(entry["record"])
							_history.append(copy)


func _extra_path(name: String) -> String:
	return directory.path_join("_%s.json" % name)


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		DotLog.warn(FILE_CHANNEL, "could not open a records file", {"path": path})
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)


func _mark(record_or_parts: Variant) -> void:
	if record_or_parts is DotTimerRecord:
		var r: DotTimerRecord = record_or_parts
		_dirty[r.board_key()] = [r.map_id, r.track, r.style_id, r.stage]


# --- Boards ----------------------------------------------------------------

func put(record: DotTimerRecord) -> DotResult:
	if record == null:
		return DotResult.fail(DotError.CODE_INVALID, "No record to store.")

	_ensure_loaded(record.map_id, record.track, record.style_id, record.stage)
	_ensure_extras()

	var result := super.put(record)

	if result.ok:
		# A slower finish still changed the row: its completion count.
		_mark(record)
		if bool((result.value as Dictionary)["improved"]):
			_extras_dirty["history"] = true

	return result


func top(
	map_id: StringName, track: int, style_id: StringName,
	limit: int = 10, offset: int = 0, stage: int = 0
) -> DotResult:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.top(map_id, track, style_id, limit, offset, stage)


func best_for(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> DotResult:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.best_for(map_id, track, style_id, player_id, stage)


func rank_of(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> DotResult:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.rank_of(map_id, track, style_id, player_id, stage)


func rank_for_time(
	map_id: StringName, track: int, style_id: StringName,
	time: float, stage: int = 0
) -> DotResult:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.rank_for_time(map_id, track, style_id, time, stage)


func count_on(
	map_id: StringName, track: int, style_id: StringName, stage: int = 0
) -> DotResult:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.count_on(map_id, track, style_id, stage)


func remove(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> DotResult:
	_ensure_loaded(map_id, track, style_id, stage)

	var result := super.remove(map_id, track, style_id, player_id, stage)

	if result.ok and bool(result.value):
		_dirty[_key(map_id, track, style_id, stage)] = [map_id, track, style_id, stage]

	return result


func set_points(records: Array) -> DotResult:
	for record in records:
		if record is DotTimerRecord:
			_ensure_loaded(record.map_id, record.track, record.style_id, record.stage)
	var result := super.set_points(records)
	for record in records:
		if record is DotTimerRecord:
			_mark(record)
	return result


func records_of(player_id: StringName, filter: Dictionary = {}) -> DotResult:
	_ensure_all_loaded()
	return super.records_of(player_id, filter)


func records_on_map(map_id: StringName) -> DotResult:
	_ensure_all_loaded()
	return super.records_on_map(map_id)


func record_count(player_id: StringName, filter: Dictionary = {}) -> DotResult:
	_ensure_all_loaded()
	return super.record_count(player_id, filter)


func recent(limit: int = 20, filter: Dictionary = {}) -> DotResult:
	_ensure_extras()
	return super.recent(limit, filter)


func wipe_board(
	map_id: StringName, track: int, style_id: StringName, stage: int = -1
) -> DotResult:
	_ensure_all_loaded()
	var doomed: Array = []
	for board in _boards:
		var rows: Array = _boards[board]
		if rows.is_empty():
			continue
		var r: DotTimerRecord = rows[0]
		if r.map_id == map_id and r.track == track and r.style_id == style_id and (stage < 0 or r.stage == stage):
			doomed.append([r.map_id, r.track, r.style_id, r.stage])
	var result := super.wipe_board(map_id, track, style_id, stage)
	for parts in doomed:
		_delete_board_file(parts)
	return result


func wipe_player(player_id: StringName) -> DotResult:
	_ensure_all_loaded()
	_ensure_extras()
	var touched: Array = []
	for board in _rows:
		var found: Variant = (_rows[board] as Dictionary).get(player_id)
		if found is DotTimerRecord:
			touched.append(found)
	var result := super.wipe_player(player_id)
	for record in touched:
		_mark(record)
	for name in EXTRAS:
		_extras_dirty[name] = true
	return result


func wipe_map(map_id: StringName) -> DotResult:
	_ensure_all_loaded()
	_ensure_extras()
	var doomed: Array = []
	for board in _boards:
		var rows: Array = _boards[board]
		if not rows.is_empty() and (rows[0] as DotTimerRecord).map_id == map_id:
			var r: DotTimerRecord = rows[0]
			doomed.append([r.map_id, r.track, r.style_id, r.stage])
	var result := super.wipe_map(map_id)
	for parts in doomed:
		_delete_board_file(parts)
	for name in ["history", "progress", "maps"]:
		_extras_dirty[name] = true
	return result


func _delete_board_file(parts: Array) -> void:
	var path := path_for(parts[0], parts[1], parts[2], parts[3])
	_dirty.erase(_key(parts[0], parts[1], parts[2], parts[3]))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
		DotWeb.sync_filesystem()


# --- Side tables -----------------------------------------------------------

func note_player(
	player_id: StringName, name: String, seen_at: int, playtime_add: float = 0.0
) -> DotResult:
	_ensure_extras()
	_extras_dirty["players"] = true
	return super.note_player(player_id, name, seen_at, playtime_add)


func player_info(player_id: StringName) -> DotResult:
	_ensure_extras()
	return super.player_info(player_id)


func refresh_player_points(
	player_ids: Array, weighting: float = 1.0, limit: int = 0
) -> DotResult:
	_ensure_all_loaded()
	_ensure_extras()
	_extras_dirty["players"] = true
	return super.refresh_player_points(player_ids, weighting, limit)


func top_players(limit: int = 10, offset: int = 0) -> DotResult:
	_ensure_extras()
	return super.top_players(limit, offset)


func player_rank(player_id: StringName) -> DotResult:
	_ensure_extras()
	return super.player_rank(player_id)


func put_map(info: Dictionary) -> DotResult:
	_ensure_extras()
	_extras_dirty["maps"] = true
	return super.put_map(info)


func map_info(map_id: StringName) -> DotResult:
	_ensure_extras()
	return super.map_info(map_id)


func maps() -> DotResult:
	_ensure_extras()
	return super.maps()


func note_progress(
	player_id: StringName, map_id: StringName, track: int, style_id: StringName,
	attempts: int, seconds: float, finished: bool
) -> DotResult:
	_ensure_extras()
	_extras_dirty["progress"] = true
	return super.note_progress(player_id, map_id, track, style_id, attempts, seconds, finished)


func progress_for(
	player_id: StringName, map_id: StringName, track: int, style_id: StringName
) -> DotResult:
	_ensure_extras()
	return super.progress_for(player_id, map_id, track, style_id)


func save_resume(player_id: StringName, map_id: StringName, state: Dictionary) -> DotResult:
	_ensure_extras()
	_extras_dirty["resume"] = true
	return super.save_resume(player_id, map_id, state)


func take_resume(player_id: StringName, map_id: StringName) -> DotResult:
	_ensure_extras()
	_extras_dirty["resume"] = true
	return super.take_resume(player_id, map_id)


func peek_top(
	map_id: StringName, track: int, style_id: StringName,
	limit: int = 10, stage: int = 0
) -> Variant:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.peek_top(map_id, track, style_id, limit, stage)


func peek_best(
	map_id: StringName, track: int, style_id: StringName,
	player_id: StringName, stage: int = 0
) -> Variant:
	_ensure_loaded(map_id, track, style_id, stage)
	return super.peek_best(map_id, track, style_id, player_id, stage)


# --- Writing ---------------------------------------------------------------

## Whether anything changed since the last flush.
func has_pending() -> bool:
	return not _dirty.is_empty() or not _extras_dirty.is_empty()


func pending_count() -> int:
	return _dirty.size() + _extras_dirty.size()


## Writes up to [member flush_batch] dirty boards, then the side files.
##
## [b]Called by [DotTimerManager][/b] on its own interval and when it leaves the tree.
## Until 2026-10-08 nothing called it at all: a server configured with a records
## directory created this store, filed every record into its memory half, and wrote
## nothing — so every record was lost at the next restart, with no error, because a
## record in memory reads back exactly like a record on disk until the process ends.
func flush() -> DotResult:
	if not has_pending():
		return DotResult.success(0)

	var written := 0
	var attempted := 0
	var failures := PackedStringArray()

	for board in _dirty.keys():
		if attempted >= flush_batch:
			break

		attempted += 1

		var parts: Array = _dirty[board]
		var wrote := _write_board(parts[0], parts[1], parts[2], parts[3])

		if wrote.ok:
			_dirty.erase(board)
			written += 1
			continue

		failures.append("%s: %s" % [board, wrote.error.message])

	for name in _extras_dirty.keys():
		var wrote := _write_extra(name)
		if wrote.ok:
			_extras_dirty.erase(name)
			written += 1
		else:
			failures.append("_%s: %s" % [name, wrote.error.message])

	if written > 0:
		DotWeb.sync_filesystem()

	if not failures.is_empty():
		return DotResult.fail(
			DotError.CODE_IO,
			"Some record files could not be written.",
			", ".join(failures)
		)

	return DotResult.success(written)


func _write_board(
	map_id: StringName, track: int, style_id: StringName, stage: int = 0
) -> DotResult:
	var rows: Array = []

	for record in _board(map_id, track, style_id, stage):
		rows.append((record as DotTimerRecord).to_dictionary())

	return _write_json(path_for(map_id, track, style_id, stage), {
		"format": DotTimerRecord.FORMAT_VERSION,
		"map": String(map_id),
		"track": track,
		"style": String(style_id),
		"stage": stage,
		"records": rows,
	})


func _write_extra(name: String) -> DotResult:
	var data: Dictionary = {}
	match name:
		"players":
			for id in _players:
				data[String(id)] = _players[id]
		"maps":
			for id in _maps:
				data[String(id)] = _maps[id]
		"progress":
			data = _progress
		"resume":
			data = _resume
		"history":
			var entries: Array = []
			for entry in _history:
				var copy: Dictionary = entry.duplicate()
				copy["record"] = (entry["record"] as DotTimerRecord).to_dictionary()
				entries.append(copy)
			data = {"entries": entries}
	return _write_json(_extra_path(name), data)


## Writes to a temporary name and renames. A records file is the one thing on a timer
## server that cannot be regenerated, and a process killed mid-write must leave the
## previous version intact.
func _write_json(path: String, data: Dictionary) -> DotResult:
	# An empty directory makes every path relative, and a relative path resolves against
	# the process's working directory: a stray `_maps.json` in a game's project root
	# (game-g2gfast, 2026-10-08). "No files" is a memory store, never this one.
	if directory.strip_edges() == "":
		return DotResult.failure(DotError.from_engine(ERR_INVALID_PARAMETER, "DotTimerStoreFile.directory is empty"))
	if not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return DotResult.failure(DotError.from_engine(made, directory))

	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)

	if file == null:
		return DotResult.failure(
			DotError.from_engine(FileAccess.get_open_error(), temporary)
		)

	file.store_string(JSON.stringify(data, "  "))
	file.close()

	var renamed := DirAccess.rename_absolute(temporary, path)

	if renamed != OK:
		return DotResult.failure(DotError.from_engine(renamed, path))

	return DotResult.success(null)


func describe() -> Dictionary:
	var out := super.describe()
	out["directory"] = directory
	out["dirty"] = pending_count()
	out["loaded_boards"] = _loaded.size()
	return out
