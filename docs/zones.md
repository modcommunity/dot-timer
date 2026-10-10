# Zones, stages and practice

## Zones are data

**A zone is data, not a node.** It survives JSON, is comparable between a client and a server, and can be drawn by an admin standing in the map with a console open. That last one is not a nice-to-have: surf and hop maps are made by people who are not the server operators, ship as geometry, and get their zones added afterwards, which is what the genre's community zone editors have always done. A timer without an in-game painter can only be used on maps whose author happened to zone them.

Zones are AABBs in `Vector3`. Both authoring routes write the same `DotTimerZoneSet`:

| Route | For |
| --- | --- |
| `DotTimerZoneVolume3D` / `2D` in a scene, then `collect()` | A mapper building the level in Godot |
| `DotTimerZonePainter`, two marks per zone | An admin adding a bonus to somebody else's map |

Three details in the painter are each a bug that would otherwise be found in production:

- **It adds height above the marked corners.** Both marks are taken at the player's feet, so without it every hand-drawn zone is a flat sheet nothing ever enters.
- **Zone ids are never reused.** A deleted zone's id going to the next one drawn silently repoints every replay crossing mark and every "zone 12 is wrong" report.
- **`mark_point` replaces rather than adds.** A track has one spawn; re-marking means "here instead".

`DotTimerTrack` is 0 for the main route and 1..8 for bonuses. `DotTimerTrack.parse` returns -1 for an unknown track rather than falling back to the main one.

## Checking a zone file

- **`DotTimerZoneSet.problems()` returns every problem**, not the first: a mapper with forty zones wants the list. It refuses a painter's save.
- **`thin_zones()` is advisory, and the first thing to check when a zone "does not work".** At 128 Hz a player at 30 m/s crosses 23 cm in a tick, and a finish volume thinner than that is never sampled with the player inside it: the run never ends, for the fast players only. **It is judged per axis**: X and Z against `fastest_expected_speed`, Y against `fastest_expected_fall_speed`, which is **zero, meaning "the same number", by default**. Guessing low there silences the warning on the most common defect in an imported map: a pit volume drawn as a thin horizontal plane, which the engines those maps were built for caught with swept trigger tests and dot-timer does not. Lower it only once a game knows how far its players can fall (a climbing course's height-band splits are the case that wants it).
- **`route_problems()` is the per-track check, and `problems()` is not one.** The timer acts only on zones of the run's own track, so a RESPAWN on the main route catches nobody on bonus 1, and there is no track-agnostic respawn. `problems()` passes a bonus with a start, an end and nothing else while every player who falls off it falls for ever. `route_problems()` asks every route (a track with any START, END or STAGE; a track with only a SPAWN is a sandbox and is asked nothing) for a START, an END, a SPAWN (or `spawn_for` falls back to the main one), a RESPAWN, and stages 1..n. A route that genuinely cannot be fallen off is declared under `meta.pitless_tracks`, and a declaration naming a track that has a pit or is not a route is itself reported, so the exemption cannot outlive its reason. It is separate from `problems()` on purpose: a half-drawn bonus is something an admin saves on the way to finishing it. `DotTimerManager` warns `incomplete route` on load, and `describe_lines()` prints `INCOMPLETE`.
- **`fingerprint()` ignores comments and ids.** Moving a finish line invalidates every record on the map; correcting a typo does not, and a records system that punished tidying up is one nobody tidies up.

## Stages

A staged map is a course divided into numbered sections with a line between each. The model: `DotTimerZone.Kind.STAGE` splits a run with a sub-tick fraction, `DotTimerRun.splits` holds a time per stage, `DotTimerZoneSet` answers `stage_count(track)` and `playable_tracks()`, and every zone has a `destination` and a `destination_yaw`. The navigation half:

| | |
| --- | --- |
| `DotTimerZoneSet.stage_zone(track, n)` | the zone "go to stage 3" resolves against |
| `DotTimerManager.stage_count(track)` / `tracks()` | how many stages, which routes |
| `DotTimerManager.request_stage(id, n)` | `!s3`. Refuses out of range rather than clamping |
| `DotTimerManager.restart_stage(id)` | `!rs`, meaning the stage you are on |
| `DotTimerManager.stage_splits_for(id)` | the player's own best split per stage |
| `stage_requested(player_id, number, zone)` | **the host moves them**, not this addon |

- **The run is stopped, not tainted.** A player teleported into the middle of a map has not run the first half; practice checkpoints are the mechanism for "keep my time while I learn this".
- **A stage out of range is refused.** A player who typed `!s9` on a five-stage map and was silently put on stage 5 has no way to tell.
- **A stage zone with no `destination` resolves to `Vector3.ZERO`**, which on most maps is a point in the sky. Nothing errors; the player is dropped out of the world. game-g2gfast's `G2GMap.zone_stage` exists to make forgetting it hard.
- **The timer still moves nobody.**

Section records are filed as a stage's second line is crossed, from runs clean so far; sections earn no points.

## Practice checkpoints

After the timer itself this is the most-used feature on a surf or hop server: a four-minute map with one hard section is four minutes of walking back per attempt without it.

- **Saving is free; restoring is what costs the run.** Saving on the way past a section is a habit, and punishing the habit rather than the shortcut punishes the wrong thing. `load_current()` calls `DotTimer.note_checkpoint_used()`; `peek()` does not, which is what a HUD uses.
- **The taint is sticky for the whole attempt.** Clearing the checkpoint set does not launder the run, or there is a one-keypress route to filing a segmented run as a clean one.
- **Two switches, two questions.** `DotTimerManager.allow_checkpoints` (the server's): does practice mode exist? `DotTimerStyle.allow_checkpoints` (the style's): may a run that used one still be filed (flagged `extra.segmented`)? One switch for both made a ranked style one nobody could learn the map on.
- **A style change leaves the saved set alone**: confiscating somebody's checkpoints because they switched style would confiscate the reason they switched.
