# dot-timer

Speedrun timers for Godot 4: bunny-hop, surf, KZ, and anything else run against the
clock.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first — no
autoloads, `DotNodeRef` instead of scene paths, `DotResult` for anything fallible,
`Dot`-prefixed class names, layered configuration, `describe()` on anything stateful.
This file is only what is specific to timing.

**Only dot-core is a dependency.** Not dot-fps-controller, not dot-net, not
dot-server. That is deliberate and it is load-bearing — see "Why it depends on
nothing" below.

## The one idea

**A time is a tick count plus two sub-tick fractions, and it is comparable between
servers.**

Everything here follows from that.

A float accumulator drifts: adding 1/128 to a running total ten thousand times does
not give what multiplying does, and two servers with different frame pacing reach
different totals for identical play. A tick counter is exact — and a tick counter
*alone* quantises every run to the tick, so the same run is worth up to 15 ms more on
a 64 Hz server than on a 128 Hz one. On a leaderboard sorted to the millisecond, that
means the tickrate decides the ordering.

So: whole ticks, minus the fraction of the first tick already spent when the player
crossed the start line, plus the fraction of the last tick spent reaching the finish.
Both come from `DotTimer._crossing_fraction`, which interpolates the signed distance
to the zone's surface along the segment the player moved over. Measured in
`examples/timer_selftest.gd::_test_tickrate_agreement`: 64 Hz and 128 Hz agree to
under a millisecond, where counting whole ticks puts them 7.8 ms apart.

**That test found a real bug in the first version of this**, and it is worth stating
because the shape recurs: the finishing tick is never counted by `DotTimerRun.advance`
— the run is `FINISHED` before it runs — so the fraction of that tick spent reaching
the line has to be *added*, where the starting fraction is *subtracted*. Storing "the
part after the line" and subtracting it lost exactly one tick, which is 7.8 ms at
128 Hz and 15.6 ms at 64 Hz: wrong, and wrong by a **different amount at each
tickrate**, which is precisely the dependence the fractions exist to remove.

## Layout

```
addons/dot_timer/
  core/
    dot_timer_config.gd     every number a timer server is configured with
    dot_timer_track.gd      main / bonus 1..8. A namespace, never instantiated
    dot_timer_zone.gd       one volume and what it means. Data, not a node
    dot_timer_zone_set.gd   every zone in a map. The JSON file mappers trade
    dot_timer_style.gd      the RECORDS half of a style. Movement is elsewhere
    dot_timer_run.gd        one attempt: ticks, splits, statistics
    dot_timer_record.gd     a finished run, as it is stored and sorted
    dot_timer_sample.gd     one tick of a player, as the timer sees them
    dot_timer_rules.gd      prespeed and speed limits, as pure functions
  runtime/
    dot_timer_zone_index.gd a uniform grid over the zones
    dot_timer.gd            the timer for one player
    dot_timer_checkpoints.gd  practice mode: +cp / +tp
    dot_timer_manager.gd    many players, the store, the replays. The node a game adds
  zones/
    dot_timer_zone_volume_3d.gd  authoring in the 3D editor
    dot_timer_zone_volume_2d.gd  authoring in the 2D editor
    dot_timer_zone_painter.gd    authoring from inside the game, two points at a time
  store/
    dot_timer_store.gd        where records live (abstract)
    dot_timer_store_memory.gd in a dictionary. The reference implementation
    dot_timer_store_file.gd   a JSON file per board, written atomically
  replay/
    dot_timer_replay.gd          the container: quantised, delta-encoded frames
    dot_timer_replay_recorder.gd records one, with a cap
    dot_timer_replay_player.gd   plays one back, sampled at a time
  net/
    dot_timer_net.gd        what replicates, without importing dot-net
  ui/
    dot_timer_hud.gd        the clock, the split, the speedometer. No art
```

## Why it depends on nothing

`DotTimerSample` is the whole answer. The timer needs a position, a velocity and
whether the player is on the ground; it does not need to know they came from a
`DotFpsState`, a 2D body, a replay being scrubbed or a bot. If it named any of those,
the addon would not compile in a project without them — and in GDScript that is not a
style preference, it is a parse error that takes every referencing script down with
it.

Three things fall out of that, and all three are the point:

- **The same timer serves 2D and 3D.** Zones are AABBs in `Vector3`; a 2D game passes
  `Vector3(x, y, 0)` against zones flattened with `DotTimerZone.flatten_for_2d()`.
  One records table, one leaderboard, one replay format for a surf map and a racing
  course. Getting that third axis wrong is the likeliest way to draw a 2D zone that
  never fires, which is why `flatten_for_2d` exists rather than being a comment.
- **A server that does not use dot-fps-controller still gets timers.**
- **The movement half and the records half of a "style" are separate classes.**
  `DotFpsStyle` (in dot-fps-controller) transforms the tunables and filters the
  command; `DotTimerStyle` (here) says whether runs count, what they are worth and
  what the shortest recordable run is. Paired by id, enforced by nothing, because
  enforcing it would mean naming a class that may not exist.

## Zones

**A zone is data, not a node** — it survives JSON, is comparable between a client and
a server, and can be drawn by an admin standing in the map with a console open. That
last one is not a nice-to-have: surf and bhop maps are made by people who are not the
server operators, ship as geometry, and get their zones added afterwards. The
community timers'
`sm_zones` is exactly `DotTimerZonePainter`, and a timer without it can only be used
on maps whose author happened to be using the same engine.

Both authoring routes write the same `DotTimerZoneSet`:

| Route | For |
| --- | --- |
| `DotTimerZoneVolume3D` / `2D` in a scene, then `collect()` | A mapper building the level in Godot |
| `DotTimerZonePainter`, two marks per zone | An admin adding a bonus to somebody else's map |

Three details in the painter are each a bug that would otherwise be found in
production:

- **It adds height above the marked corners.** Both marks are taken at the player's
  feet, so without it every hand-drawn zone is a flat sheet nothing ever enters.
- **Zone ids are never reused.** A deleted zone's id going to the next one drawn
  silently repoints every replay crossing mark and every "zone 12 is wrong" report.
- **`mark_point` replaces rather than adds.** A track has one spawn; re-marking means
  "here instead".

`DotTimerZoneSet.problems()` returns *every* problem rather than the first — a mapper
with forty zones wants the list, not forty rounds of save-and-retry — and
`thin_zones()` is advisory and is the first thing to check when a zone "does not
work": at 128 Hz a player at 30 m/s crosses 23 cm in a tick, and a finish volume
thinner than that is never sampled with the player inside it, so the run simply never
ends. For the fast players only, which is exactly the population that notices.

**`fingerprint()` deliberately ignores comments and ids.** Moving a finish line
invalidates every record on the map; correcting a mapper's typo does not, and a
records system that punished tidying up is one nobody tidies up.

## The tick rate is configuration, and it is the one that can ruin a records table

A timer counting 128 ticks a second on a server stepping 64 produces times exactly
twice what they should be — and **nothing anywhere errors**. The runs finish, the
records file, and the leaderboard is simply wrong by a factor of two against every
other server. That is why the rate is not an export somebody has to remember.

The chain, and every link in it is silent when it breaks:

```
server.cfg:  sv_tickrate 128
      ↓      dot-server, _apply_tickrate()
Engine.physics_ticks_per_second
      ↓      DotTimerConfig.tick_rate == 0 means "ask the engine"
DotTimerManager.adopt_engine_tick_rate()
      ↓
DotTimerRecord.tick_rate        ← so a disputed time can be checked afterwards
```

**`sv_tickrate` belongs in `server.cfg`, not `autoexec.cfg`.** It is
`FLAG_STARTUP_ONLY` — a live server cannot re-negotiate its tick rate — and dot-server
execs `server.cfg` *before* the listener for exactly that reason, while `autoexec.cfg`
runs after and has it refused. Putting it in the wrong one of the two fails quietly.
`--sv-tickrate=128` and `+sv_tickrate 128` both work too; the second only since
dot-server started applying the command line's cvar half before the listener.

**`set_tick_rate` abandons runs in progress, and that is the only honest option.** A
run is a count of ticks plus the duration one tick represents; change the second and
every tick already banked means something different. A run half-counted at 64 and half
at 128 produces a time that is neither, and files it. Abandoning costs somebody one
attempt; the alternative costs the leaderboard its meaning.

`tick_rate_matches_engine()` is checked at every map change and warns loudly, because
a map change is when somebody is watching.

## Practice mode

After the timer itself this is the most-used feature on a surf or bhop server. A
four-minute map with one hard section is four minutes of walking back per attempt
without it, and every timer in the genre has had `+cp` / `+tp` bound to a key for
fifteen years.

**Saving is free; restoring is what costs the run.** Pressing the save key on the way
past a section is a habit, and punishing the habit rather than the shortcut would be
punishing the wrong thing. `load_current()` calls `DotTimer.note_checkpoint_used()`;
`peek()` does not, which is what a HUD uses.

**The taint is sticky for the whole attempt.** Clearing the checkpoint set does not
launder the run — a player who could clear the flag by clearing their checkpoints
would have a one-keypress route to filing a segmented run as a clean one.

Two switches, and they are deliberately different questions:

| | Question | Where |
| --- | --- | --- |
| `DotTimerManager.allow_checkpoints` | Does practice mode exist on this server? | The server's |
| `DotTimerStyle.allow_checkpoints` | May a run that used one still be **ranked**? | The style's |

The second was originally used for both, and that was wrong: it made a ranked style a
style nobody could learn the map on, which is the opposite of what a records server
wants. A style change now leaves the saved set alone — confiscating somebody's
checkpoints because they switched to sideways would be confiscating the reason they
switched.

## 2D

The timer works on positions, not on a controller, so a 2D game gets tracks, stages,
styles, records, replays and leaderboards from the same addon a surf server uses — and
files into the same records table. The whole of the 2D-specific part is one line in
the host:

```gdscript
sample.position = Vector3(body.position.x, body.position.y, 0.0)
```

against zones authored with `DotTimerZoneVolume2D`, which does the one thing that is
easy to get wrong for you.

**The third axis is the trap.** A rectangle has zero thickness on Z, and a box with
zero thickness contains *nothing* — so a zone built by hand from 2D coordinates never
fires, silently, with no error anywhere. `DotTimerZone.flatten_for_2d()` makes the box
unbounded on Z and `DotTimerZoneVolume2D` applies it without being asked. Both are
checked in `examples/timer_2d_selftest.gd`.

Replays cost nothing extra: the container quantises three axes and the third is simply
always zero, which delta-encodes to nothing.

## The timer

**Starts on LEAVING the start zone.** The start zone is where a player builds their
speed up; timing from entry would time their run-up. It also means the boundary is
crossed exactly once per attempt, in a known direction, which is what makes the
sub-tick fraction meaningful.

**Zones on another track are reported but never acted on.** Real maps route a bonus
across the main line constantly, and a timer that reacted to any finish would end
every main run halfway through. Tested.

**The timer decides; the game acts.** Nothing here teleports, kills, changes gravity
or refuses a jump — `effect_requested` and `effects_changed` say what the map asked
for and the host does it, because "teleport" means something different in a
first-person controller, a 2D game and a replay being scrubbed.

**`authoritative` is a security boundary, not a preference.** A client runs its own
timer so its HUD updates on the tick rather than a round trip later; if that copy
could file records, a modified client would announce world records. `can_record`
refuses on a non-authoritative timer before it checks anything else.

Every other refusal in `can_record` exists because of a real exploit: the minimum time
stops a start and finish drawn close enough to touch producing an unbeatable 0.02
second record; the checkpoint and taint flags are sticky for the whole attempt,
because clearing them when the player stops cheating would let anybody file a record
for the last thirty seconds of a map.

## Replays

A six-minute run at 128 Hz is 46,000 frames. At a naive 32 bytes each that is 1.5 MB
per record, times six styles times nine tracks times every map on the server.
Quantising position to a millimetre and view to a tenth of a degree, and storing
per-frame deltas with keyframes for teleports, brings it under 12 bytes a frame —
about 250 KB for that run, which is a file a browser client can fetch while the map
loads. Measured in the self-test rather than asserted.

**Playback is sampled at a time, not stepped per frame.** The obvious implementation
advances an index once per rendered frame, which plays a 128 Hz replay at half speed
on a 60 Hz monitor. Asking for "the pose at t" also makes scrubbing free and makes
comparing two replays a matter of sampling both at the same t.

The yaw is interpolated **the short way round**. 179° to −179° is two degrees; a naive
lerp spins the model 358° the other way, once per lap, which reads as the replay being
corrupt.

**The recorder throws almost everything away**, and has to: a server records every
attempt because it cannot know which will be a record, and on a busy map that is
thirty players failing every ninety seconds. `discard()` on every run that beat
nothing, and a hard frame cap so a player who started the timer and went to make tea
does not accumulate an unbounded array.

**And the kept one is written to disk**, under `replays_directory`, at the end of
`_file()` — the one point where the store has actually kept the run. That was the
family's most repeated bug in its purest form: the recorder ran, `save()` and
`load_from()` existed, `DotTimerConfig.replays_directory` defaulted to `user://replays`
and **was read by nothing**, so a records server held the world-record replay in
`last_replay` and lost it at exit. Nothing errored, because a replay in memory looks
exactly like a replay that was kept.

Three decisions in that path:

- **Only replays of runs the store kept are written.** `last_replay` is already
  nulled everywhere the record was refused or the old one survived, so the file set is
  the record set. A replay of a run nothing is keeping is a file nothing will open.
- **A failed write is logged, not propagated.** The record is already in the store and
  `record_accepted` has already gone out. A full disk must not turn an accepted record
  into a refused one.
- **The filename goes through `DotTimerStoreFile.safe_component`, not a second
  sanitiser.** Both a map id and a player id reach it from the wire, so a `../` in
  either is a write outside the directory — and substitution is many-to-one, so
  without that function's hash suffix `surf_kitsune2` and `surf_kitsune3` share one
  file. That is the exact bug that once merged two maps into one leaderboard, and a
  second sanitiser in the same repository is how it comes back. The suite checks two
  ids that flatten to the same string still get two files.

## Records

`DotTimerStore` is the seam. Everything is `DotResult`-returning and asynchronous in
shape even where it does not need to be, because an interface written against the fast
case has to be rewritten the first time somebody points it at a database — the
family's own history has that mistake in it twice.

**A store never decides whether a record is allowed.** It writes what it is given.
`DotTimer.can_record` runs on the authoritative timer where the run happened; a check
inside the store would have to be repeated in every implementation and would be
missing from somebody's.

**`player_id` is not a site user id.** The family's identity layer hands a server a
per-scope pseudonymous id precisely so operators cannot correlate players across
servers, and a records table storing a global id would undo that. The backbone maps it
to an account at the point of reporting — see dot-leaderboard.

`DotTimerStoreFile` writes one board per file, to a temporary name and then renames:
a records file is the one thing on a timer server that cannot be regenerated, and a
process killed mid-write must leave the previous board intact. Past a few thousand
rows per board, subclass `DotTimerStore` against a database — nothing above it
changes.

## Wiring it to dot-fps-controller

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

`DotTimerRules` holds the parts that run *inside* the simulation, as pure static
functions, because clamping a player's speed at the start line changes where they end
up and so has to happen on both machines on the same tick:

```gdscript
if timer.is_inside(DotTimerZone.Kind.START):
    state.velocity = DotTimerRules.clamp_prespeed(state.velocity, style.prespeed_limit)
```

`clamp_prespeed` caps the **horizontal** speed only. Clamping the vertical component
too would cancel a player's fall, so somebody dropping into the start area would hang
in the air — every timer in this genre gets this right and it is the first thing a
re-implementation gets wrong.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/timer_selftest.tscn      # 255 checks
godot --headless --path . res://examples/timer_2d_selftest.tscn   # 25 checks
```

Exits non-zero on failure. **Run the check-only pass first**: a script that fails to
parse makes the scene fail to load, and the process then hangs rather than exiting.
And **re-run `--import` after adding any script with a new `class_name`**, or the
identifier does not resolve and the failure looks like a dozen unrelated errors.

**`timer_2d_selftest.tscn` is not a formality.** "Dimension-agnostic" is easy to
claim and easy to be wrong about, so it is a whole 2D game in miniature: a `Node2D`
world, zones authored as `DotTimerZoneVolume2D` nodes, a body moved by 2D vectors, a
run that starts, splits, finishes and files a record, and a replay round-tripped
through the same container 3D uses. It found a real bug in the *shared* code on its
first run.

The self-tests found five real bugs, none of which produced an error anywhere — and a
sixth was found by game-playground, from the other side:

- **`effect_requested` was emitted by nothing at all.** The signal was declared here,
  `DotTimerManager` forwarded it, and both game-playground and game-g2gfast connected a
  handler — and no line in this addon ever fired it. So `RESPAWN`, `SLAY` and
  `TELEPORT` zones did nothing, anywhere, for as long as they have existed: a player
  who fell off a surf map fell for ever, and every map's pit volume was decoration.

  Nothing errored, and that is the design working against itself. A zone kind the timer
  has no rule for is a legitimate thing to find — the timer must *not* act on a
  respawn, because what "respawn" means is different in a first-person game, a 2D game
  and a replay being scrubbed — so "reached a RESPAWN zone and did nothing" is
  indistinguishable from correct behaviour at every point inside this addon. It is the
  family's commonest pattern with the ends swapped: not a value produced and consumed by
  nothing, but a value **consumed by two games and produced by nobody.**

  `_request_effects()` now fires it once on entry, filtered by the run's track, after
  the tick's own state is complete — last, because the host acts synchronously inside
  the signal and a respawn handler calls straight back in through `stop()`.
  `_test_entry_zones_reach_the_host` fails on every check without it.

  It also invalidated a passing test elsewhere: game-g2gfast's "most of the descent is
  spent not grounded, which is surf" was counting 1500 ticks of a bot that had missed
  the ramps and was falling through the void. With the pit working, the bot is put back
  after ~500 ticks and is airborne for 94% of them.

- **The finishing tick was subtracted instead of added**, costing exactly one tick —
  7.8 ms at 128 Hz, 15.6 ms at 64 Hz. Every single-tickrate test passed.
- **`DotTimerNet.Finish.time()` still subtracted it** after the run was fixed: the
  wire copy of the arithmetic was a second copy, and every finish a server announced
  was two fractions short of the run it announced. Found by game-g2gfast's netcode suite
  comparing the two at 1e-4 s. There is one formula now and a comment saying so.
- **`is_inside(kind)` answers only for EFFECT zones**, which is documented — and
  game-g2gfast asked it about START for its prespeed clamp, so the clamp never ran.
  `in_zone(kind)` is the membership query; the name difference is the whole point.
- **A replay truncated inside its header parsed as a valid replay of nothing.**
  `StreamPeerBuffer` reads past its end by returning zeros rather than failing, so
  every string came back empty and the frame count came back zero. `_get_string` now
  returns `null` to distinguish "the name was blank" from "the file ends here".
- **Splits were quantised to the tick** while the run's own time was not, so a
  player's splits were systematically off against a record set at another tickrate.
- **`set_box` normalised the corners** and the first test asserted it did not, which
  is worth listing because it is the one that was the test's fault and cost the same
  ten minutes.
- **`String.is_valid_identifier()` is false for a digit.** It answers "is this a legal
  GDScript identifier", and an identifier may not *begin* with one — so on a single
  character it is false for every digit, and using it to sanitise a records filename
  replaced every digit in a map id with an underscore. In a genre whose maps are
  called `surf_kitsune2` and `bhop_arcane_v3` that is not cosmetic:
  `surf_kitsune2` and `surf_kitsune3` both became `surf_kitsune_` and **shared one
  records file**, with two maps' times merged into one leaderboard. The alphabet is
  now explicit, and anything the substitution changed gets eight hex characters of the
  original id appended — because substitution is many-to-one by construction and
  "unlikely to collide" is not the same as "cannot".
- **A signed distance of exactly zero was folded into "inside"**, which threw the
  crossing fraction away whenever a player landed on a line rather than straddling
  it — and that is not rare: it happens whenever the per-tick step divides the
  distance to the line, which on any course built out of round numbers is *every
  run*. Every one was exactly one tick long, at every tickrate. Zero is the boundary
  and is neither side; it terminates the crossing at whichever end it is on. Found by
  the 2D suite, with a 3D control beside it.

## Where a game plugs in

| To change | Where |
| --- | --- |
| How a server is configured | `DotTimerConfig`, layered like every `DotConfig` |
| What the tick rate is | `sv_tickrate` in `server.cfg`; `DotTimerConfig.tick_rate = 0` asks the engine |
| Whether practice mode exists | `DotTimerManager.allow_checkpoints` |
| Whether a practised run may rank | `DotTimerStyle.allow_checkpoints` |
| Where records live | `DotTimerStore` subclass on `DotTimerManager.store` |
| What a style is worth | `DotTimerStyle`, and `points_for` to change the formula |
| How the movement changes per style | `DotFpsStyle` in dot-fps-controller |
| A new kind of volume | `DotTimerZone.Kind.CUSTOM` plus `payload`, read on `effect_requested` |
| What a teleport / respawn / slay does | `effect_requested`, always. The timer never acts |
| The map's difficulty tier | `DotTimerZoneSet.meta["tier"]`, or override `DotTimerManager.map_tier` |
| How zones are authored | `DotTimerZoneVolume3D` / `2D`, or `DotTimerZonePainter` |
| What the HUD looks like | `DotTimerHud` exports, or a subclass. It ships no art |
| Speed units on the HUD | `DotTimerHud._stats_line` and the `u/s` conversion |
| What replicates | `DotTimerNet.RunState` / `Finish`, written by a dot-net bridge |

## Things deliberately not here

- **A chat, a menu or a `!wr` command.** Console commands belong to dot-server and
  chat to the game. This exposes the queries; what a player types is not its business.
- **A ranking table across maps.** `DotTimerStyle.points_for` scores one completion;
  summing them into a player's rank across a server is dot-leaderboard's job, because
  it is the same problem for a timer, a deathmatch and a 2D game.
- **Sending records anywhere.** `DotTimerStore` is the seam; the backbone client is
  dot-leaderboard.
- **A replay of another player rendered as a ghost.** `DotTimerReplayPlayer` gives the
  pose; what to draw at it is a game's own decision, and every game draws something
  different.
- **Segmented / TAS styles.** `DotTimerStyle.allow_checkpoints` is the switch and the
  run flags are recorded; the actual save-and-restore of a player's position is the
  game's, because it is the game that knows what a position is.
- **Anti-cheat beyond the structural refusals.** The minimum time, the checkpoint flag
  and the zone fingerprint make specific exploits unrepresentable. Detecting a
  scripted strafe is a different discipline and belongs where the input is.
