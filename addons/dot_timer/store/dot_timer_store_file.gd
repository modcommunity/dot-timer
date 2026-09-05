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
## [b]Not for a server with thousands of players.[/b] It reads a whole board to answer
## a query and writes a whole board to file a record, which is correct and is O(board).
## Past a few thousand rows per board, subclass [DotTimerStore] against a database —
## the interface is the same and nothing above it changes.

const FILE_CHANNEL := "timer.store.file"

## Where the boards live. Created on first write.
var directory: String = "user://records"

## Boards written per [method flush] before the rest wait for the next one.
##
## Bounded because a map change can dirty every board on the map at once, and writing
## forty files inside one frame is a stall a player feels. What is left stays dirty
## and goes on the next flush.
var flush_batch: int = 16

## Boards changed since the last flush.
var _dirty: Dictionary = {}

## Whether a board has been read off disk yet.
var _loaded: Dictionary = {}


static func at(path: String) -> DotTimerStoreFile:
	var store := DotTimerStoreFile.new()
	store.directory = path
	return store


## The file a board lives in.
##
## [b]Every component is sanitised, not just checked.[/b] A map id arrives from a
## content manifest and a style id from a config file, and either could contain a
## slash or a [code]..[/code] — which without this writes a records file wherever the
## attacker liked.
func path_for(map_id: StringName, track: int, style_id: StringName) -> String:
	return "%s/%s.%d.%s.json" % [
		directory.rstrip("/"),
		safe_component(String(map_id)),
		clampi(track, 0, DotTimerTrack.BONUS_LAST),
		safe_component(String(style_id)),
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
	map_id: StringName, track: int, style_id: StringName
) -> void:
	var board := _key(map_id, track, style_id)

	if _loaded.has(board):
		return

	_loaded[board] = true

	var path := path_for(map_id, track, style_id)

	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		DotLog.warn(FILE_CHANNEL, "could not open a records file", {"path": path})
		return

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)

	if not (parsed is Dictionary):
		DotLog.warn(FILE_CHANNEL, "a records file is not a JSON object", {"path": path})
		return

	var rows_value: Variant = (parsed as Dictionary).get("records", [])

	if not (rows_value is Array):
		return

	for entry in (rows_value as Array):
		if entry is Dictionary:
			# Through the in-memory put(), so a file with two rows for one player —
			# which a crash mid-write or a hand edit can produce — resolves to the
			# faster one rather than to whichever was last in the array.
			super.put(DotTimerRecord.from_dictionary(entry))


func put(record: DotTimerRecord) -> DotResult:
	if record == null:
		return DotResult.fail(DotError.CODE_INVALID, "No record to store.")

	_ensure_loaded(record.map_id, record.track, record.style_id)

	var result := super.put(record)

	if result.ok:
		_dirty[record.board_key()] = [record.map_id, record.track, record.style_id]

	return result


func top(
	map_id: StringName, track: int, style_id: StringName, limit: int = 10
) -> DotResult:
	_ensure_loaded(map_id, track, style_id)
	return super.top(map_id, track, style_id, limit)


func best_for(
	map_id: StringName, track: int, style_id: StringName, player_id: StringName
) -> DotResult:
	_ensure_loaded(map_id, track, style_id)
	return super.best_for(map_id, track, style_id, player_id)


func rank_of(
	map_id: StringName, track: int, style_id: StringName, player_id: StringName
) -> DotResult:
	_ensure_loaded(map_id, track, style_id)
	return super.rank_of(map_id, track, style_id, player_id)


func count_on(
	map_id: StringName, track: int, style_id: StringName
) -> DotResult:
	_ensure_loaded(map_id, track, style_id)
	return super.count_on(map_id, track, style_id)


func remove(
	map_id: StringName, track: int, style_id: StringName, player_id: StringName
) -> DotResult:
	_ensure_loaded(map_id, track, style_id)

	var result := super.remove(map_id, track, style_id, player_id)

	if result.ok and bool(result.value):
		_dirty[_key(map_id, track, style_id)] = [map_id, track, style_id]

	return result


## Whether anything is waiting to be written.
##
## For a host deciding whether to keep flushing before it shuts down.
func has_pending() -> bool:
	return not _dirty.is_empty()


func pending_count() -> int:
	return _dirty.size()


## Writes up to [member flush_batch] changed boards. Call after a run, and at shutdown.
##
## [b]Batched rather than written on every put.[/b] Two players finishing in the same
## second is normal and would otherwise be two full rewrites of the same file.
##
## Returns how many boards were written. A non-zero [method pending_count] afterwards
## means the batch was reached and another call is due.
func flush() -> DotResult:
	if _dirty.is_empty():
		return DotResult.success(0)

	var written := 0
	var attempted := 0
	var failures := PackedStringArray()

	# A copy of the keys, because the loop erases from the dictionary it is walking.
	# Iterating a Dictionary while erasing from it skips entries, which here would
	# leave a board marked clean that was never written.
	var pending: Array = _dirty.keys()

	for board in pending:
		# Budgeted on ATTEMPTS, not successes. Budgeting on successes lets a
		# permanently failing board be retried for ever inside one flush while
		# nothing else gets written.
		if attempted >= flush_batch:
			break

		attempted += 1

		var parts: Array = _dirty[board]
		var wrote := _write_board(parts[0], parts[1], parts[2])

		if wrote.ok:
			_dirty.erase(board)
			written += 1
			continue

		# Left dirty on failure, so it is retried on the next flush. That is the
		# difference between a full disk costing a retry and costing the records —
		# which are the one thing on a timer server that cannot be regenerated.
		failures.append("%s: %s" % [board, wrote.error.message])

	# The browser mirrors user:// into IndexedDB and does not flush on close. Once
	# per flush, not once per board: this is the expensive call.
	if written > 0:
		DotWeb.sync_filesystem()

	if not failures.is_empty():
		return DotResult.fail(
			DotError.CODE_IO,
			"Some record boards could not be written.",
			", ".join(failures)
		)

	return DotResult.success(written)


func _write_board(
	map_id: StringName, track: int, style_id: StringName
) -> DotResult:
	if not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return DotResult.failure(DotError.from_engine(made, directory))

	var listed := top(map_id, track, style_id, 1 << 30)

	if not listed.ok:
		return listed

	var rows: Array = []

	for record in (listed.value as Array):
		rows.append((record as DotTimerRecord).to_dictionary())

	var path := path_for(map_id, track, style_id)

	# Written to a temporary file and renamed, so a process killed mid-write leaves
	# the previous board intact rather than a truncated one. A records file is the
	# one thing on a timer server that cannot be regenerated.
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)

	if file == null:
		return DotResult.failure(
			DotError.from_engine(FileAccess.get_open_error(), temporary)
		)

	file.store_string(JSON.stringify({
		"format": DotTimerRecord.FORMAT_VERSION,
		"map": String(map_id),
		"track": track,
		"style": String(style_id),
		"records": rows,
	}, "  "))
	file.close()

	var renamed := DirAccess.rename_absolute(temporary, path)

	if renamed != OK:
		return DotResult.failure(DotError.from_engine(renamed, path))

	return DotResult.success(null)


func describe() -> Dictionary:
	var out := super.describe()
	out["directory"] = directory
	out["dirty"] = _dirty.size()
	out["loaded_boards"] = _loaded.size()
	return out
