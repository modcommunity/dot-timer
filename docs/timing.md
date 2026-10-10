# Timing

## A time is a tick count plus two fractions

**A time is a tick count plus two sub-tick fractions, and it is comparable between servers.** Everything here follows from that.

A float accumulator drifts: adding 1/128 to a running total ten thousand times does not give what multiplying does, and two servers with different frame pacing reach different totals for identical play. A tick counter is exact, and a tick counter alone quantises every run to the tick, so the same run is worth up to 15 ms more on a 64 Hz server than on a 128 Hz one. On a leaderboard sorted to the millisecond, the tick rate would decide the ordering.

So: whole ticks, **minus** the fraction of the first tick already spent when the player crossed the start line, **plus** the fraction of the last tick spent reaching the finish. Both come from `DotTimer._crossing_fraction`, which interpolates the signed distance to the zone's surface along the segment the player moved over. `_test_tickrate_agreement` holds 64 Hz and 128 Hz to under a millisecond.

- **The finish fraction is added.** The finishing tick is never counted by `DotTimerRun.advance` (the run is `FINISHED` before it runs), so its fraction is added where the start's is subtracted. Getting it backwards loses one tick, a different amount at each tick rate, which is exactly the dependence the fractions exist to remove.
- **There is one formula.** `DotTimerNet.Finish.time()` once kept its own copy and was two fractions short of every finish a server announced. A second copy of the arithmetic is the bug.
- **Splits use the fractions too**, not the tick, or they are off against a record set at another tick rate.
- **A signed distance of exactly zero is the boundary**, neither inside nor outside; it terminates the crossing at whichever end it is on. Folded into "inside", it threw the fraction away whenever a player landed on a line, which on a course built from round numbers is every run.

## Why it depends on nothing

`DotTimerSample` is the whole answer. The timer needs a position, a velocity and whether the player is grounded; it does not need to know they came from a `DotFpsState`, a 2D body, a replay being scrubbed or a bot. Naming any of those would make the addon fail to parse in a project without them. Three things fall out of that:

- **The same timer serves 2D and 3D**: one records table, one leaderboard, one replay format.
- **A server that does not use dot-player-controller still gets timers.**
- **The movement half and the records half of a style are separate classes.** `DotFpsStyle` (dot-player-controller) transforms the tunables and filters the command; `DotTimerStyle` (here) says whether runs count, what they are worth and the shortest recordable run. Paired by id and enforced by nothing, because enforcing it would mean naming a class that may not exist.

## The tick rate

The rate is configuration, and it is the one that can ruin a records table. A timer counting 128 ticks a second on a server stepping 64 produces times exactly twice what they should be, and **nothing anywhere errors**. That is why the rate is not an export somebody has to remember. The chain, every link of which is silent when it breaks:

```
server.cfg:  sv_tickrate 128
      ↓      dot-server, _apply_tickrate()
Engine.physics_ticks_per_second
      ↓      DotTimerConfig.tick_rate == 0 means "ask the engine"
DotTimerManager.adopt_engine_tick_rate()
      ↓
DotTimerRecord.tick_rate        ← so a disputed time can be checked afterwards
```

- **`sv_tickrate` belongs in `server.cfg`, not `autoexec.cfg`.** It is `FLAG_STARTUP_ONLY`, and dot-server execs `server.cfg` before the listener for exactly that reason while `autoexec.cfg` runs after and has it refused. `--sv-tickrate=128` and `+sv_tickrate 128` on the command line work too.
- **`set_tick_rate` abandons runs in progress**, the only honest option: a run half-counted at 64 and half at 128 is neither, and files. Abandoning costs one attempt; the alternative costs the leaderboard its meaning.
- **`tick_rate_matches_engine()` is checked at every map change and warns, but only on an authoritative timer.** A mirroring client counts at the rate the server told it (which is what makes a run comparable on a client rendering at 60), while its own `physics_ticks_per_second` is whatever its project exported; a browser build runs at 60. Warning there told every web client it would file wrong times, about a client that files none.

## The timer

- **A run starts on LEAVING the start zone.** The start zone is where a player builds speed; timing from entry would time their run-up. It also means the boundary is crossed once per attempt in a known direction, which is what makes the fraction meaningful.
- **Standing in the start zone again ends a live run, as a reset**, so the clock reads zero while the player builds speed, as in every timer of the genre. Before, a re-entered start zone was nothing and the run counted on until they left again.
- **Zones on another track are reported but never acted on.** Real maps route a bonus across the main line constantly; a timer that reacted to any finish would end every main run halfway through.
- **The timer decides; the game acts.** Nothing here teleports, kills, changes gravity or refuses a jump. `effect_requested` (fired once on entry, filtered by the run's track, last in the tick because a host's respawn handler calls straight back in through `stop()`), `effects_changed`, `stage_requested` and `teleport_requested` say what the map or player asked for, because "teleport" means something different in a first-person controller, a 2D game and a replay being scrubbed. A zone kind with no rule here is legitimate, so a signal nobody fires looks correct from inside this addon: when adding one, check that something emits it.
- **`is_inside(kind)` answers only for EFFECT zones**; `in_zone(kind)` is the membership query. The name difference is the point.

## What can_record refuses

**`authoritative` is a security boundary, not a preference.** A client runs its own timer so its HUD updates on the tick; if that copy could file, a modified client would announce world records. `can_record` refuses on a non-authoritative timer before anything else. Every other refusal exists because of a real exploit:

- **The minimum time** stops a start and finish drawn close enough to touch producing an unbeatable 0.02 s record.
- **The checkpoint and taint flags are sticky for the whole attempt**: clearing them when the player stops cheating would let anybody file the last thirty seconds of a map.
- A style that allows checkpoints files a practised run **flagged** (`extra.segmented`) rather than refusing it.

## Rules

- **Start**: `start_speed_cap`, `start_ground_seconds` (judged on the last grounded stretch, so a hop through the start does not count as standing in it), `refuse_vertical_start`, all waived below `start_rules_below` and overridden by the start zone's payload. Refusals are emitted (`start_refused`) for the same reason `record_refused` is.
- **Finish**: `enforce_stages` (every stage line crossed; a map opts out in its zone file), and `VALIDATOR` / `CHECKER` zones (a checker reached without its validator marks the run skipped and asks the host to send the player back).
- **During**: `pause_checked` (not in the start or end, grounded, nearly still; the snapshot is what resuming puts back); `sample.noclip` stops a run; `teleport_stop_distance` stops one on an unexplained jump (off by default; a teleport this timer asked for is expected, and `expect_teleport()` declares any other).
- **Slow motion**: `DotTimerStyle.timescale`, carried on the run and the record.

## Wiring it to a controller

```gdscript
# once
manager.set_styles(DotTimerStyle.defaults())
manager.set_zones(zone_set)
manager.add_player(player_id, display_name)

# every simulated tick, per player, from the movement loop — never from _process
manager.tick_player(
    player_id,
    controller.state.position,
    controller.state.velocity,
    controller.state.is_grounded(),
    alive,
    controller.state.yaw,
    controller.state.pitch
)

# when the run ends
manager.note_stats(player_id, controller.stats.to_dictionary())
```

and, because a style has two halves:

```gdscript
controller.set_style(movement_styles[id])   # DotFpsStyle  — the movement
manager.set_player_style(player_id, id)     # DotTimerStyle — the ranking
```

`DotTimerRules` holds what runs inside the simulation, as pure static functions, because clamping speed at the start line changes where the player ends up and must happen on both machines on the same tick:

```gdscript
# in the movement loop, after the timer has ticked
if timer.in_zone(DotTimerZone.Kind.START):   # NOT is_inside: that is effects only
    state.velocity = DotTimerRules.clamp_prespeed(state.velocity, movement_style.prespeed_limit)
```

`prespeed_limit` is the movement style's (`DotFpsStyle`); `DotTimerStyle.start_speed_cap` is the timer's own start rule. `clamp_prespeed` caps the **horizontal** speed only. Clamping the vertical too would cancel a fall, so somebody dropping into the start would hang in the air: the first thing a re-implementation gets wrong.

## 2D

The timer works on positions, so a 2D game gets tracks, stages, styles, records, replays and leaderboards from the same addon and files into the same table. The 2D-specific part is one line in the host:

```gdscript
sample.position = Vector3(body.position.x, body.position.y, 0.0)
```

against zones authored with `DotTimerZoneVolume2D`. **The third axis is the trap**: a rectangle has zero thickness on Z, and a box with zero thickness contains nothing, so a zone built by hand from 2D coordinates never fires, with no error anywhere. `DotTimerZone.flatten_for_2d()` makes the box unbounded on Z and `DotTimerZoneVolume2D` applies it without being asked. Replays cost nothing extra: the third axis is always zero and delta-encodes to nothing.

## Deliberately not here

- **Chat, a menu or a `!wr` command.** Console commands belong to dot-server and chat to the game; this exposes the queries (`profile`, `top_players`, `recent_records`, `maps_done`, `maps_left`, `section_records`, `suggest_time_limit`, `would_rank`).
- **A ranking across games.** Points and rank on this server are here, because every formula needs the board; what a game reports to the site is dot-leaderboard's, and so is sending records off the server.
- **A ghost.** `DotTimerReplayPlayer` gives the pose; what to draw is the game's.
- **Segmented styles' save-and-restore of a position.** The run flags are recorded; the position is the game's to save.
- **Anti-cheat beyond the structural refusals.** Detecting a scripted strafe belongs where the input is.
