@tool
class_name DotTimerConfig
extends DotConfig

## Every number a timer server is configured with. Layered like every [DotConfig]:
## exported defaults, then a JSON file, then [code]DOT_TIMER_*[/code] environment
## variables, then [code]--timer-*[/code] arguments.
##
## [b]Why this exists at all.[/b] Every other addon in the family has one —
## [code]DotFpsTunables[/code], [code]DotServerConfig[/code],
## [code]DotPropLimits[/code] — and the reason is always the same: a dedicated server
## has to be reconfigured without an editor and without a rebuild, at three in the
## morning, by somebody who is not the person who wrote it. Exports on a node are not
## that. This was the one gap in the set.
##
## [b]The tick rate is the field that matters most here[/b], because it is the only
## one that can silently invalidate a records table. See [member tick_rate].

@export_group("Simulation")

## Ticks per second the timer counts in. [b]Must match the host's simulation rate.[/b]
##
## [b]0 means "take it from the engine", and that is the right answer on a server.[/b]
## dot-server writes [member Engine.physics_ticks_per_second] from its own
## [code]sv_tickrate[/code] cvar, so a timer that reads the engine is a timer an
## operator configures in [code]server.cfg[/code] along with everything else — one
## number, one place. A fixed value here is for a client or a test that has no server
## to ask.
##
## [b]Getting this wrong does not fail loudly.[/b] A timer counting 128 ticks a second
## on a server stepping 64 produces times exactly twice what they should be, and
## nothing anywhere errors — the runs finish, the records file, and the leaderboard is
## simply wrong by a factor of two against every other server. That is why
## [method DotTimerManager.adopt_engine_tick_rate] exists and why a record carries the
## rate it was set at.
@export_range(0, 240, 1) var tick_rate: int = 0

## Fall back to this when [member tick_rate] is 0 and the engine has not been set.
##
## 128 rather than 60: this genre runs 100 or 128 tick servers, and a timer that
## quietly defaulted to the engine's 60 would produce times a fifth coarser than
## anybody expects on a server whose operator never set the cvar.
@export_range(1, 240, 1) var default_tick_rate: int = 128

@export_group("Records")

## Whether finished runs are offered to the store at all.
@export var record_runs: bool = true

## Where a [DotTimerStoreFile] keeps its boards. Empty keeps records in memory only.
##
## Under [code]user://[/code] by default, because that is the one directory a server
## can write on every platform including the browser — where it is an IndexedDB
## mirror that needs an explicit flush, which the store does.
@export var records_directory: String = "user://records"

## Boards written per flush before the rest wait for the next one.
##
## Bounded because a map change can dirty every board on the map at once, and writing
## forty files inside one frame is a stall a player feels.
@export_range(1, 256, 1) var flush_batch: int = 16

@export_group("Replays")

## Whether replays are recorded at all.
##
## Costs memory per player in a run and most of it is thrown away — see
## [DotTimerReplayRecorder]. On by default because a timer without replays is half a
## timer; off is the right answer for a thirty-slot server with 256 MB.
@export var record_replays: bool = true

## Where replays are kept. Empty keeps them in memory only.
@export var replays_directory: String = "user://replays"

## Longest run that will be recorded, in seconds.
@export_range(10.0, 7200.0, 10.0) var max_replay_seconds: float = 1200.0

@export_group("Rules")

## Speed a fast player is assumed to reach, in m/s, for the thin-zone warning.
##
## Used only by [method DotTimerZoneSet.thin_zones], which is advisory — but it is the
## first thing to look at when a zone "does not work", and the right number is a
## property of the game rather than of the addon. A surf server sets this high.
@export_range(1.0, 500.0, 1.0) var fastest_expected_speed: float = 40.0

## Whether practice checkpoints exist at all.
##
## The server's switch. What using one COSTS is the style's — see
## [member DotTimerStyle.allow_checkpoints]. Off is for a competition evening; on is
## how anybody learns a map.
@export var allow_checkpoints: bool = true

## Whether a client's own timer may file records. [b]Always false on a client.[/b]
##
## Here as well as on the manager so it can be forced off from a config file: a
## build that shipped with it on is a build a modified client can announce world
## records from, and the fix has to be reachable without a rebuild.
@export var authoritative: bool = false


func env_prefix() -> String:
	return "DOT_TIMER_"


func cli_prefix() -> String:
	return "--timer-"


func validate() -> DotResult:
	if tick_rate < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"tick_rate must be 0 (take it from the engine) or positive.",
			"%d" % tick_rate
		)

	if default_tick_rate < 1:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"default_tick_rate must be at least 1.",
			"%d" % default_tick_rate
		)

	if record_runs and records_directory == "":
		# Not an error: a server that times without keeping records is a legitimate
		# thing (a practice server, a client's own display). Said out loud because
		# the combination reads like a mistake and usually is one.
		DotLog.info(
			"timer.config",
			"records are enabled with no directory; they will be kept in memory only"
		)

	return DotResult.success(null)


## The rate the timer should actually count in.
##
## [param engine_rate] is [member Engine.physics_ticks_per_second], which on a
## dot-server is whatever [code]sv_tickrate[/code] was set to. Passed in rather than
## read here so this class stays a pure description and a test can supply one.
func effective_tick_rate(engine_rate: int = 0) -> int:
	if tick_rate > 0:
		return tick_rate

	if engine_rate > 0:
		return engine_rate

	return default_tick_rate


func describe_summary() -> String:
	return "%s tick, records %s, replays %s" % [
		("engine" if tick_rate == 0 else str(tick_rate)),
		("off" if not record_runs else (
			"memory" if records_directory == "" else records_directory
		)),
		("off" if not record_replays else "on"),
	]
