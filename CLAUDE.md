# dot-timer

Speedrun timers for Godot 4: bunny-hop, surf, climb courses, and anything else run against the clock. Zones, tracks and stages, styles, practice checkpoints, records in memory, a file or SQL, points and ranks, replays, and a HUD, for 2D and 3D alike.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to timing. The reasoning is in [docs/](docs/README.md).

**Only dot-core is a dependency.** Not dot-player-controller, not dot-net, not dot-server, not dot-sql (its driver is held duck-typed). That is load-bearing: [timing.md](docs/timing.md#why-it-depends-on-nothing).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/timing.md](docs/timing.md) | `DotTimer`, `DotTimerRun`, the tick rate, start/finish/pause rules, `can_record`, wiring to a controller, 2D |
| [docs/zones.md](docs/zones.md) | zones and zone files, the painter, zone checks, stages, practice checkpoints |
| [docs/records.md](docs/records.md) | `DotTimerStore` and its three implementations, points, the manager's filing |
| [docs/replays.md](docs/replays.md) | the replay container, recorder, player, and writing them to disk |
| [docs/hud.md](docs/hud.md) | `DotTimerHud` |
| [docs/testing.md](docs/testing.md) | the suites, the store contract, adding a check |
| [docs/history.md](docs/history.md) | the bugs the suites and the games found, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_timer/core/` | data and pure functions: config, track, zone, zone set, style (the records half), run, record, sample, rules, points, rank titles |
| `addons/dot_timer/runtime/` | `DotTimer` (one player), `DotTimerManager` (the node a game adds), zone index, practice checkpoints |
| `addons/dot_timer/zones/` | authoring: `DotTimerZoneVolume3D` / `2D`, `DotTimerZonePainter` (in-game, two marks a zone) |
| `addons/dot_timer/store/` | `DotTimerStore` (abstract, every read awaited), memory, file, SQL |
| `addons/dot_timer/replay/` | container (quantised, delta-encoded), recorder, player |
| `addons/dot_timer/net/` | `DotTimerNet`: what replicates, without importing dot-net |
| `addons/dot_timer/ui/` | `DotTimerHud`: no art |
| `examples/` | `timer_selftest`, `timer_2d_selftest`, `timer_records_selftest`, `timer_sql_live`, `timer_store_contract.gd`, `hud_preview` (for a screenshot) |

## Running and testing

- The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timer_selftest.tscn`, `timer_2d_selftest.tscn` and `timer_records_selftest.tscn`; `../dot-sql/tools/test_live.sh . res://examples/timer_sql_live.tscn` against the three databases for anything in the SQL store. [testing](docs/testing.md)
- The 2D suite is not a formality: it found a bug in the shared code on its first run.
- A change here is not done until game-g2gfast's and game-playground's suites agree; three of the bugs here were found from a game.
- The HUD is checked by a picture: `tools/screenshot.sh dot-timer out.png --scene res://examples/hud_preview.tscn` from game-dev.

## Rules that bite

Short forms; the reasoning is in the linked file.

**Time**

- A time is whole ticks minus the start fraction plus the finish fraction (the finishing tick is never counted by `advance`, so its fraction is ADDED). One formula: `DotTimerNet.Finish` uses the run's, never a copy. [timing](docs/timing.md#a-time-is-a-tick-count-plus-two-fractions)
- A signed distance of exactly zero is the boundary, neither side. [timing](docs/timing.md#a-time-is-a-tick-count-plus-two-fractions)
- `sv_tickrate` goes in `server.cfg`, never `autoexec.cfg`; `DotTimerConfig.tick_rate = 0` asks the engine. A wrong rate errors nowhere and doubles every time. [timing](docs/timing.md#the-tick-rate)
- `set_tick_rate` abandons runs in progress, on purpose. The engine-rate warning is for an authoritative timer only. [timing](docs/timing.md#the-tick-rate)
- A run starts on LEAVING the start zone; standing in it again ends a live run as a reset. [timing](docs/timing.md#the-timer)
- Zones on another track are reported, never acted on. [timing](docs/timing.md#the-timer)
- **The timer never moves, kills or teleports anybody.** It emits `effect_requested`, `stage_requested`, `teleport_requested`; the host acts. [timing](docs/timing.md#the-timer)
- `authoritative` is a security boundary: a non-authoritative timer never files. [timing](docs/timing.md#what-can_record-refuses)
- `is_inside(kind)` answers for EFFECT zones only; `in_zone(kind)` is membership. [timing](docs/timing.md#the-timer)
- `clamp_prespeed` caps HORIZONTAL speed only, and runs inside the simulation on both machines. [timing](docs/timing.md#wiring-it-to-a-controller)
- Call `tick_player` from the simulated tick, never `_process`. [timing](docs/timing.md#wiring-it-to-a-controller)
- A 2D game's zones are flattened on Z (`flatten_for_2d`, automatic in `DotTimerZoneVolume2D`); a zero-thickness box contains nothing. [timing](docs/timing.md#2d)

**Zones**

- A zone is data, not a node. Zone ids are never reused. [zones](docs/zones.md#zones-are-data)
- `problems()` is per zone, `route_problems()` per track (START, END, SPAWN, RESPAWN, stages); there is no track-agnostic respawn. `meta.pitless_tracks` exempts a route. [zones](docs/zones.md#checking-a-zone-file)
- `thin_zones()` is judged per axis; the fall speed defaults to the run speed on purpose. [zones](docs/zones.md#checking-a-zone-file)
- `fingerprint()` ignores comments and ids. [zones](docs/zones.md#checking-a-zone-file)
- A stage zone without a `destination` sends the player to `Vector3.ZERO`, silently. A stage out of range is refused, never clamped; going to a stage stops the run. [zones](docs/zones.md#stages)
- Saving a checkpoint is free, loading taints the attempt, and the taint is sticky. `DotTimerManager.allow_checkpoints` (does practice exist) is not `DotTimerStyle.allow_checkpoints` (may a practised run rank). [zones](docs/zones.md#practice-checkpoints)

**Records and replays**

- A store never decides whether a record is allowed; `can_record` does, on the authoritative timer. [records](docs/records.md#the-store)
- Every store read is awaited; only `peek_*` is synchronous, and `null` there means "not known yet". [records](docs/records.md#the-store)
- `examples/timer_store_contract.gd` runs unchanged against every store: add a check there, never a copy. [records](docs/records.md#one-contract-three-stores)
- Filenames from ids go through `DotTimerStoreFile.safe_component`, never a second sanitiser. [records](docs/records.md#the-file-store)
- The file store must be flushed (the manager does it every `flush_seconds` and on exit) and refuses an empty directory. [records](docs/records.md#the-file-store)
- SQL: improvements are conditional (`WHERE time > ?`); never write `SET a = ..., b = a + ...` (MySQL reads the new `a`). [records](docs/records.md#the-sql-store)
- A board is re-scored whenever its record changes. Ranks are shared by ties. [records](docs/records.md#points)
- `player_id` is a per-scope pseudonymous id, never a site user id. [records](docs/records.md#the-store)
- Replays sample at a time, never step per frame; yaw the short way round; never blend across a teleport frame. [replays](docs/replays.md#playback)
- Only a kept run's replay is written, after its run-out; a failed write is logged, never turned into a refused record. [replays](docs/replays.md#writing-to-disk)

## Where a game plugs in

| To change | Where |
| --- | --- |
| How a server is configured | `DotTimerConfig`, layered like every `DotConfig` |
| What the tick rate is | `sv_tickrate` in `server.cfg`; `DotTimerConfig.tick_rate = 0` asks the engine |
| Whether practice mode exists | `DotTimerManager.allow_checkpoints` |
| Whether a practised run may rank | `DotTimerStyle.allow_checkpoints` |
| Where records live | `DotTimerStore` subclass on `DotTimerManager.store`; `DotTimerStoreSql` for a database |
| How records are scored | `DotTimerConfig.points_formula` (curve / tiered / placement), `points_weighting` |
| What standings are called | `DotTimerManager.titles = DotTimerRankTitles.from_array(...)` |
| Start rules | `DotTimerStyle.start_speed_cap`, `start_ground_seconds`, `refuse_vertical_start`; a start zone's payload overrides |
| Whether every stage must be passed | `DotTimerConfig.enforce_stages`, or the zone file's `meta.enforce_stages` |
| A shortcut a map closes | `VALIDATOR` / `CHECKER` zones, paired by `number` |
| What a style is worth | `DotTimerStyle`, and `points_for` to change the formula |
| How the movement changes per style | `DotFpsStyle` in dot-player-controller |
| A new kind of volume | `DotTimerZone.Kind.CUSTOM` plus `payload`, read on `effect_requested` |
| What a teleport / respawn / slay does | `effect_requested`, always |
| The map's difficulty tier | `DotTimerZoneSet.meta["tier"]`, or override `DotTimerManager.map_tier` |
| How zones are authored | `DotTimerZoneVolume3D` / `2D`, or `DotTimerZonePainter` |
| What the HUD looks like | `DotTimerHud` exports, or a subclass |
| Speed units on the HUD | `DotTimerHud._stats_line` and the `u/s` conversion |
| What replicates | `DotTimerNet.RunState` / `Finish`, written by a dot-net bridge |
| Replay flags (ducked, jumped, teleported) | the `replay_flags` argument of `tick_player` |

Deliberately not here: chat commands, menus, a cross-game ranking, sending records off the server (dot-leaderboard), drawing a ghost, the save-and-restore of a segmented run's position, and anti-cheat beyond the structural refusals. [timing](docs/timing.md#deliberately-not-here)
