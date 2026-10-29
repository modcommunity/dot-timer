class_name DotTimerZoneIndex
extends RefCounted

## Answers "which zones is this point in" fast enough to ask thirty times a tick, with a uniform grid over the map.
## Rebuilt whenever the set changes, never mutated in place.

# No log channel: a derived lookup, rebuilt from a zone set and asked thirty times a
# tick. It cannot fail, and what is wrong with the zones it indexes is reported by
# DotTimerZoneSet.problems(), which the manager logs on load.

## Edge length of a grid cell, in metres.
## Sized for zones: too small writes a big zone into hundreds of cells, too large makes every query return the whole map.
const CELL_SIZE := 8.0

## Cells a single zone may occupy before it is treated as covering everything.
## A map-wide volume would otherwise take tens of thousands of cells; past this it goes on an "always test" list.
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


## A cell key. An int rather than a [Vector3i], which allocates and is asked several times per player per tick.
static func _key(x: int, y: int, z: int) -> int:
	# Large primes keep neighbouring cells apart; a collision only tests a zone that does not contain the point, but a systematic one would fill a bucket.
	return x * 73856093 ^ y * 19349663 ^ z * 83492791


## Every zone containing [param point], in the set's own order.
## The file's order, not the grid's, so overlapping zones resolve identically on client and server.
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
