@tool
class_name DotTimerManager
extends Node

## The component a game adds: a timer per player, the map's zones, the styles, the
## store and the replay recorder, joined up.
##
## [codeblock]
## var manager := DotTimerManager.new()
## manager.authoritative = true          # on the server only
## add_child(manager)
## manager.load_zones("res://maps/surf_beginner.zones.json")
##
## manager.add_player(&"p1", "Christian")
##
## # every simulated tick, per player
## manager.tick_player(&"p1", position, velocity, grounded, alive, yaw, pitch)
## [/codeblock]
##
## [b]One manager, many players — never one per player.[/b] A dedicated server runs
## thirty at once and they share the zones, the index, the styles and the store. A
## per-player node would rebuild the spatial index thirty times per map change and
## give thirty answers to "what is the record here".
##
## [b]No autoload, for the family's reason and for one of its own[/b]: a replay viewer
## runs a second manager over the same map at the same time, and a test runs several.

const CHANNEL := "timer.manager"

## A player's run finished. The record has NOT been filed yet — see
## [signal record_accepted].
signal player_finished(player_id: StringName, run: DotTimerRun)

signal player_started(player_id: StringName, run: DotTimerRun)

signal player_stopped(
	player_id: StringName, run: DotTimerRun, reason: StringName
)

signal player_staged(
	player_id: StringName, number: int, split_seconds: float
)

## A finished run cleared every rule and reached the store.
##
## [param previous] is the player's own best before this run, or null if they had
## none. [b]It is not necessarily slower[/b]: most finished runs are worse than the
## player's own record, the store keeps the better one, and the caller wants to know
## either way so it can say "personal best" or "+2.3 seconds". Compare with
## [method DotTimerRecord.beats] to tell them apart.
##
## [param rank] is the player's position on the board after the write, 1 for first.
signal record_accepted(
	record: DotTimerRecord, previous: DotTimerRecord, rank: int
)

## A finished run was NOT filed, and why.
##
## [b]Emitted, not swallowed.[/b] "I finished and nothing happened" is the single most
## common complaint on a timer server, and the reason is almost always one the player
## could have been told: an unranked style, a practice checkpoint, a time under the
## floor.
signal record_refused(player_id: StringName, run: DotTimerRun, reason: String)

## A zone asked for something only the game can do: a teleport, a respawn, a slay.
signal effect_requested(player_id: StringName, zone: DotTimerZone)

## The "while inside" zones in force for a player changed.
signal effects_changed(player_id: StringName, effects: Dictionary)

## A player asked to be put at a stage. [b]The host moves them.[/b]
##
## [param zone] carries [member DotTimerZone.destination] and
## [member DotTimerZone.destination_yaw]. The run is already stopped by the time this
## is emitted — see [method request_stage]. Emitted rather than acted on for the same
## reason [signal effect_requested] is: what "put the player here" means differs
## between a first-person game, a 2D game and a replay being scrubbed.
signal stage_requested(player_id: StringName, number: int, zone: DotTimerZone)

## The map's zones were replaced.
signal zones_changed(zones: DotTimerZoneSet)

## Everything a "you finished" message needs, once the run is filed. Emitted after
## [signal record_accepted], with more in it:
##
## [codeblock]
## {
##     "player": StringName, "record": DotTimerRecord,
##     "previous": DotTimerRecord or null,   # their best before
##     "previous_record": DotTimerRecord or null,  # the board's #1 before
##     "improved": bool, "first": bool,      # a new personal best; their first finish
##     "world_record": bool,                 # this run took first place
##     "rank": int, "total": int,            # where it stands now, of how many
##     "completions": int,                   # their finishes on this board
##     "points": float, "title": Dictionary, # what it is worth; their title now
## }
## [/codeblock]
signal run_filed(result: Dictionary)

## A finished run that was NOT filed, with the place it would have taken — the
## practice-mode finish, the unranked style, the run that used a checkpoint. "That
## would have been 4th" is worth saying even when nothing is kept.
signal practice_finished(player_id: StringName, run: DotTimerRun, would_be_rank: int, total: int, reason: String)

## A section of a staged map was filed as its own record. [param result] is shaped like
## [signal run_filed]'s.
signal section_filed(result: Dictionary)

## Leaving the start did not begin a run, and why.
signal start_refused(player_id: StringName, reason: String)

## The host should move a player: back to the start ([code]&"restart"[/code],
## [code]&"auto_restart"[/code]) or to the end ([code]&"end"[/code]). [param zone] is the
## track's SPAWN or END zone, or null if the map has none. The timer moves nobody.
signal teleport_requested(player_id: StringName, zone: DotTimerZone, why: StringName)

## These players' points totals were recomputed — a re-score after a record moved, a
## removal, a wipe. What a host re-reports a ranking board from: everybody's total can
## move when one record does, not only the finisher's.
signal points_changed(player_ids: Array)

## A returning player has a run they dropped, kept for them. The host offers it (or
## restores it straight away) with [method restore_player].
signal resume_available(player_id: StringName, state: Dictionary)

@export_group("Role")

## Whether this manager files records.
##
## [b]False on a client, and this is a security boundary rather than a preference.[/b]
## A client runs its own manager so its HUD updates on the tick instead of a round
## trip later; if that copy could file, a modified client would announce world
## records. The server's copy is the only one whose runs count.
@export var authoritative: bool = false

## Simulation ticks per second. Must match the host's movement loop.
##
## [b]Do not assign this at runtime — call [method set_tick_rate].[/b] Every run in
## progress is counting in the old rate, and changing the number under them
## reinterprets ticks already banked: a run half-simulated at 64 and half at 128
## produces a time that is neither, and files it without an error anywhere.
##
## On a server, prefer [method adopt_engine_tick_rate], which takes it from
## [member Engine.physics_ticks_per_second] — the value dot-server writes from its
## own [code]sv_tickrate[/code] cvar. One number, in [code]server.cfg[/code], with
## everything else.
@export_range(1, 1000, 1) var tick_rate: int = 128

## Optional layered configuration. Applied on ready, before anything else.
##
## Assign one to configure a timer server from a file, the environment or the command
## line rather than from exports on a node. See [DotTimerConfig].
@export var config: DotTimerConfig = null

@export_group("Content")

## A zone file to load on ready. Optional; [method load_zones] does the same at
## runtime.
@export var zones_path: String = ""

@export_group("Records")

## Whether finished runs are offered to the store at all.
@export var record_runs: bool = true

## Whether replays are recorded.
##
## Costs memory per player in a run, and most of it is thrown away — see
## [DotTimerReplayRecorder]. On by default because a timer without replays is half a
## timer, and off is the right answer for a server with thirty players and 256 MB.
@export var record_replays: bool = true

## Where kept replays are written. Empty keeps them in memory only.
##
## [b]Set from [member DotTimerConfig.replays_directory], and read by nothing until
## now.[/b] The recorder's memory cap was the same bug one field over — see
## [DotTimerReplayRecorder] — and this is the half that survived it: a server recorded
## every run, held the winner in [code]last_replay[/code], and lost it at exit. A
## records server that cannot show the world-record replay has the feature in name.
##
## Only replays of runs the store [i]kept[/i] are written, which is the same set
## [code]last_replay[/code] already survives to; a replay of a run nothing is keeping
## is a file nothing will ever open.
@export var replays_directory: String = ""

## Whether practice checkpoints exist at all on this server.
##
## [b]The server's switch, and it is not the style's.[/b]
## [member DotTimerStyle.allow_checkpoints] decides whether a run that used one may
## still be RANKED; this decides whether the feature is there. They are separate
## because a ranked style that took practice mode away would be a style nobody could
## learn the map on — which is the opposite of what a records server wants — while a
## competition server turning the whole feature off for an evening is a real thing
## somebody asks for.
@export var allow_checkpoints: bool = true

@export_group("Wiring")

## A [DotRegistry] name to find the store under, if it is published there.
##
## [b]A registry name rather than a [DotNodeRef][/b], which is the family's usual
## answer, because a [DotTimerStore] is a [RefCounted] and not a node — it is a
## database handle, and making it a node so it could be pointed at would put a
## connection pool in the scene tree. Left empty, [member store] is assigned directly,
## which is what a server that builds its own does.
@export var store_service: StringName = &""

## The map's zones.
var zones: DotTimerZoneSet = null

## Where records go. Null means runs are timed and nothing is filed.
var store: DotTimerStore = null

## Style definitions by id. See [method set_styles].
var styles: Dictionary = {}

## How records are scored and totalled. Set from [member DotTimerConfig.points_formula].
var points: DotTimerPoints = DotTimerPoints.new()

## What a player's standing is called. Replace with a ladder from a file.
var titles: DotTimerRankTitles = DotTimerRankTitles.defaults()

## Rules handed to every player's timer. See the same names on [DotTimer].
var enforce_stages: bool = true
var pause_rules: bool = true
var teleport_stop_distance: float = 0.0

## Seconds a dropped run is kept. See [member DotTimerConfig.resume_seconds].
var resume_seconds: float = 600.0

## Seconds between flushes of a batching store.
var flush_seconds: float = 5.0

## The map's tier, as an admin set it, overriding the zone file's. 0 = none set.
var _tier_override: int = 0

var _flush_elapsed: float = 0.0
var _last_flush_error_msec: int = 0

## Per-player state, by player id.
var _players: Dictionary = {}


## Everything one player needs. Kept together so adding a player is one allocation.
class Player extends RefCounted:
	var id: StringName = &""
	var display_name: String = ""
	var timer: DotTimer = null
	var sample: DotTimerSample = null
	var recorder: DotTimerReplayRecorder = null

	## The last finished run, kept so a caller can inspect it after the signal.
	var last_finished: DotTimerRun = null

	## The last replay produced, handed to whatever stores replays.
	var last_replay: DotTimerReplay = null
	## A kept record whose replay is still taking its run-out: written when it is done.
	var pending_replay_record: DotTimerRecord = null

	## Practice checkpoints. Per player, because they are a player's own working set.
	var checkpoints: DotTimerCheckpoints = null

	## When they joined, for play time. Ticks of the engine clock, not the run's.
	var joined_msec: int = 0

	## Stop the run the moment it falls behind their best, and ask to be put back.
	var auto_restart: bool = false

	## A dropped run kept for them, offered on return. Empty when none.
	var pending_resume: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if config != null:
		var applied := apply_config(config)
		DotLog.result(CHANNEL, "applying the timer configuration", applied)

	if store == null and store_service != &"":
		var found := DotRegistry.get_service(store_service)

		if found is DotTimerStore:
			store = found
		elif found != null:
			DotLog.warn(CHANNEL, "the registered store is not a DotTimerStore", {
				"service": String(store_service)
			})

	if zones_path != "":
		var loaded := load_zones(zones_path)
		DotLog.result(CHANNEL, "loading zones", loaded)

	if styles.is_empty():
		set_styles(DotTimerStyle.defaults())

	set_process(true)


## Writes a batching store's pending changes on an interval. The file store keeps
## records in memory until flushed; see [method DotTimerStoreFile.flush] for what
## happened when nothing did this.
func _process(delta: float) -> void:
	if Engine.is_editor_hint() or store == null:
		return
	_flush_elapsed += delta
	if _flush_elapsed < flush_seconds:
		return
	_flush_elapsed = 0.0
	_flush_store(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE and not Engine.is_editor_hint():
		_flush_store(true)


## Flushes the store. [param all] keeps going until nothing is pending — at exit, where
## there is no next interval.
func _flush_store(all: bool) -> void:
	if store == null:
		return
	var rounds := 0
	while true:
		var result := store.flush()
		if not result.ok:
			# At most once a minute: the same unwritable directory fails every interval,
			# and an ERROR every five seconds buries everything else in the log.
			var now := Time.get_ticks_msec()
			if now - _last_flush_error_msec > 60000 or _last_flush_error_msec == 0:
				_last_flush_error_msec = now
				DotLog.error(CHANNEL, "records could not be written", {"error": result.error.message, "detail": result.error.detail})
			return
		rounds += 1
		if not all or not store.has_method("has_pending") or not store.call("has_pending") or rounds > 1000:
			return

# --- Configuration ---------------------------------------------------------

## Applies a [DotTimerConfig], including its tick rate.
##
## Called from [method Node._ready] when [member config] is set; call it again after
## reloading the file. Safe to call with runs in progress only in the sense that
## [method set_tick_rate] is — it will abandon them rather than misreport them.
func apply_config(p_config: DotTimerConfig) -> DotResult:
	if p_config == null:
		return DotResult.fail(DotError.CODE_INVALID, "No configuration.")

	var valid := p_config.validate()

	if not valid.ok:
		return valid.wrap("The timer configuration is not usable.")

	config = p_config

	authoritative = p_config.authoritative
	record_runs = p_config.record_runs
	record_replays = p_config.record_replays
	replays_directory = (
		p_config.replays_directory if p_config.record_replays else ""
	)
	allow_checkpoints = p_config.allow_checkpoints

	for id in _players:
		var existing: Player = _players[id]
		if existing.checkpoints != null:
			existing.checkpoints.enabled = allow_checkpoints

	# A store the host assigned — a SQL one, built from the game's own database
	# settings — is kept. The configuration only chooses one when there is none, which
	# is what it always did for a server that left it to the file.
	if store == null:
		if p_config.record_runs and p_config.records_directory != "":
			var file_store := DotTimerStoreFile.at(p_config.records_directory)
			file_store.flush_batch = p_config.flush_batch
			store = file_store
		else:
			store = DotTimerStoreMemory.new()

	points.formula = DotTimerPoints.formula_from_name(p_config.points_formula) as DotTimerPoints.Formula
	points.weighting = p_config.points_weighting
	points.weighting_limit = p_config.points_weighting_limit
	points.points_per_tier = p_config.points_per_tier
	points.bonus_factor = p_config.bonus_points_factor
	enforce_stages = p_config.enforce_stages
	pause_rules = p_config.pause_rules
	teleport_stop_distance = p_config.teleport_stop_distance
	resume_seconds = p_config.resume_seconds
	flush_seconds = p_config.flush_seconds
	for id in _players:
		_configure_timer((_players[id] as Player).timer)

	set_tick_rate(p_config.effective_tick_rate(Engine.physics_ticks_per_second))

	for id in _players:
		(_players[id] as Player).timer.authoritative = authoritative

	DotLog.info(CHANNEL, "timer configured", {
		"summary": p_config.describe_summary(), "tick_rate": tick_rate,
		# The store actually in use, which a host may have assigned (a database) and the
		# summary — built from the file settings alone — cannot know about.
		"store": store.get_script().get_global_name() if store != null else "none",
		"points": DotTimerPoints.formula_name(points.formula),
	})

	return DotResult.success(null)


## Sets the tick rate, rebinding every player's timer.
##
## [b]Runs in progress are abandoned, and that is the only honest option.[/b] A run is
## a count of ticks plus the duration one tick represents; change the second and every
## tick already banked means something different. A run half-counted at 64 and half at
## 128 produces a time that is neither — and files it, with nothing anywhere to say
## so. Abandoning costs somebody one attempt; the alternative costs the leaderboard
## its meaning.
##
## Returns false when the rate is unusable or already in force.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	var was := tick_rate
	tick_rate = rate

	var abandoned := 0

	for id in _players:
		var player: Player = _players[id]

		if player.timer.run.is_active():
			abandoned += 1

		# bind() re-binds the zones AND the rate, and stops whatever was running.
		player.timer.bind(zones, tick_rate)

	if abandoned > 0:
		DotLog.warn(CHANNEL, "tick rate changed; runs in progress were abandoned", {
			"from": was, "to": rate, "runs": abandoned
		})
	else:
		DotLog.info(CHANNEL, "tick rate set", {"from": was, "to": rate})

	return true


## Takes the tick rate from the engine, which is what a dot-server sets.
##
## [b]The chain this closes:[/b] an operator writes [code]sv_tickrate 128[/code] in
## [code]server.cfg[/code]; dot-server's [code]_apply_tickrate[/code] writes
## [member Engine.physics_ticks_per_second]; this reads it; and the rate ends up on
## every [DotTimerRecord] the server files. Before it, the timer's rate was an export
## on a node that nobody would think to change, and a server retuned from 64 to 128
## would have gone on producing times computed against 64 — twice what they should
## be, on a leaderboard shared with servers that got it right, with no error anywhere.
##
## Call it once after the server has applied its own configuration, and again if the
## server ever changes it.
func adopt_engine_tick_rate() -> bool:
	return set_tick_rate(Engine.physics_ticks_per_second)


## Whether the timer and the engine agree about how fast time passes.
##
## [b]Worth checking at boot and saying so loudly.[/b] They disagreeing is the one
## misconfiguration here that produces plausible, wrong, permanently-filed times
## instead of an error: a timer counting 128 a second on a server stepping 64 reports
## every run at twice its length, and nothing about the run looks unusual.
func tick_rate_matches_engine() -> bool:
	return tick_rate == Engine.physics_ticks_per_second


# --- Content ---------------------------------------------------------------

## Replaces the map's zones. Every player's run in progress is abandoned.
##
## Abandoned rather than carried, for the reason [method DotTimer.bind] gives: a run
## begun on one map's zones and finished on another's is a record on neither.
func set_zones(set: DotTimerZoneSet) -> DotResult:
	zones = set

	_tier_override = 0

	for id in _players:
		var player: Player = _players[id]
		# A new map: a run-out still going belongs to the last one. Written as it stands.
		_flush_trail(player)
		var bound := player.timer.bind(set, tick_rate)
		if not bound.ok:
			return bound
		_configure_timer(player.timer)

	zones_changed.emit(set)

	if set != null and store != null:
		_catalogue_map()

	if set != null:
		for problem in set.problems():
			DotLog.warn(CHANNEL, "zone problem", {
				"map": String(set.map_id), "problem": problem
			})

		# A route missing its spawn or its pit loads and runs; the first anybody hears
		# of it otherwise is a player on a bonus falling out of the world.
		for problem in set.route_problems():
			DotLog.warn(CHANNEL, "incomplete route", {
				"map": String(set.map_id), "problem": problem
			})

		# Advisory, and checked here because a map change is the moment somebody is
		# looking: at 128 Hz a player at 40 m/s crosses 31 cm in a tick, and a finish
		# volume thinner than that is one the fastest players pass straight through
		# without the run ever ending.
		var speed := config.fastest_expected_speed if config != null else 40.0
		var fall := config.fastest_expected_fall_speed if config != null else 0.0

		for zone in set.thin_zones(speed, tick_rate, fall):
			DotLog.warn(CHANNEL, "a zone is thinner than one tick of travel", {
				"map": String(set.map_id),
				"zone": zone.describe(),
				"at": "%.0f m/s across, %.0f m/s down, %d Hz" % [
					speed, fall if fall > 0.0 else speed, tick_rate
				],
			})

	# [b]Only where it is true.[/b] On an authoritative timer a rate that disagrees with
	# the engine is the one misconfiguration producing plausible wrong times rather than
	# an error, and it is said at every map change because that is when somebody is
	# watching.
	#
	# On a MIRRORING timer it is neither wrong nor avoidable. A client counts at the
	# rate the server told it — that is the whole point, and it is what makes a run set
	# at 128 comparable on a client rendering at 60 — while `physics_ticks_per_second`
	# there is whatever the host project exported, which the server has no say in and
	# which a browser build never sets at all. Warning about it told every web client
	# that every time "this server" files will be wrong, on a client that files none.
	if authoritative and not tick_rate_matches_engine():
		DotLog.warn(
			CHANNEL,
			"the timer's tick rate does not match the engine's physics rate; "
			+ "every time this server files will be wrong by their ratio",
			{"timer": tick_rate, "engine": Engine.physics_ticks_per_second}
		)

	return DotResult.success(null)


func load_zones(path: String) -> DotResult:
	var loaded := DotTimerZoneSet.load_json(path)

	if not loaded.ok:
		return loaded

	return set_zones(loaded.value)


## Registers the style table. Ids must match the movement styles the game applies.
func set_styles(list: Array[DotTimerStyle]) -> void:
	styles.clear()

	for style in list:
		styles[style.id] = style


func style_for(id: StringName) -> DotTimerStyle:
	var found: Variant = styles.get(id)
	return found if found is DotTimerStyle else null


## Styles in display order.
func styles_in_order() -> Array[DotTimerStyle]:
	var out: Array[DotTimerStyle] = []

	for id in styles:
		out.append(styles[id])

	out.sort_custom(func(a: DotTimerStyle, b: DotTimerStyle) -> bool:
		if a.ordering != b.ordering:
			return a.ordering < b.ordering
		return String(a.id) < String(b.id)
	)

	return out


# --- Players ---------------------------------------------------------------

func add_player(id: StringName, display_name: String) -> DotResult:
	if _players.has(id):
		return DotResult.fail(
			DotError.CODE_STATE, "That player already has a timer.", String(id)
		)

	var player := Player.new()
	player.id = id
	player.display_name = display_name
	player.timer = DotTimer.new()
	player.timer.authoritative = authoritative
	player.sample = DotTimerSample.new()
	player.recorder = DotTimerReplayRecorder.new()
	player.recorder.tick_rate = tick_rate
	if config != null:
		player.recorder.max_seconds = config.max_replay_seconds
		player.recorder.pre_roll_seconds = config.replay_pre_roll_seconds
		player.recorder.post_roll_seconds = config.replay_post_roll_seconds

	var bound := player.timer.bind(zones, tick_rate)

	if not bound.ok:
		return bound

	player.timer.style = style_for(&"normal")
	_configure_timer(player.timer)
	player.joined_msec = Time.get_ticks_msec()

	player.checkpoints = DotTimerCheckpoints.of(player.timer)
	player.checkpoints.enabled = allow_checkpoints

	# Bound with the player's id captured, because the timer's own signals do not
	# carry one — it does not know it is one of thirty.
	player.timer.run_started.connect(
		func(run: DotTimerRun) -> void: _on_started(id, run)
	)
	player.timer.run_finished.connect(
		func(run: DotTimerRun) -> void: _on_finished(id, run)
	)
	player.timer.run_stopped.connect(
		func(run: DotTimerRun, reason: StringName) -> void:
			_on_stopped(id, run, reason)
	)
	player.timer.stage_reached.connect(
		func(number: int, split: float) -> void:
			player_staged.emit(id, number, split)
			_on_staged(id, number)
	)
	player.timer.start_refused.connect(
		func(reason: String) -> void: start_refused.emit(id, reason)
	)
	player.timer.effect_requested.connect(
		func(zone: DotTimerZone) -> void: effect_requested.emit(id, zone)
	)
	player.timer.effects_changed.connect(
		func() -> void: effects_changed.emit(id, player.timer.active_effects())
	)

	_players[id] = player

	if store != null and authoritative:
		# Not awaited: joining is not held up by a database. The name and the time are
		# on the row by the time anybody asks for a profile.
		store.note_player(id, display_name, int(Time.get_unix_time_from_system()))
		_offer_resume(id)

	return DotResult.success(player)


## The per-map and per-server rules every player's timer needs. Called on join, on a map
## change and on a configuration change, so a rule never differs between two players.
func _configure_timer(timer: DotTimer) -> void:
	var map_says: Variant = zones.meta.get("enforce_stages") if zones != null else null
	timer.enforce_stages = enforce_stages if map_says == null else bool(map_says)
	timer.pause_rules = pause_rules
	timer.teleport_stop_distance = teleport_stop_distance


func remove_player(id: StringName) -> bool:
	if not _players.has(id):
		return false

	var player: Player = _players[id]

	if store != null and authoritative:
		# Kept for them, if they come back soon enough. Saved before the stop below,
		# which is what ends it here.
		if resume_seconds > 0.0 and player.timer.run.is_active() and zones != null:
			var state := player.timer.run.to_snapshot()
			state["position"] = _vec(player.sample.position)
			state["velocity"] = _vec(player.sample.velocity)
			state["saved_at"] = int(Time.get_unix_time_from_system())
			state["zones"] = zones.fingerprint()
			state["tick_rate"] = tick_rate
			store.save_resume(id, zones.map_id, state)
		var played := float(Time.get_ticks_msec() - player.joined_msec) / 1000.0
		store.note_player(id, player.display_name, int(Time.get_unix_time_from_system()), played)

	# Stopped rather than dropped, so anything listening for the end of a run gets
	# one. A player who disconnects mid-run leaves a run that never ended otherwise,
	# and whatever was tracking it leaks.
	player.timer.stop(DotTimer.REASON_RESET)
	_flush_trail(player)
	player.recorder.discard()

	_players.erase(id)

	return true


func player(id: StringName) -> Player:
	var found: Variant = _players.get(id)
	return found if found is Player else null


func timer_for(id: StringName) -> DotTimer:
	var found := player(id)
	return found.timer if found != null else null


func player_count() -> int:
	return _players.size()


func player_ids() -> Array:
	return _players.keys()


# --- The tick --------------------------------------------------------------

## Advances one player's timer by one simulated tick.
##
## [b]Once per simulated tick, from the movement loop.[/b] Not from
## [code]_process[/code] and not twice for a replayed tick. A timer sampled per frame
## counts a different number of ticks on a 144 Hz monitor than on a 60 Hz one, and the
## player's time then depends on their hardware.
func tick_player(
	id: StringName,
	position: Vector3,
	velocity: Vector3,
	grounded: bool,
	alive: bool = true,
	yaw: float = 0.0,
	pitch: float = 0.0,
	buttons: int = 0,
	replay_flags: int = 0
) -> void:
	var found := player(id)

	if found == null:
		return

	found.sample.position = position
	found.sample.velocity = velocity
	found.sample.grounded = grounded
	found.sample.alive = alive
	found.sample.buttons = buttons

	found.timer.tick(found.sample)

	if found.auto_restart and found.timer.run.is_running() and store != null and zones != null:
		# From the store's cache, never waiting: this runs every tick.
		var best: Variant = store.peek_best(zones.map_id, found.timer.track, found.timer.run.style_id, id)
		if best is DotTimerRecord and found.timer.run.time() > (best as DotTimerRecord).time:
			found.timer.stop(DotTimer.REASON_AUTO_RESTART)
			teleport_requested.emit(id, _spawn_zone(found.timer.track), &"auto_restart")

	# Every tick, not only during a run: the recorder keeps the run-up before a start and the
	# run-out after a finish. [param replay_flags] is the caller's FLAG_DUCKED, FLAG_JUMPED
	# and FLAG_TELEPORT, which this addon declared from the start and nothing ever wrote.
	if record_replays:
		var flags := (DotTimerReplay.FLAG_GROUNDED if grounded else 0) | (replay_flags & (
			DotTimerReplay.FLAG_DUCKED | DotTimerReplay.FLAG_JUMPED | DotTimerReplay.FLAG_TELEPORT))
		found.recorder.feed(position, yaw, pitch, flags, buttons)
		if found.recorder.take_trail_done() and found.pending_replay_record != null:
			var record := found.pending_replay_record
			found.pending_replay_record = null
			_write_replay(found, record)


## Folds movement statistics into a player's current run.
##
## Separate from [method tick_player] because not every game measures the same things
## and a 2D game measures none of them. A first-person game passes
## [code]controller.stats.to_dictionary()[/code] once when the run ends, or every tick
## if it wants a live HUD.
##
## [b]A FINISHED run accepts them too, and that is the whole point of the method.[/b]
## The obvious guard is "only while the run is active", and it silently discards the
## one call that matters: the natural moment to fold in a run's statistics is when it
## ends, which is exactly when the run is no longer active. game-playground's
## integration suite caught it as a record whose stats dictionary was empty — no
## error anywhere, because refusing to write a statistic is a legitimate thing for a
## timer with no run to do.
func note_stats(id: StringName, stats: Dictionary) -> void:
	var found := player(id)

	if found == null:
		return

	var run := found.timer.run

	if run.is_active() or run.status == DotTimerRun.Status.FINISHED:
		run.note_stats(stats)


# --- Run lifecycle ---------------------------------------------------------

func _on_started(id: StringName, run: DotTimerRun) -> void:
	var found := player(id)

	if found == null:
		return

	if record_replays:
		found.recorder.begin(
			zones.map_id if zones != null else &"",
			run.track,
			run.style_id,
			found.display_name,
			tick_rate
		)

	player_started.emit(id, run)


func _on_stopped(id: StringName, run: DotTimerRun, reason: StringName) -> void:
	var found := player(id)

	if found != null:
		found.recorder.discard()

	if store != null and authoritative and zones != null and run.ticks > 0:
		store.note_progress(id, zones.map_id, run.track, run.style_id, 1, run.time(), false)

	player_stopped.emit(id, run, reason)


func _on_finished(id: StringName, run: DotTimerRun) -> void:
	var found := player(id)

	if found == null:
		return

	found.last_finished = run
	found.last_replay = found.recorder.finish(run.time())

	player_finished.emit(id, run)

	if store != null and authoritative and zones != null:
		store.note_progress(id, zones.map_id, run.track, run.style_id, 1, run.time(), true)

	if not record_runs:
		return

	var allowed := found.timer.can_record(run)

	if not allowed.ok:
		# The recorder is emptied here rather than at the top: a refused run still
		# produced frames, and holding them until the next run would double the peak.
		found.last_replay = null
		record_refused.emit(id, run, allowed.error.message)
		_tell_would_be_rank(id, run, allowed.error.message)
		return

	if store == null:
		found.last_replay = null
		record_refused.emit(id, run, "This server does not keep records.")
		return

	var record := found.timer.build_record(run, id, found.display_name)

	if record == null:
		found.last_replay = null
		record_refused.emit(id, run, "The run could not be turned into a record.")
		return

	if run.stats.has("resumed"):
		# Restored after a reconnect: the recorder never saw the first half.
		found.last_replay = null

	await _file(found, record)

	# The last section of a staged map ends at the finish, so it is filed here rather
	# than at a stage line.
	var stages := stage_count(run.track)
	if stages > 0:
		await _file_section(found, run, stages + 1)


## The rank a refused finish would have had, for the player's own information.
func _tell_would_be_rank(id: StringName, run: DotTimerRun, reason: String) -> void:
	if store == null or zones == null or not authoritative:
		return
	var would: DotResult = await store.rank_for_time(zones.map_id, run.track, run.style_id, run.time())
	var total: DotResult = await store.count_on(zones.map_id, run.track, run.style_id)
	practice_finished.emit(
		id, run, int(would.value) if would.ok else 0, int(total.value) if total.ok else 0, reason
	)


func _file(found: Player, record: DotTimerRecord) -> void:
	var wrote: DotResult = await store.put(record)

	if not wrote.ok:
		# ERROR, because this is not a refusal. Whether a run may be filed was decided
		# by DotTimer.can_record before it got here, and a store never decides that --
		# so a failed put is a clean, finished run lost to a disk or a service. The
		# signal tells the player; before this line nothing told the operator.
		DotLog.error(CHANNEL, "a finished run could not be stored", {
			"player": String(record.player_id),
			"map": String(record.map_id),
			"track": record.track,
			"style": String(record.style_id),
			"time": record.time,
			"code": wrote.code(),
			"error": wrote.error.message if wrote.error != null else "",
		})
		record_refused.emit(found.id, found.last_finished, wrote.error.message)
		found.last_replay = null
		return

	var info: Dictionary = wrote.value
	var previous: DotTimerRecord = info["previous"]
	var leader: DotTimerRecord = info["previous_record"]
	var improved := bool(info["improved"])
	# The store's own answer when it has one: the SQL store asks the board AFTER its
	# write, which is the only place two servers beating one record at once can be told
	# apart. Otherwise judged against the leader it read before.
	var world_record := improved and (
		bool(info["was_record"]) if info.has("was_record")
		else (leader == null or record.time < leader.time or leader.player_id == record.player_id)
	)

	if not improved:
		# The store kept the old one, which is correct: the run was slower. Still an
		# acceptance rather than a refusal — the player did finish, cleanly, and the
		# HUD wants to say by how much they missed. The replay goes, because it is a
		# replay of a run nothing is keeping.
		found.last_replay = null
	else:
		# Scored after the write, against the board as it now stands, and the whole
		# board re-scored when its record moved: every row's worth depends on the
		# record (and, for PLACEMENT, on everybody's place). Scoring once at filing and
		# never again left boards whose points said the record was a time it no longer
		# was.
		await _rescore(record, world_record or points.rescore_on_any_change())

	var rank_result: DotResult = await store.rank_of(
		record.map_id, record.track, record.style_id, record.player_id
	)
	var total_result: DotResult = await store.count_on(record.map_id, record.track, record.style_id)
	var rank := int(rank_result.value) if rank_result.ok else 0

	record_accepted.emit(record, previous, rank)

	if improved:
		_persist_replay(found, record)

	run_filed.emit({
		"player": found.id,
		"record": record,
		"previous": previous,
		"previous_record": leader,
		"improved": improved,
		"first": previous == null,
		"world_record": world_record,
		"rank": rank,
		"total": int(total_result.value) if total_result.ok else 0,
		"completions": int(info["completions"]),
		"points": record.points,
		"title": await title_for(found.id),
	})


## Files section [param section] of a run as its own record, if the run is clean.
##
## [b]Clean so far, not clean at the finish[/b]: a section is a complete thing once its
## second line is crossed, and the flags that disqualify a run are sticky — so a section
## filed now was clean when it was run, whatever happens later in the attempt.
func _file_section(found: Player, run: DotTimerRun, section: int) -> void:
	if store == null or zones == null or not authoritative or not record_runs:
		return
	var style := found.timer.style
	if style != null and not style.ranked:
		return
	if run.tainted or run.skipped or (run.used_checkpoints and not (style != null and style.allow_checkpoints)):
		return
	var total := stage_count(run.track) + 1
	var record := DotTimerRecord.section_from_run(run, section, total, zones.map_id, found.id, found.display_name)
	if record == null or record.time <= 0.0:
		return
	record.zone_fingerprint = zones.fingerprint()
	var wrote: DotResult = await store.put(record)
	if not wrote.ok:
		DotLog.warn(CHANNEL, "a section could not be stored", {
			"player": String(found.id), "section": section, "error": wrote.error.message,
		})
		return
	var info: Dictionary = wrote.value
	var leader: DotTimerRecord = info["previous_record"]
	var rank: DotResult = await store.rank_of(record.map_id, record.track, record.style_id, record.player_id, section)
	var count: DotResult = await store.count_on(record.map_id, record.track, record.style_id, section)
	section_filed.emit({
		"player": found.id,
		"record": record,
		"previous": info["previous"],
		"previous_record": leader,
		"improved": bool(info["improved"]),
		"first": info["previous"] == null,
		"world_record": bool(info["improved"]) and (
			bool(info["was_record"]) if info.has("was_record")
			else (leader == null or record.time < leader.time or leader.player_id == record.player_id)
		),
		"rank": int(rank.value) if rank.ok else 0,
		"total": int(count.value) if count.ok else 0,
		"completions": int(info["completions"]),
		"points": 0.0,
	})


func _on_staged(id: StringName, number: int) -> void:
	var found := player(id)
	if found == null:
		return
	# Crossing line N completes section N: the stretch from line N - 1 (the start, for
	# N = 1) to line N.
	await _file_section(found, found.timer.run, number)


# --- Points ------------------------------------------------------------------

## What [param record] is worth now, written to the store, with the player totals that
## depend on it. [param whole_board] re-scores every row on its board.
func _rescore(record: DotTimerRecord, whole_board: bool) -> void:
	if record.stage != 0:
		return
	if whole_board:
		await rescore_board(record.map_id, record.track, record.style_id, record)
		return
	var top_res: DotResult = await store.top(record.map_id, record.track, record.style_id, 1)
	var best := (top_res.value[0] as DotTimerRecord).time if top_res.ok and not (top_res.value as Array).is_empty() else record.time
	var rank_res: DotResult = await store.rank_of(record.map_id, record.track, record.style_id, record.player_id)
	var count_res: DotResult = await store.count_on(record.map_id, record.track, record.style_id)
	record.points = _points_for(record, best, int(rank_res.value) if rank_res.ok else 1, int(count_res.value) if count_res.ok else 1)
	await store.set_points([record])
	await _refresh_totals([String(record.player_id)])


## Re-scores every record on one board and re-totals everybody on it.
##
## [param filed] is the record just filed, if any, which gets its new points too — the
## caller emits it.
func rescore_board(
	map_id: StringName, track: int, style_id: StringName, filed: DotTimerRecord = null,
	also_refresh: Array = []
) -> DotResult:
	var listed: DotResult = await store.top(map_id, track, style_id, 1 << 20)
	if not listed.ok:
		return listed
	var rows: Array = listed.value
	if rows.is_empty():
		if not also_refresh.is_empty():
			await _refresh_totals(also_refresh)
		return DotResult.success(0)
	var best: float = (rows[0] as DotTimerRecord).time
	var changed: Array = []
	var players: Array = []
	var rank := 1
	for i in range(rows.size()):
		var row: DotTimerRecord = rows[i]
		if i > 0 and row.time > (rows[i - 1] as DotTimerRecord).time:
			rank = i + 1
		var worth := _points_for(row, best, rank, rows.size())
		if filed != null and row.player_id == filed.player_id:
			filed.points = worth
		if absf(worth - row.points) > 0.0001:
			row.points = worth
			changed.append(row)
			players.append(String(row.player_id))
	if not changed.is_empty():
		await store.set_points(changed)
	# A player whose record was just REMOVED has no row here, so their total would never
	# be recomputed from the rows that changed; the caller names them.
	for id in also_refresh:
		if not players.has(str(id)):
			players.append(str(id))
	if not players.is_empty():
		await _refresh_totals(players)
	return DotResult.success(changed.size())


## Re-totals [param player_ids] and says so.
func _refresh_totals(player_ids: Array) -> void:
	await store.refresh_player_points(player_ids, points.weighting, points.weighting_limit)
	points_changed.emit(player_ids.duplicate())


## Removes one player's record and puts the board and their total right. What an admin's
## "delete that time" means; the store's own [code]remove[/code] only deletes the row.
func remove_record(
	map_id: StringName, track: int, style_id: StringName, player_id: StringName, stage: int = 0
) -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	var removed: DotResult = await store.remove(map_id, track, style_id, player_id, stage)
	if not removed.ok or not bool(removed.value) or stage != 0:
		return removed
	await rescore_board(map_id, track, style_id, null, [String(player_id)])
	return removed


## Removes everything one player filed, then re-scores every map they were on — they may
## have held records other rows were measured against — and re-totals them (to zero).
func wipe_player(player_id: StringName) -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	var theirs: DotResult = await store.records_of(player_id, {"stage": -1})
	var map_ids := {}
	if theirs.ok:
		for record in (theirs.value as Array):
			map_ids[(record as DotTimerRecord).map_id] = true
	var wiped: DotResult = await store.wipe_player(player_id)
	if not wiped.ok:
		return wiped
	for map_id in map_ids:
		await rescore_map(map_id)
	await _refresh_totals([String(player_id)])
	return wiped


## Re-scores every board on a map. What a tier change needs, and what an operator runs
## after changing the points formula.
func rescore_map(map_id: StringName = &"") -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	var id := map_id if map_id != &"" else (zones.map_id if zones != null else &"")
	var listed: DotResult = await store.records_on_map(id)
	if not listed.ok:
		return listed
	var boards := {}
	for record in (listed.value as Array):
		var r: DotTimerRecord = record
		if r.stage == 0:
			boards[r.board_key()] = [r.map_id, r.track, r.style_id]
	var changed := 0
	for key in boards:
		var parts: Array = boards[key]
		var res: DotResult = await rescore_board(parts[0], parts[1], parts[2])
		if res.ok:
			changed += int(res.value)
	return DotResult.success(changed)


func _points_for(record: DotTimerRecord, best: float, rank: int, finishers: int) -> float:
	var style := style_for(record.style_id)
	var multiplier := style.points_multiplier if style != null else 1.0
	if style != null and not style.ranked:
		return 0.0
	# CURVE goes through the style, so a game that overrode DotTimerStyle.points_for —
	# the documented way to change the formula before there were three — still gets its
	# own.
	if points.formula == DotTimerPoints.Formula.CURVE and style != null:
		return style.points_for(record.time, map_tier(), best)
	return points.points_for(record.time, best, map_tier(), record.track, multiplier, rank, finishers)


## Writes the replay of a run the store kept, if replays are being kept on disk.
##
## Failure is logged and swallowed on purpose: the record is already in the store and
## the run already counted. A full disk must not turn an accepted record into a
## refused one, and the caller has emitted [signal record_accepted] before this runs.
## Ends a finished replay's run-out early and writes it if a kept record was waiting for it.
func _flush_trail(found: Player) -> void:
	found.recorder.end_trail()
	var _done := found.recorder.take_trail_done()
	if found.pending_replay_record != null:
		var record := found.pending_replay_record
		found.pending_replay_record = null
		_write_replay(found, record)


func _persist_replay(found: Player, record: DotTimerRecord) -> void:
	if replays_directory == "" or found.last_replay == null:
		return

	# Still taking its run-out: written when that ends (tick_player), with it.
	if found.recorder.is_trailing():
		found.pending_replay_record = record
		return

	_write_replay(found, record)


func _write_replay(found: Player, record: DotTimerRecord) -> void:
	if replays_directory == "" or found.last_replay == null:
		return

	var path := replay_path(record)
	var saved := found.last_replay.save(path)

	if not saved.ok:
		DotLog.warn(CHANNEL, "replay not written", {
			"path": path, "error": saved.error.message
		})
		return

	DotLog.info(CHANNEL, "replay written", {"path": path})


## Where a record's replay lives, under [member replays_directory].
##
## One file per map/track/style/player rather than per run: the store keeps one record
## per that tuple, so a second file would be a replay of a run the store has already
## replaced. Overwriting is the correct behaviour.
##
## Ids are sanitised through [method DotTimerStoreFile.safe_component], which is the
## same function the records filename goes through, and deliberately not a second one
## written here: a player id and a map id both reach this from the wire, so
## [code]../[/code] in either is a write outside the directory — and substitution is
## many-to-one, so without that function's hash suffix [code]surf_kitsune2[/code] and
## [code]surf_kitsune3[/code] would share one replay file. That exact bug cost this
## addon a leaderboard once; a second sanitiser is how it comes back.
func replay_path(record: DotTimerRecord) -> String:
	var name := "%s_%d_%s_%s.drp" % [
		DotTimerStoreFile.safe_component(String(record.map_id)),
		clampi(record.track, 0, DotTimerTrack.BONUS_LAST),
		DotTimerStoreFile.safe_component(String(record.style_id)),
		DotTimerStoreFile.safe_component(String(record.player_id)),
	]

	return replays_directory.path_join(name)


## The map's difficulty tier, 1..10, for the points formula.
##
## Read off the zone set's [member DotTimerZoneSet.meta], because a tier is a property
## of the map that whoever drew the zones is best placed to record, and a game with
## its own map catalogue overrides this.
func map_tier() -> int:
	if _tier_override > 0:
		return _tier_override

	if zones == null:
		return 1

	return clampi(int(zones.meta.get("tier", 1)), 1, 10)


## Sets the map's tier, keeps it, and re-scores every board on the map — every record's
## worth depends on the tier. An admin's tier outranks the zone file's from then on.
func set_map_tier(tier: int) -> DotResult:
	if zones == null or store == null:
		return DotResult.fail(DotError.CODE_STATE, "No map is loaded.")
	if tier < 1 or tier > 10:
		return DotResult.fail(DotError.CODE_INVALID, "A tier is 1 to 10.", str(tier))
	_tier_override = tier
	var saved: DotResult = await store.put_map({"map": String(zones.map_id), "tier": tier, "tier_source": "admin"})
	if not saved.ok:
		return saved
	return await rescore_map(zones.map_id)


## Records the loaded map in the store's catalogue — what "maps left" counts against —
## and picks up a tier an admin set before.
func _catalogue_map() -> void:
	var map_id := zones.map_id
	var existing: DotResult = await store.map_info(map_id)
	var info: Dictionary = existing.value if existing.ok and existing.value != null else {}
	if zones == null or zones.map_id != map_id:
		return
	var bonuses := 0
	for track in zones.playable_tracks():
		if DotTimerTrack.is_bonus(track):
			bonuses += 1
	var update := {
		"map": String(map_id),
		"stages": zones.stage_count(DotTimerTrack.MAIN),
		"bonuses": bonuses,
	}
	if str(info.get("tier_source", "")) == "admin":
		_tier_override = clampi(int(info.get("tier", 1)), 1, 10)
	else:
		update["tier"] = clampi(int(zones.meta.get("tier", 1)), 1, 10)
		update["tier_source"] = "zones"
	if zones.meta.has("mapper"):
		update["mapper"] = str(zones.meta["mapper"])
	await store.put_map(update)


# --- Convenience -----------------------------------------------------------

## Puts a player on a style, abandoning any run in progress.
func set_player_style(id: StringName, style_id: StringName) -> bool:
	var found := player(id)

	if found == null:
		return false

	var style := style_for(style_id)

	if style == null:
		return false

	# The checkpoint set is deliberately NOT cleared or disabled by a style change.
	# Practice mode is how somebody learns a map, and taking their saved positions
	# away because they switched to sideways would be taking away the reason they
	# switched. What the style decides is what using one costs — see
	# [member DotTimerStyle.allow_checkpoints].
	return found.timer.set_style(style)


## A player's practice checkpoints, or null.
func checkpoints_for(id: StringName) -> DotTimerCheckpoints:
	var found := player(id)
	return found.checkpoints if found != null else null


func set_player_track(id: StringName, track: int) -> bool:
	var found := player(id)
	return found != null and found.timer.set_track(track)


# --- Stages ----------------------------------------------------------------
#
# The navigation half of a staged map, which is what the timer community's staged maps
# and Shavit's `sm_stages` / `sm_stagerestart` are. dot-timer has carried stage zones,
# sub-tick splits and `stage_count` since it was written and NOTHING read any of it:
# `stage_count` occurred exactly once in the whole family, which is this tree's own
# mechanical detector for a value produced correctly and consumed by nothing.
#
# The timer still does not move anybody. `stage_requested` is emitted for the same
# reason `effect_requested` is: what "put the player here" means differs between a
# first-person game, a 2D game and a replay being scrubbed, and an addon that moved a
# body would be choosing for all three.


## How many stages a track has on the loaded map. 0 for a map without any.
func stage_count(track: int = DotTimerTrack.MAIN) -> int:
	return zones.stage_count(track) if zones != null else 0


## The stage zone a "go to stage N" resolves to, or null.
func stage_zone(track: int, number: int) -> DotTimerZone:
	return zones.stage_zone(track, number) if zones != null else null


## Which tracks on this map can actually be run, start to finish.
func tracks() -> PackedInt32Array:
	return zones.playable_tracks() if zones != null else PackedInt32Array()


## Puts a player at stage [param number] of the track they are on. Shavit's `!s3`.
##
## [b]The run is stopped, not tainted.[/b] A player teleported into the middle of a
## map has not run the first half of it, and a timer that let that time stand would be
## filing a record for a run nobody made. Practice checkpoints are the mechanism for
## "I want to keep my time while I learn this" and they carry their own
## [member DotTimerRun.used_checkpoints] flag; this is the other thing, and it is not
## a ranked attempt.
##
## Returns the zone the host should move the player to.
func request_stage(id: StringName, number: int) -> DotResult:
	var found := player(id)

	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)

	var track: int = found.timer.track
	var total := stage_count(track)

	if total <= 0:
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"%s has no stages on %s." % [
				String(zones.map_id) if zones != null else "this map",
				DotTimerTrack.name_of(track),
			]
		)

	# Refused rather than clamped, for the reason DotTimerTrack.parse returns -1
	# rather than falling back to the main track: a player who typed "stage 9" on a
	# five-stage map and was silently put on stage 5 has no way to tell.
	if number < 1 or number > total:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Stage %d is outside 1..%d on %s." % [
				number, total, DotTimerTrack.name_of(track)
			]
		)

	var zone := stage_zone(track, number)

	if zone == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No stage %d zone on %s." % [number, DotTimerTrack.name_of(track)]
		)

	found.timer.stop(DotTimer.REASON_TELEPORT)
	stage_requested.emit(id, number, zone)

	DotLog.debug(CHANNEL, "stage requested", {
		"player": String(id), "track": track, "stage": number
	})

	return DotResult.success(zone)


## Puts a player back at the start of the stage they are on. Shavit's `!rs`.
##
## Stage 0 — before the first stage zone — is the start of the track, so this falls
## back to stage 1 rather than refusing. A player who has not reached a stage yet and
## asks to restart the stage means the one they are in.
func restart_stage(id: StringName) -> DotResult:
	var found := player(id)

	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)

	return request_stage(id, maxi(found.timer.run.stage, 1))


## The comparison splits for a player's stage line: their own best on this map,
## track and style, as [member DotTimerRecord.splits].
##
## Empty when there is no store, no record, or no stages — all three of which mean
## the HUD shows a stage number and no gap, which is correct rather than a failure.
func stage_splits_for(id: StringName, against_record: bool = false) -> Dictionary:
	var found := player(id)

	if found == null or store == null or zones == null:
		return {}

	var style := found.timer.style
	var style_id: StringName = style.id if style != null else &"normal"

	# From the store's cache, never waiting: a HUD asks this. The record's splits are the
	# comparison a staged map is raced against; a player's own are what they practise
	# against. A null means "not fetched yet" — the next frame has them.
	var peeked: Variant = (
		store.peek_top(zones.map_id, found.timer.track, style_id, 1) if against_record
		else store.peek_best(zones.map_id, found.timer.track, style_id, id)
	)

	if peeked is Array:
		peeked = (peeked as Array)[0] if not (peeked as Array).is_empty() else null

	# A store that answers "nobody has a time here" says so with false or an empty
	# list, not with a failure — a player who has never run this map is not an error.
	if not (peeked is DotTimerRecord):
		return {}

	var best: DotTimerRecord = peeked

	# Copied, not handed out. `DotTimerRecord.splits` is a Dictionary and therefore a
	# reference: returning it directly would let a HUD's own writes land in the stored
	# record. Three of this record's dictionaries have already been that bug once.
	return best.splits.duplicate(true)


# --- Restarting, pausing, resuming -----------------------------------------

## Stops a player's run and asks the host to put them at the start. `!r`.
func request_restart(id: StringName) -> DotResult:
	var found := player(id)
	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)
	found.timer.stop(DotTimer.REASON_RESET)
	var zone := _spawn_zone(found.timer.track)
	teleport_requested.emit(id, zone, &"restart")
	return DotResult.success(zone)


## Stops a player's run and asks the host to put them at the end. `!end`.
func request_end(id: StringName) -> DotResult:
	var found := player(id)
	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)
	var zone := zones.first_of_kind(DotTimerZone.Kind.END, found.timer.track) if zones != null else null
	if zone == null:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "This track has no end zone.")
	found.timer.stop(DotTimer.REASON_TELEPORT)
	found.timer.expect_teleport()
	teleport_requested.emit(id, zone, &"end")
	return DotResult.success(zone)


## Stops a player's run whenever it falls behind their best. `!autorestart`.
func set_auto_restart(id: StringName, on: bool) -> bool:
	var found := player(id)
	if found == null:
		return false
	found.auto_restart = on
	return true


## Pauses a player's run, if the rules allow. See [method DotTimer.pause_checked].
func pause_player(id: StringName) -> DotResult:
	var found := player(id)
	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)
	return found.timer.pause_checked(found.sample)


## Resumes a paused run. Success carries where the host must put the player back.
func resume_player(id: StringName) -> DotResult:
	var found := player(id)
	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)
	return found.timer.resume_checked()


## Gives a returning player back the run they dropped. The run comes back PAUSED;
## success carries [code]{position, velocity}[/code] for the host to put them at, after
## which [method resume_player] continues it.
##
## [b]Its replay is not kept[/b] — the recorder never saw the first half — and the
## record says it was resumed ([code]stats.resumed[/code]), so a disputed time can be
## checked against that.
func restore_player(id: StringName) -> DotResult:
	var found := player(id)
	if found == null:
		return DotResult.fail(DotError.CODE_INVALID, "No such player: %s." % id)
	if found.pending_resume.is_empty():
		return DotResult.fail(DotError.CODE_STATE, "There is no run to give back.")
	var state := found.pending_resume
	var run := DotTimerRun.from_snapshot(state)
	if run == null:
		found.pending_resume = {}
		return DotResult.fail(DotError.CODE_INVALID, "The saved run could not be read.")
	var current_style: StringName = found.timer.style.id if found.timer.style != null else &"normal"
	if run.style_id != current_style:
		# Kept, not dropped: the player switches back and asks again. The movement half
		# of a style is the host's, so this cannot switch it for them.
		return DotResult.fail(
			DotError.CODE_STATE,
			"That run was on %s. Switch back to it to take the run back." % String(run.style_id)
		)
	found.pending_resume = {}
	if found.timer.track != run.track:
		found.timer.set_track(run.track)
	run.stats["resumed"] = 1
	var at := _vec_from(state.get("position"))
	var velocity := _vec_from(state.get("velocity"))
	if not found.timer.restore_run(run, at, velocity):
		return DotResult.fail(DotError.CODE_STATE, "The run could not be restored.")
	found.recorder.discard()
	return DotResult.success({"position": at, "velocity": velocity})


func _offer_resume(id: StringName) -> void:
	if resume_seconds <= 0.0 or zones == null:
		return
	var taken: DotResult = await store.take_resume(id, zones.map_id)
	var found := player(id)
	if found == null or not taken.ok or not (taken.value is Dictionary) or zones == null:
		return
	var state: Dictionary = taken.value
	var age := int(Time.get_unix_time_from_system()) - int(state.get("saved_at", 0))
	# Refused rather than offered when the map moved underneath it: a run timed against
	# one finish line and finished at another is a record on neither.
	if age > int(resume_seconds) or str(state.get("zones", "")) != zones.fingerprint() or int(state.get("tick_rate", 0)) != tick_rate:
		return
	found.pending_resume = state
	resume_available.emit(id, state.duplicate(true))


func _spawn_zone(track: int) -> DotTimerZone:
	if zones == null:
		return null
	var zone := zones.first_of_kind(DotTimerZone.Kind.SPAWN, track)
	if zone == null and track != DotTimerTrack.MAIN:
		zone = zones.first_of_kind(DotTimerZone.Kind.SPAWN, DotTimerTrack.MAIN)
	return zone


static func _vec(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _vec_from(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


# --- Queries ----------------------------------------------------------------
#
# What a `!wr`, a `!profile` or a scoreboard asks. The commands themselves are a game's
# (see "Things deliberately not here"); these are the answers, so two games' `!rank`
# cannot disagree about what a rank is.

## A player's standing: their row, their rank and title, and what they have done.
func profile(id: StringName, style_id: StringName = &"") -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	var info: DotResult = await store.player_info(id)
	var rank: DotResult = await store.player_rank(id)
	var filter := {}
	if style_id != &"":
		filter["style"] = String(style_id)
	var mine: DotResult = await store.records_of(id, filter)
	var holds: DotResult = await store.record_count(id, filter)
	var catalogue: DotResult = await store.maps()
	if not (info.ok and rank.ok and mine.ok and holds.ok and catalogue.ok):
		return DotResult.fail(DotError.CODE_IO, "Could not read the player's records.")
	var maps_done := {}
	var bonuses_done := 0
	for record in (mine.value as Array):
		var r: DotTimerRecord = record
		if r.track == DotTimerTrack.MAIN:
			maps_done[r.map_id] = true
		else:
			bonuses_done += 1
	var standing: Dictionary = rank.value
	return DotResult.success({
		"player": String(id),
		"info": info.value,
		"rank": int(standing["rank"]),
		"ranked_players": int(standing["total"]),
		"points": float(standing["points"]),
		"title": titles.title_for(int(standing["rank"]), int(standing["total"]), float(standing["points"])),
		"records": (mine.value as Array).size(),
		"record_holds": int(holds.value),
		"maps_done": maps_done.size(),
		"bonuses_done": bonuses_done,
		"maps_total": (catalogue.value as Array).size(),
	})


## A player's title now. An empty dictionary without a store.
func title_for(id: StringName) -> Dictionary:
	if store == null:
		return {}
	var rank: DotResult = await store.player_rank(id)
	if not rank.ok:
		return {}
	var standing: Dictionary = rank.value
	return titles.title_for(int(standing["rank"]), int(standing["total"]), float(standing["points"]))


## Maps a player has finished on [param style], with their time: `!mapsdone`.
func maps_done(id: StringName, style_id: StringName = &"normal", track: int = DotTimerTrack.MAIN) -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	return await store.records_of(id, {"style": String(style_id), "track": track})


## Maps in the catalogue a player has NOT finished on [param style]: `!mapsleft`.
func maps_left(id: StringName, style_id: StringName = &"normal") -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	var done: DotResult = await maps_done(id, style_id)
	var catalogue: DotResult = await store.maps()
	if not done.ok or not catalogue.ok:
		return DotResult.fail(DotError.CODE_IO, "Could not read the map list.")
	var finished := {}
	for record in (done.value as Array):
		finished[String((record as DotTimerRecord).map_id)] = true
	var out: Array[Dictionary] = []
	for info in (catalogue.value as Array):
		if not finished.has(str(info["map"])):
			out.append(info)
	return DotResult.success(out)


## The latest records, newest first: `!rr`. See [method DotTimerStore.recent].
func recent_records(limit: int = 15, filter: Dictionary = {}) -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	return await store.recent(limit, filter)


## The ranked players, best first, with their titles: `!top`.
func top_players(limit: int = 10, offset: int = 0) -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store.")
	var listed: DotResult = await store.top_players(limit, offset)
	if not listed.ok:
		return listed
	var count: DotResult = await store.player_rank(&"")
	var total := int((count.value as Dictionary)["total"]) if count.ok else 0
	for row in (listed.value as Array):
		row["title"] = titles.title_for(int(row["rank"]), total, float(row["points"]))
	return listed


## The record for every section of the loaded map on a track and style: `!wrcp`. One
## entry per section, null where nobody has a time yet.
func section_records(track: int = DotTimerTrack.MAIN, style_id: StringName = &"normal") -> DotResult:
	if store == null or zones == null:
		return DotResult.fail(DotError.CODE_STATE, "No map or no store.")
	var out: Array = []
	var stages := stage_count(track)
	if stages <= 0:
		return DotResult.success(out)
	for section in range(1, stages + 2):
		var top_res: DotResult = await store.top(zones.map_id, track, style_id, 1, 0, section)
		out.append((top_res.value[0] if top_res.ok and not (top_res.value as Array).is_empty() else null))
	return DotResult.success(out)


## Minutes a map should run for, judged from how long it takes the people who have
## finished it. 0 when fewer than five have — not enough to judge, and the server's own
## default is the honest answer.
##
## The average of up to the fastest twenty-five, times enough attempts that a player of
## average speed gets several goes — more attempts on a short map, where one is cheap —
## plus five minutes, between twenty and a hundred and twenty, rounded up to ten.
func suggest_time_limit(track: int = DotTimerTrack.MAIN, style_id: StringName = &"normal") -> DotResult:
	if store == null or zones == null:
		return DotResult.fail(DotError.CODE_STATE, "No map or no store.")
	var listed: DotResult = await store.top(zones.map_id, track, style_id, 25)
	if not listed.ok:
		return listed
	var rows: Array = listed.value
	if rows.size() < 5:
		return DotResult.success(0)
	var sum := 0.0
	for record in rows:
		sum += (record as DotTimerRecord).time
	var average_minutes := sum / float(rows.size()) / 60.0
	var attempts := clampf(12.0 / sqrt(maxf(average_minutes, 0.25)), 4.0, 16.0)
	var minutes := clampf(average_minutes * attempts + 5.0, 20.0, 120.0)
	return DotResult.success(int(ceil(minutes / 10.0)) * 10)


## The rank a time would take on a board, without filing anything.
func would_rank(time: float, track: int = DotTimerTrack.MAIN, style_id: StringName = &"normal") -> DotResult:
	if store == null or zones == null:
		return DotResult.fail(DotError.CODE_STATE, "No map or no store.")
	return await store.rank_for_time(zones.map_id, track, style_id, time)


## The run in progress for a player, or null.
func run_for(id: StringName) -> DotTimerRun:
	var found := player(id)
	return found.timer.run if found != null else null


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"tick_rate": tick_rate,
		"map": String(zones.map_id) if zones != null else "-",
		"zones": zones.zones.size() if zones != null else 0,
		"players": _players.size(),
		"styles": styles.size(),
		"store": store.describe() if store != null else "none",
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("map          %s" % (String(zones.map_id) if zones != null else "-"))
	out.append("authority    %s" % authoritative)
	out.append("tick rate    %d" % tick_rate)
	out.append("players      %d" % _players.size())

	for id in _players:
		var found: Player = _players[id]
		out.append("  %-16s %s" % [String(id), str(found.timer.run)])

	return out
