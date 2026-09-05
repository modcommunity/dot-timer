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

## The map's zones were replaced.
signal zones_changed(zones: DotTimerZoneSet)

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

	## Practice checkpoints. Per player, because they are a player's own working set.
	var checkpoints: DotTimerCheckpoints = null


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

	if p_config.record_runs and p_config.records_directory != "":
		var file_store := DotTimerStoreFile.at(p_config.records_directory)
		file_store.flush_batch = p_config.flush_batch
		store = file_store
	elif store == null:
		store = DotTimerStoreMemory.new()

	set_tick_rate(p_config.effective_tick_rate(Engine.physics_ticks_per_second))

	for id in _players:
		(_players[id] as Player).timer.authoritative = authoritative

	DotLog.info(CHANNEL, "timer configured", {
		"summary": p_config.describe_summary(), "tick_rate": tick_rate
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

	for id in _players:
		var player: Player = _players[id]
		var bound := player.timer.bind(set, tick_rate)
		if not bound.ok:
			return bound

	zones_changed.emit(set)

	if set != null:
		for problem in set.problems():
			DotLog.warn(CHANNEL, "zone problem", {
				"map": String(set.map_id), "problem": problem
			})

		# Advisory, and checked here because a map change is the moment somebody is
		# looking: at 128 Hz a player at 40 m/s crosses 31 cm in a tick, and a finish
		# volume thinner than that is one the fastest players pass straight through
		# without the run ever ending.
		var speed := config.fastest_expected_speed if config != null else 40.0

		for zone in set.thin_zones(speed, tick_rate):
			DotLog.warn(CHANNEL, "a zone is thinner than one tick of travel", {
				"map": String(set.map_id),
				"zone": zone.describe(),
				"at": "%.0f m/s, %d Hz" % [speed, tick_rate],
			})

	if not tick_rate_matches_engine():
		# The one misconfiguration that produces plausible wrong times rather than an
		# error. Said at every map change because that is when somebody is watching.
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
	if config != null:
		player.recorder.max_seconds = config.max_replay_seconds

	var bound := player.timer.bind(zones, tick_rate)

	if not bound.ok:
		return bound

	player.timer.style = style_for(&"normal")

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
	)
	player.timer.effect_requested.connect(
		func(zone: DotTimerZone) -> void: effect_requested.emit(id, zone)
	)
	player.timer.effects_changed.connect(
		func() -> void: effects_changed.emit(id, player.timer.active_effects())
	)

	_players[id] = player

	return DotResult.success(player)


func remove_player(id: StringName) -> bool:
	if not _players.has(id):
		return false

	var player: Player = _players[id]

	# Stopped rather than dropped, so anything listening for the end of a run gets
	# one. A player who disconnects mid-run leaves a run that never ended otherwise,
	# and whatever was tracking it leaks.
	player.timer.stop(DotTimer.REASON_RESET)
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
	buttons: int = 0
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

	if record_replays and found.recorder.recording:
		var flags := DotTimerReplay.FLAG_GROUNDED if grounded else 0
		found.recorder.capture(position, yaw, pitch, flags)


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

	player_stopped.emit(id, run, reason)


func _on_finished(id: StringName, run: DotTimerRun) -> void:
	var found := player(id)

	if found == null:
		return

	found.last_finished = run
	found.last_replay = found.recorder.finish(run.time())

	player_finished.emit(id, run)

	if not record_runs:
		return

	var allowed := found.timer.can_record(run)

	if not allowed.ok:
		# The recorder is emptied here rather than at the top: a refused run still
		# produced frames, and holding them until the next run would double the peak.
		found.last_replay = null
		record_refused.emit(id, run, allowed.error.message)
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

	_file(found, record)


func _file(found: Player, record: DotTimerRecord) -> void:
	# The points are computed before the write, against the board's CURRENT record,
	# so a run that becomes the new record is scored against the one it beat rather
	# than against itself. Scoring after the write would give every new record a
	# closeness of exactly 1 and make the first clear of a map worth the same as a
	# perfect one.
	var style := style_for(record.style_id)
	var existing_best := 0.0

	if store != null:
		var listed := store.top(record.map_id, record.track, record.style_id, 1)
		if listed.ok and (listed.value as Array).size() > 0:
			existing_best = (listed.value[0] as DotTimerRecord).time

	if style != null:
		record.points = style.points_for(record.time, map_tier(), existing_best)

	var wrote := store.put(record)

	if not wrote.ok:
		record_refused.emit(found.id, found.last_finished, wrote.error.message)
		found.last_replay = null
		return

	var previous: DotTimerRecord = (
		wrote.value if wrote.value is DotTimerRecord else null
	)

	if previous != null and not record.beats(previous):
		# The store kept the old one, which is correct: the run was slower. Still an
		# acceptance rather than a refusal — the player did finish, cleanly, and the
		# HUD wants to say by how much they missed. The replay goes, because it is a
		# replay of a run nothing is keeping.
		found.last_replay = null

	var rank_result := store.rank_of(
		record.map_id, record.track, record.style_id, record.player_id
	)

	record_accepted.emit(
		record, previous, int(rank_result.value) if rank_result.ok else 0
	)

	_persist_replay(found, record)


## Writes the replay of a run the store kept, if replays are being kept on disk.
##
## Failure is logged and swallowed on purpose: the record is already in the store and
## the run already counted. A full disk must not turn an accepted record into a
## refused one, and the caller has emitted [signal record_accepted] before this runs.
func _persist_replay(found: Player, record: DotTimerRecord) -> void:
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
	if zones == null:
		return 1

	return clampi(int(zones.meta.get("tier", 1)), 1, 10)


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
