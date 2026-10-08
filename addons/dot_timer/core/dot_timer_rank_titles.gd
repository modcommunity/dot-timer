class_name DotTimerRankTitles
extends RefCounted

## The name a player's standing earns them — the title beside their name in chat and on
## the scoreboard.
##
## [b]Data, not code.[/b] Every community names its ladder differently and moves the
## boundaries as it grows, so a ladder is a list a server loads from a file:
##
## [codeblock]
## [
##     {"title": "Record Holder", "colour": "#ffd700", "rank": [1, 1]},
##     {"title": "Elite",         "colour": "#ff7f50", "rank": [2, 10]},
##     {"title": "Top 5%",        "colour": "#7fc8ff", "percent": [0, 5]},
##     {"title": "Regular",       "colour": "#9ccc65", "points": [1000, 0]},
##     {"title": "Newcomer",      "colour": "#bdbdbd", "points": [1, 0]},
##     {"title": "Unranked",      "colour": "#757575", "points": [0, 0]}
## ]
## [/codeblock]
##
## Each entry has exactly one requirement: a [code]rank[/code] range, a
## [code]percent[/code] range (of ranked players; 0 is the top), or a [code]points[/code]
## range, where an upper bound of 0 means "and above". [b]The first match wins[/b], so
## the list is read top to bottom like the ladder it draws — which is what lets "Record
## Holder" sit above a points band that would also contain them.

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
