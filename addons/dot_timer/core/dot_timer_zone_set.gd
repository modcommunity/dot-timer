@tool
class_name DotTimerZoneSet
extends Resource

## Every zone in one map, and the file a mapper hands round: plain, hand-editable JSON carrying the map name and a hash.
## Authoritative on the server, advisory on a client (which needs the zones only to draw them and predict). See [DotTimer].

# No log channel: the document a mapper trades. Loading and saving return a DotResult
# and problems() returns strings; DotTimerManager logs both, with the map it was loading.

## Format version written into every file.
## Bumped when a field's meaning changes, never when one is added: a reader that ignores unknown keys already handles additions.
const FORMAT_VERSION := 1

## The map these zones were drawn for.
## An id, not a file path: a map may be delivered, mounted and versioned by dot-cloud, so its path is a deployment detail.
@export var map_id: StringName = &""

@export var zones: Array[DotTimerZone] = []

## Free-form notes: who drew them, when, what changed.
@export var meta: Dictionary = {}

## Next id to hand out. Monotonic, never reused.
## A reused id would make a replay's crossing marks, an undo stack and a moderator's "zone 12 is wrong" point at a different volume.
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
## A start with no finish is the commonest hand-drawn mistake: playable, the timer starts, and nobody can complete it.
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


## The stage zone numbered [param number] on [param track], or null.
## What "go to stage 3" resolves against: this lookup plus the zone's [member DotTimerZone.destination].
func stage_zone(track: int, number: int) -> DotTimerZone:
	for zone in zones:
		if (
			zone.kind == DotTimerZone.Kind.STAGE
			and zone.track == track
			and int(zone.number) == number
		):
			return zone

	return null



## Problems that make the set unusable. Empty means it is fine.
## Returns every problem, not the first: a mapper with forty zones wants the list, not forty save-and-retry rounds.
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

		out.append_array(_stage_problems(track))

	return out


## Stages must be 1..n with no gaps. A missing stage 3 means every player's splits are
## numbered differently from the map's own signage.
func _stage_problems(track: int) -> PackedStringArray:
	var out := PackedStringArray()
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



## The [member meta] key a map declares its pitless routes under: a list of tracks.
## Data, so the declaration travels with the zone file to every server and is visible to the next editor.
const PITLESS_TRACKS_KEY := "pitless_tracks"


## Tracks that are routes: any track with a START, an END or a STAGE on it, ascending.
## Not "any track with a zone": a track with only a SPAWN is somewhere a player stands, not a route.
func route_tracks() -> PackedInt32Array:
	var seen := {}

	for zone in zones:
		if zone.kind in [
			DotTimerZone.Kind.START, DotTimerZone.Kind.END, DotTimerZone.Kind.STAGE
		] and DotTimerTrack.is_valid(zone.track):
			seen[zone.track] = true

	var out := PackedInt32Array()

	for track in range(DotTimerTrack.COUNT):
		if seen.has(track):
			out.append(track)

	return out


## The tracks this set declares have nothing to fall off. See [constant PITLESS_TRACKS_KEY].
func pitless_tracks() -> PackedInt32Array:
	var out := PackedInt32Array()
	var listed: Variant = meta.get(PITLESS_TRACKS_KEY, [])

	# JSON hands every number back as a float, so a file that round-tripped says 3.0.
	if listed is Array or listed is PackedInt32Array:
		for value: Variant in listed:
			if (value is int or value is float) and not out.has(int(value)):
				out.append(int(value))

	out.sort()
	return out


## What each route on this map is missing. Empty means every route can be spawned onto, begun, finished and fallen off of.
## Per track, which [method problems] is not; separate from it so a half-drawn bonus can still be saved.
func route_problems() -> PackedStringArray:
	var out := PackedStringArray()
	var routes := route_tracks()
	var pitless := pitless_tracks()

	for track in routes:
		var name := DotTimerTrack.name_of(track)

		for kind in [
			DotTimerZone.Kind.START, DotTimerZone.Kind.END, DotTimerZone.Kind.SPAWN
		]:
			if first_of_kind(kind, track) == null:
				out.append(
					"%s is a route with no %s zone"
					% [name, DotTimerZone.kind_name(kind).to_lower()]
				)

		var has_pit := first_of_kind(DotTimerZone.Kind.RESPAWN, track) != null

		if not has_pit and not pitless.has(track):
			out.append(
				"%s has no respawn zone, so a player who falls off it falls for ever "
				% name
				+ "(the other tracks' pits do not catch them; list it under meta.%s "
				% PITLESS_TRACKS_KEY
				+ "if it truly cannot be fallen off)"
			)

		if has_pit and pitless.has(track):
			out.append(
				"%s is declared pitless and has a respawn zone; one of them is stale"
				% name
			)

		out.append_array(_stage_problems(track))

	for track in pitless:
		if not routes.has(track):
			out.append(
				"%s is declared pitless and is not a route on this map"
				% DotTimerTrack.name_of(track)
			)

	return out


## Zones thin enough that a fast player can pass through one in a single tick. Advisory.
## [code]fastest_fall_speed[/code] judges the Y extent; zero means the same as [code]fastest_speed[/code]. See [method DotTimerZone.is_thin_for].
func thin_zones(
	fastest_speed: float,
	tick_rate: int,
	fastest_fall_speed: float = 0.0
) -> Array[DotTimerZone]:
	var ticks := maxf(float(tick_rate), 1.0)
	var per_tick := fastest_speed / ticks
	var fall_per_tick := (
		fastest_fall_speed / ticks if fastest_fall_speed > 0.0 else per_tick
	)
	var out: Array[DotTimerZone] = []

	for zone in zones:
		if zone.is_point_kind():
			continue
		if zone.is_thin_for(per_tick, fall_per_tick):
			out.append(zone)

	return out



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


## A hash of the zones themselves, ignoring notes and ids: what a records table is keyed against.
## Moving a finish line invalidates every record; correcting a comment must not.
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

	for problem in route_problems():
		out.append("INCOMPLETE   %s" % problem)

	return out


func _to_string() -> String:
	return "DotTimerZoneSet(%s, %d zones)" % [String(map_id), zones.size()]
