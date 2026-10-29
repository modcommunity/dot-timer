class_name DotTimerRankTitles
extends RefCounted

## The name a player's standing earns them, as a ladder loaded from a list of entries.
## Each entry has one requirement: [code]rank[/code], [code]percent[/code] or [code]points[/code] range (upper 0 = and above); the first match wins.

var entries: Array[Dictionary] = []


static func from_array(list: Array) -> DotTimerRankTitles:
	var titles := DotTimerRankTitles.new()
	for entry in list:
		if entry is Dictionary and (entry as Dictionary).has("title"):
			titles.entries.append((entry as Dictionary).duplicate(true))
	return titles


## A ladder that works without configuration: a handful of neutral names.
static func defaults() -> DotTimerRankTitles:
	return from_array([
		{"title": "Record Holder", "colour": "#ffd54f", "rank": [1, 1]},
		{"title": "Elite", "colour": "#ff8a65", "rank": [2, 10]},
		{"title": "Expert", "colour": "#ba68c8", "percent": [0, 5]},
		{"title": "Skilled", "colour": "#4fc3f7", "percent": [5, 20]},
		{"title": "Regular", "colour": "#81c784", "points": [1, 0]},
		{"title": "Unranked", "colour": "#9e9e9e", "points": [0, 0]},
	])


## The entry for a player at [param rank] of [param total] ranked players, holding
## [param points]. An empty dictionary when nothing matches.
func title_for(rank: int, total: int, points: float) -> Dictionary:
	for entry in entries:
		if entry.has("rank"):
			var r: Array = entry["rank"]
			if rank > 0 and rank >= int(r[0]) and rank <= int(r[1]):
				return entry
		elif entry.has("percent"):
			if rank <= 0 or total <= 0:
				continue
			var p: Array = entry["percent"]
			var share := 100.0 * float(rank) / float(total)
			if share > float(p[0]) and share <= float(p[1]):
				return entry
		elif entry.has("points"):
			var b: Array = entry["points"]
			var lo := float(b[0])
			var hi := float(b[1])
			# [0, 0] is "no points at all" — the unranked band — rather than "0 and
			# above", which would swallow everybody below it in the list.
			if lo <= 0.0 and hi <= 0.0:
				if points <= 0.0:
					return entry
			elif points >= lo and (hi <= 0.0 or points <= hi):
				return entry
	return {}


func describe() -> Dictionary:
	return {"titles": entries.size()}
