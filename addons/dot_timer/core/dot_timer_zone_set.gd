@tool
class_name DotTimerZoneSet
extends Resource

## Every zone in one map, and the file a mapper hands round.
##
## [b]This is the artefact the genre runs on.[/b] Surf and bhop maps are made by
## people who are not the server operators: a map ships as geometry, and somebody
## then stands in it with a console open and draws the start and finish. That file is
## traded, corrected, and re-traded — the community timers' [code]zones.json[/code]
## does this and
## communities have shared them for years. So the format here is plain JSON, is
## readable, is hand-editable, and carries the map name and a hash so a server can
## tell whether the zones it holds were drawn for the map it loaded.
##
## [codeblock]
## var set := DotTimerZoneSet.new()
## set.map_id = &"surf_beginner"
## set.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(a, b))
## set.save_json("user://zones/surf_beginner.json")
## [/codeblock]
##
## [b]The set is authoritative on the server and advisory on a client.[/b] A client
## needs the zones to draw them and to predict its own crossing; only the server's
## copy decides a record. See [DotTimer].

const CHANNEL := "timer.zones"

## Format version written into every file.
##
## Bumped when the meaning of a field changes, never when one is added — a reader
## that ignores an unknown key already handles an addition, and refusing a file for
## one is how a mapper's afternoon is wasted.
const FORMAT_VERSION := 1

## The map these zones were drawn for.
##
## Not a file path. A map is content that may be delivered, mounted and versioned by
## dot-cloud, so its identity is an id and its path is a deployment detail.
@export var map_id: StringName = &""

@export var zones: Array[DotTimerZone] = []

## Free-form notes: who drew them, when, what changed.
@export var meta: Dictionary = {}

## Next id to hand out. Monotonic, never reused.
##
## Reusing the id of a deleted zone means a replay's crossing marks, an editor's undo
## stack and a moderator's "zone 12 is wrong" all point at a different volume than
## they did — a silent corruption whose only symptom is somebody's complaint no longer
## making sense.
@export var next_id: int = 1


func add(zone: DotTimerZone) -> DotTimerZone:
	if zone == null:
		return null

	if zone.id <= 0:
		zone.id = next_id
		next_id += 1
	elif zone.id >= next_id:
		next_id = zone.id + 1

	zones.append(zone)
	return zone


func remove_id(id: int) -> bool:
	for i in range(zones.size()):
		if zones[i].id == id:
			zones.remove_at(i)
			return true
	return false


func get_zone(id: int) -> DotTimerZone:
	for zone in zones:
		if zone.id == id:
			return zone
	return null


func clear() -> void:
	zones.clear()
	next_id = 1


## Every zone of one kind on one track. [param track] of -1 means any.
func of_kind(kind: DotTimerZone.Kind, track: int = -1) -> Array[DotTimerZone]:
	var out: Array[DotTimerZone] = []

	for zone in zones:
		if zone.kind == kind and (track < 0 or zone.track == track):
			out.append(zone)

	return out


## The first zone of a kind on a track, or null.
func first_of_kind(kind: DotTimerZone.Kind, track: int) -> DotTimerZone:
	for zone in zones:
		if zone.kind == kind and zone.track == track:
			return zone
	return null


## Tracks that have both a start and an end, in ascending order.
##
## [b]Both, and that is the point of the method.[/b] A track with a start and no
## finish is the most common thing wrong with a hand-drawn zone file: it is playable,
## the timer starts, and nobody can ever complete it. Listing only the tracks that can
## actually be run means a map with a broken bonus offers the main track rather than
## offering a bonus that silently cannot be finished.
func playable_tracks() -> PackedInt32Array:
	var out := PackedInt32Array()

	for track in range(DotTimerTrack.COUNT):
		if (
			first_of_kind(DotTimerZone.Kind.START, track) != null
			and first_of_kind(DotTimerZone.Kind.END, track) != null
		):
			out.append(track)

	return out


## Highest stage number on a track. 0 when the track has no stages.
func stage_count(track: int) -> int:
	var highest := 0

	for zone in zones:
		if zone.kind == DotTimerZone.Kind.STAGE and zone.track == track:
			highest = maxi(highest, int(zone.number))

	return highest


# --- Validation ------------------------------------------------------------

## Problems that make the set unusable. Empty means it is fine.
##
## Returns every problem rather than the first: a mapper who has drawn forty zones
## wants the list, not forty rounds of save-and-retry.
func problems() -> PackedStringArray:
	var out := PackedStringArray()
	var seen_ids := {}

	for zone in zones:
		var valid := zone.validate()
		if not valid.ok:
			out.append("zone #%d: %s" % [zone.id, valid.error.message])

		if seen_ids.has(zone.id):
			out.append("zone id %d is used more than once" % zone.id)
		seen_ids[zone.id] = true

	for track in range(DotTimerTrack.COUNT):
		var starts := of_kind(DotTimerZone.Kind.START, track)
		var ends := of_kind(DotTimerZone.Kind.END, track)

		if starts.size() > 1:
			out.append(
				"%s has %d start zones; a track may have one"
				% [DotTimerTrack.name_of(track), starts.size()]
			)

		if ends.size() > 1:
			out.append(
				"%s has %d end zones; a track may have one"
				% [DotTimerTrack.name_of(track), ends.size()]
			)

		if starts.size() == 1 and ends.is_empty():
			out.append(
				"%s has a start and no end, so it can be begun and never finished"
				% DotTimerTrack.name_of(track)
			)

		if ends.size() == 1 and starts.is_empty():
			out.append(
				"%s has an end and no start" % DotTimerTrack.name_of(track)
			)

		# Stages must be 1..n with no gaps. A missing stage 3 means every player's
		# splits are numbered differently from the map's own signage.
		var stages := of_kind(DotTimerZone.Kind.STAGE, track)
		var numbers := {}

		for zone in stages:
			var n := int(zone.number)
			if numbers.has(n):
				out.append(
					"%s has two stage zones numbered %d"
					% [DotTimerTrack.name_of(track), n]
				)
			numbers[n] = true

		for n in range(1, stages.size() + 1):
			if not numbers.has(n):
				out.append(
					"%s is missing stage %d" % [DotTimerTrack.name_of(track), n]
				)

	return out


## Zones thin enough that a fast player can pass through one in a single tick.
##
## [b]Advisory, and the first thing to check when a zone "does not work".[/b] At
## 128 Hz a player at 30 m/s covers 23 cm per tick, and at 64 Hz nearly half a metre.
## A finish volume thinner than that is not sampled on any tick the player is inside
## it, so the run simply never ends — for the fast players only, which is exactly the
## population that notices.
func thin_zones(fastest_speed: float, tick_rate: int) -> Array[DotTimerZone]:
	var per_tick := fastest_speed / maxf(float(tick_rate), 1.0)
	var out: Array[DotTimerZone] = []

	for zone in zones:
		if zone.is_point_kind():
			continue
		if zone.min_thickness() < per_tick:
			out.append(zone)

	return out


# --- Serialisation ---------------------------------------------------------

func to_dictionary() -> Dictionary:
	var list: Array = []

	for zone in zones:
		list.append(zone.to_dictionary())

	return {
		"format": FORMAT_VERSION,
		"map": String(map_id),
		"next_id": next_id,
		"meta": meta,
		"zones": list,
	}


## A hash of the zones themselves, ignoring notes and ids.
##
## [b]What a records table is keyed against, and why it excludes the notes.[/b] Moving
## a finish line invalidates every record on the map; correcting a mapper's comment
## does not. A hash over the whole file would throw away a leaderboard for a typo fix,
## and a records system that punishes tidying up is one nobody tidies up.
func fingerprint() -> String:
	var parts := PackedStringArray()
	var sorted := zones.duplicate()

	# Sorted by a stable key rather than by id, so re-drawing a zone that ends up in
	# the same place produces the same fingerprint and does not orphan the records.
	sorted.sort_custom(func(a: DotTimerZone, b: DotTimerZone) -> bool:
		if a.track != b.track:
			return a.track < b.track
		if a.kind != b.kind:
			return a.kind < b.kind
		return a.from.x < b.from.x
	)

	for zone in sorted:
		parts.append("%d/%d/%d/%.3f,%.3f,%.3f/%.3f,%.3f,%.3f/%.3f" % [
			zone.track, zone.kind, zone.shape,
			zone.from.x, zone.from.y, zone.from.z,
			zone.to.x, zone.to.y, zone.to.z,
			zone.number,
		])

	return DotHash.sha256_text("|".join(parts)).substr(0, 16)


func to_json(pretty: bool = true) -> String:
	return JSON.stringify(to_dictionary(), "  " if pretty else "")


static func from_dictionary(data: Dictionary) -> DotResult:
	var format := int(data.get("format", 0))

	if format > FORMAT_VERSION:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"These zones were written by a newer version of dot-timer.",
			"format %d, this build reads %d" % [format, FORMAT_VERSION]
		)

	var set := DotTimerZoneSet.new()
	set.map_id = StringName(str(data.get("map", "")))

	var meta_value: Variant = data.get("meta", {})
	set.meta = meta_value if meta_value is Dictionary else {}

	var list_value: Variant = data.get("zones", [])

	if not (list_value is Array):
		return DotResult.fail(
			DotError.CODE_PARSE, "The zones key is not a list."
		)

	var list: Array = list_value

	for entry in list:
		if entry is Dictionary:
			set.add(DotTimerZone.from_dictionary(entry))

	# After the zones, so a file whose next_id is behind its contents is repaired
	# rather than made to hand out ids that already exist.
	set.next_id = maxi(int(data.get("next_id", 1)), set.next_id)

	return DotResult.success(set)


static func from_json(text: String) -> DotResult:
	var parsed: Variant = JSON.parse_string(text)

	if not (parsed is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "A zone file must be a JSON object."
		)

	return from_dictionary(parsed)


static func load_json(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(
			DotError.CODE_IO, "No zone file there.", path
		)

	var file := FileAccess.open(path, FileAccess.READ)

	if file == null:
		return DotResult.failure(
			DotError.from_engine(FileAccess.get_open_error(), path)
		)

	var text := file.get_as_text()
	file.close()

	var loaded := from_json(text)

	if not loaded.ok:
		return loaded.wrap("Could not read %s." % path)

	return loaded


func save_json(path: String) -> DotResult:
	var directory := path.get_base_dir()

	if directory != "" and not DirAccess.dir_exists_absolute(directory):
		var made := DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return DotResult.failure(DotError.from_engine(made, directory))

	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		return DotResult.failure(
			DotError.from_engine(FileAccess.get_open_error(), path)
		)

	file.store_string(to_json())
	file.close()

	# The browser mirrors user:// into IndexedDB and does not flush on close. Every
	# write path in this family calls this; a zone file that vanishes when the tab is
	# closed is the failure it prevents.
	DotWeb.sync_filesystem()

	return DotResult.success(null)


func describe() -> Dictionary:
	var counts := {}

	for zone in zones:
		var key := DotTimerZone.kind_name(zone.kind)
		counts[key] = int(counts.get(key, 0)) + 1

	return {
		"map": String(map_id),
		"zones": zones.size(),
		"tracks": str(playable_tracks()),
		"kinds": counts,
		"fingerprint": fingerprint(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("map          %s" % String(map_id))
	out.append("zones        %d" % zones.size())
	out.append("tracks       %s" % str(playable_tracks()))
	out.append("fingerprint  %s" % fingerprint())

	for problem in problems():
		out.append("PROBLEM      %s" % problem)

	return out


func _to_string() -> String:
	return "DotTimerZoneSet(%s, %d zones)" % [String(map_id), zones.size()]
