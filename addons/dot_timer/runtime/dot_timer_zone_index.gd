class_name DotTimerZoneIndex
extends RefCounted

## Answers "which zones is this point in" fast enough to ask thirty times a tick.
##
## [b]Why not just loop over the list.[/b] A busy surf map has forty to a hundred
## zones, a server has thirty players, and this is asked once per player per tick at
## 128 Hz — a hundred and twenty thousand box tests a second, before anything else in
## the tick has run. A uniform grid over the map's extent turns that into a handful.
##
## The grid is uniform rather than a BVH deliberately: zones are large, few, mostly
## axis-aligned and never move, which is the case a uniform grid is best at and the
## case a tree's build cost is least justified by.
##
## [b]Rebuilt whenever the set changes, never mutated in place.[/b] An index that
## tracked edits would have to be correct under a mapper deleting a zone mid-frame
## while a player is inside it; rebuilding takes under a millisecond for a hundred
## zones and removes the entire class of question.

const CHANNEL := "timer.index"

## Edge length of a grid cell, in metres.
##
## Sized for zones rather than for players: a surf map's start box is a few metres
## across and its stage zones tens, so eight metres puts most zones in one to a few
## cells. Too small and a big zone is written into hundreds of cells; too large and
## every query returns the whole map.
const CELL_SIZE := 8.0

## Cells a single zone may occupy before it is treated as covering everything.
##
## A map-wide gravity volume is a legitimate thing to draw and would otherwise be
## written into tens of thousands of cells, which costs more memory than the map. Past
## this it goes on a short "always test" list instead.
const MAX_CELLS_PER_ZONE := 512

var zone_set: DotTimerZoneSet = null

## Cell key -> array of zone indices.
var _cells: Dictionary = {}

## Zones too large to bucket, tested on every query.
var _everywhere: Array[DotTimerZone] = []

## Point-kind zones, which are never "contained" and are indexed separately.
var _points: Array[DotTimerZone] = []


static func of(set: DotTimerZoneSet) -> DotTimerZoneIndex:
	var index := DotTimerZoneIndex.new()
	index.rebuild(set)
	return index


func rebuild(set: DotTimerZoneSet) -> void:
	zone_set = set
	_cells.clear()
	_everywhere.clear()
	_points.clear()

	if set == null:
		return

	for zone in set.zones:
		if zone.is_point_kind():
			_points.append(zone)
			continue

		var low := _cell_of(zone.from if zone.shape == DotTimerZone.Shape.BOX
			else zone.from - Vector3.ONE * zone.number)
		var high := _cell_of(zone.to if zone.shape == DotTimerZone.Shape.BOX
			else zone.from + Vector3.ONE * zone.number)

		var span := (
			(high.x - low.x + 1) * (high.y - low.y + 1) * (high.z - low.z + 1)
		)

		if span <= 0 or span > MAX_CELLS_PER_ZONE:
			_everywhere.append(zone)
			continue

		for x in range(low.x, high.x + 1):
			for y in range(low.y, high.y + 1):
				for z in range(low.z, high.z + 1):
					var key := _key(x, y, z)
					if not _cells.has(key):
						_cells[key] = []
					(_cells[key] as Array).append(zone)


static func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(
		int(floor(point.x / CELL_SIZE)),
		int(floor(point.y / CELL_SIZE)),
		int(floor(point.z / CELL_SIZE))
	)


## A cell key.
##
## A [Vector3i] would work and allocates; this is called several times per player per
## tick and an int key does not.
static func _key(x: int, y: int, z: int) -> int:
	# Large primes so three small coordinates do not collide with each other's
	# neighbours. Collisions are correctness-safe — a wrong bucket only means a zone
	# is tested that does not contain the point, and `contains` decides — but a
	# systematic collision would put half the map in one bucket.
	return x * 73856093 ^ y * 19349663 ^ z * 83492791


## Every zone containing [param point], in the set's own order.
##
## [b]The set's order, not the grid's.[/b] Two overlapping zones of the same kind is
## a mapper's mistake, and which of them wins should be the same on the client and on
## the server — so the answer is ordered by the file, which both machines load
## identically, rather than by a hash whose bucket order is a property of the process.
func zones_at(point: Vector3, out: Array[DotTimerZone]) -> void:
	out.clear()

	if zone_set == null:
		return

	var cell := _cell_of(point)
	var bucket: Variant = _cells.get(_key(cell.x, cell.y, cell.z))

	if bucket is Array:
		for zone in (bucket as Array):
			if (zone as DotTimerZone).contains(point):
				out.append(zone)

	for zone in _everywhere:
		if zone.contains(point):
			out.append(zone)

	if out.size() > 1:
		out.sort_custom(
			func(a: DotTimerZone, b: DotTimerZone) -> bool: return a.id < b.id
		)


## The first zone of a kind containing [param point], or null.
func first_at(point: Vector3, kind: DotTimerZone.Kind) -> DotTimerZone:
	var found: Array[DotTimerZone] = []
	zones_at(point, found)

	for zone in found:
		if zone.kind == kind:
			return zone

	return null


## The spawn point for a track, or null.
func spawn_for(track: int) -> DotTimerZone:
	for zone in _points:
		if zone.kind == DotTimerZone.Kind.SPAWN and zone.track == track:
			return zone
	return null


func describe() -> Dictionary:
	return {
		"zones": zone_set.zones.size() if zone_set != null else 0,
		"cells": _cells.size(),
		"everywhere": _everywhere.size(),
		"points": _points.size(),
	}
