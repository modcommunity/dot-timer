class_name DotTimerStoreSqlSpecs
extends RefCounted
## The dot-sql table specs of DotTimerStoreSql, split out so the store keeps to the size gate.


## The tables, as dot-sql specs. Every one is keyed so its hottest query is an index
## range scan: a board by time, a player's records, the latest history.
static func specs(prefix: String) -> Array:
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
			"name": prefix + "records",
			"columns": record_columns,
			"primary_key": ["map", "track", "style", "stage", "player"],
			"indexes": [
				# The board, in time order: the record, the top ten, a rank by COUNT.
				{"name": "board", "columns": ["map", "track", "style", "stage", "time"]},
				# A player's own records: a profile, a points total.
				{"name": "player", "columns": ["player", "stage", "points"]},
			],
		},
		_history_spec(prefix),
		_players_spec(prefix),
		_maps_spec(prefix),
		_progress_spec(prefix),
		_resume_spec(prefix),
	]


static func _history_spec(prefix: String) -> Dictionary:
	return {
		"name": prefix + "history",
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
	}


static func _players_spec(prefix: String) -> Dictionary:
	return {
		"name": prefix + "players",
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
	}


static func _maps_spec(prefix: String) -> Dictionary:
	return {
		"name": prefix + "maps",
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
	}


static func _progress_spec(prefix: String) -> Dictionary:
	return {
		"name": prefix + "progress",
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
	}


static func _resume_spec(prefix: String) -> Dictionary:
	return {
		"name": prefix + "resume",
		"columns": [
			{"name": "player", "type": "key", "null": false},
			{"name": "map", "type": "key", "null": false},
			{"name": "state", "type": "json"},
			{"name": "saved_at", "type": "bigint", "null": false, "default": 0},
		],
		"primary_key": ["player", "map"],
	}
