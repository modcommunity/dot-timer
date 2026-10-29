# Rationale moved out of code comments

Long reasoning that sat above the code, kept here so the code carries one-line docs. Each section names the file it came from.

## addons/dot_timer/core/dot_timer_config.gd

**`DotTimerConfig.tick_rate`.** 0 means "take it from the engine": dot-server writes `Engine.physics_ticks_per_second` from its `sv_tickrate` cvar, so the operator sets one number in `server.cfg`. A fixed value is for a client or a test with no server to ask. Getting it wrong does not fail loudly: a timer counting 128 ticks a second on a server stepping 64 produces times exactly twice what they should be, the runs finish, the records file, and the leaderboard is wrong by a factor of two against every other server. That is why `adopt_engine_tick_rate` exists and why a record carries the rate it was set at.

**`DotTimerConfig.fastest_fall_speed`.** Zero by default because guessing low here is how the thin-zone warning goes quiet on a real bug. A map built for jumping is full of height bands entered on the way up at walking speed, and warning about every one trains everybody to ignore the warning; but a pit volume drawn as a thin horizontal plane has the same shape, and a player falling into it at genre speed passes straight through. That is the most common defect in an imported map.

## addons/dot_timer/core/dot_timer_points.gd

**`DotTimerPoints`.** Three formulas, chosen by configuration, because the choice is the whole of a ranking system's politics. A ranking by raw time rewards whoever plays the easiest map; one by placement rewards whoever plays the emptiest.

- CURVE: the tier's worth, quadratic in the tier, scaled by how close the run is to the record, never below a fifth for a clear. The default, because every record filed so far was scored with it.
- TIERED: linear in the tier plus a share of the record's own length, scaled by closeness. Long maps are worth more than short ones of the same tier.
- PLACEMENT: placement on the board, not closeness. The record is worth a tier- and population-dependent amount, the next nine a falling share, everyone else a share by slice, and every clear a flat completion award. Every row moves when anybody's does.

Every formula is recomputed for the whole board when its record changes, and for PLACEMENT on any change, because every row's worth depends on the record (or everybody's place); scoring once at filing would leave points that name a record time that no longer stands. A player's total is a weighted sum: records sorted best first, the i-th multiplied by `weighting^i`. At 0.975 the hundredth record is worth eight percent of the first, so a ranking reflects the best a player has done rather than how many easy maps they cleared. 1.0 is a plain sum.

## addons/dot_timer/core/dot_timer_rank_titles.gd

**`DotTimerRankTitles`.** Data, not code: every community names its ladder differently and moves the boundaries as it grows, so a ladder is a list a server loads from a file. The first match wins, so the list is read top to bottom like the ladder it draws, which lets "Record Holder" sit above a points band that would also contain them.

```json
[
    {"title": "Record Holder", "colour": "#ffd700", "rank": [1, 1]},
    {"title": "Elite",         "colour": "#ff7f50", "rank": [2, 10]},
    {"title": "Top 5%",        "colour": "#7fc8ff", "percent": [0, 5]},
    {"title": "Regular",       "colour": "#9ccc65", "points": [1000, 0]},
    {"title": "Newcomer",      "colour": "#bdbdbd", "points": [1, 0]},
    {"title": "Unranked",      "colour": "#757575", "points": [0, 0]}
]
```

`percent` is of ranked players; 0 is the top.

## addons/dot_timer/core/dot_timer_record.gd

**`DotTimerRecord`.** The identity of a record is (map, track, style, player). Everything a leaderboard does ("the record for this map", "my best", "am I first") is a query over those four, so they are separate fields rather than a composite key somebody has to parse. Times are seconds and the tickrate they were measured at is stored beside them: a record whose provenance cannot be established cannot be defended when disputed, and in this genre records are disputed. The same reasoning puts the zone fingerprint here: if the finish line moves, every record set against the old one is on a different map, and only the fingerprint can say so afterwards.

**`player_id`.** A global id here would undo the per-scope pseudonymous ids the family's identity layer gives a server precisely so operators cannot correlate their players across servers. The backbone maps the host's id to an account at the point of reporting, if the player has linked one.

**`stage`.** A staged map is ranked twice: by the whole run, and section by section (the stage records players chase when the whole map is out of reach). Sections are stored in the same table with their own board, because every query a board answers is the same query for a section.

## addons/dot_timer/core/dot_timer_rules.gd

**`DotTimerRules`.** Pure, static and outside the timer, because they run inside the simulation. Clamping speed at the start line changes where the player ends up, so it has to happen on client and server identically, on the same tick, before the move; that is the movement loop's business. The timer decides that a limit applies (it owns the zones); these decide what the limit does.

```gdscript
# in the movement loop, after the timer has ticked
if timer.in_zone(DotTimerZone.Kind.START):   # NOT is_inside: that is effects only
    velocity = DotTimerRules.clamp_prespeed(velocity, style.prespeed_limit)
```

**`clamp_prespeed`.** Horizontal only is the point. The rule stops a player building speed in the start zone and diving through the line; clamping vertical velocity as well would cancel the fall of a player who dropped into the start area. It is the first thing a re-implementation gets wrong.

## addons/dot_timer/core/dot_timer_run.gd

**`DotTimerRun`.** Time is counted in ticks, plus two fractions, and the difference decides whether two servers can share a leaderboard. A float accumulator drifts: adding 1/128 ten thousand times does not give the same answer as multiplying, and two servers with different frame pacing reach different totals for identical play. A tick counter is exact, but alone it quantises every run to the tick, so the same run is worth up to 15 ms more on a 64 Hz server than on a 128 Hz one, and on a leaderboard sorted to the millisecond the tickrate wins. So: whole ticks, plus the fraction of a tick the player was already past the start line when the first tick was sampled, minus the fraction past the finish line when the last one was. Both come from where the player was along the segment they crossed on (`DotTimer._crossing_fraction`), and the result is comparable across tickrates to well under a millisecond.

Everything is derived from the simulation, never the wall clock: a timer reading `Time.get_ticks_msec()` can be sped up by lagging the server, is not reproducible from a replay, and disagrees with itself when the server catches up after a stall.

**`end_offset`.** Added, where start_offset is subtracted, and the asymmetry is the whole of a real bug. The finishing tick is not counted by `advance` (the run is already FINISHED by the time it runs), so the part of that tick spent getting to the line has to be added back. Storing "the part after the line" and subtracting it loses a whole tick: 7.8 ms at 128 Hz and 15.6 ms at 64 Hz, wrong by a different amount at each tickrate, which is exactly the dependence the sub-tick fractions exist to remove.

**`section_time`.** A map with n stage lines has n + 1 sections: section 1 runs from the start to line 1, section k from line k - 1 to line k, and the last from line n to the finish. Both lines must be crossed in this run: a section whose first line was skipped (a player who found a way round stage 2) has no time, rather than one measured from wherever they last were, which would be a stage record for a route nobody else runs.

## addons/dot_timer/core/dot_timer_sample.gd

**`DotTimerSample`.** The timer needs a position, a velocity and whether the player is on the ground. It does not need to know that they came from a `DotFpsState`, a 2D body, a replay or a bot, and if it asked for any of those by name the addon would not compile in a project without them. Three lines for a first-person game:

```gdscript
sample.position = controller.state.position
sample.velocity = controller.state.velocity
sample.grounded = controller.state.is_grounded()
```

A 2D game does the same with `Vector3(pos.x, pos.y, 0)` against zones flattened with `DotTimerZone.flatten_for_2d`. Reused, not allocated per tick: thirty players at 128 Hz would allocate nearly four thousand of these a second; `DotTimerManager` keeps one per player.

## addons/dot_timer/core/dot_timer_style.gd

**`DotTimerStyle`.** The split is deliberate. Movement belongs where the motor is; records belong where the records are. A game that only wants a timer over its own movement does not have to install a first-person controller, and a 2D game, which cannot use `DotFpsStyle`, still gets styles. The two are paired by id and nothing enforces it, because enforcing it would mean this file mentioning a class that may not exist, which in GDScript takes the whole addon down with it.

**`allow_checkpoints`.** This is about the RECORD, not the feature. Practice mode is always available, and a timer that took it away on a ranked style would be one nobody could learn a map on. What this decides is what happens to the run: off, restoring a checkpoint abandons it, because continuing to time a run that can never be filed wastes the player's next four minutes; on, the run keeps going and is filed with the flag set. Off for every normal style, since saving and restoring a position is the whole of the difficulty on some maps; a "segmented" style turns it on and ranks separately. Whether practice mode exists at all is the server's, `DotTimerManager.allow_checkpoints`.

**`points_for`.** The shape of this formula is the whole of a ranking system's politics. Ranks by raw time reward whoever plays the easiest map; ranks by placement reward whoever plays the emptiest. This is the compromise the genre settled on: points are the map's tier weight scaled by how close the run is to the record, so finishing a hard map slowly is worth more than finishing an easy map perfectly, and improving a run always pays something.

## addons/dot_timer/core/dot_timer_track.gd

**`DotTimerTrack`.** Nothing is ever instantiated: a track is a column in a records table, a field on the wire and an index into an array of zones, and wrapping it in a class would mean allocating one per record. The numbering is the community timers': maps are shared between servers and referred to by the same numbers, so "bonus 2" has to mean bonus 2.

## addons/dot_timer/core/dot_timer_zone.gd

**`DotTimerZone`.** A zone is data, not a node. Everything survives JSON, is comparable between a client and a server, and can be authored by somebody standing in the map with a console open, which is the workflow `DotTimerZonePainter` reproduces. A scene node could not be created by a player at runtime, sent to a client without the map's source, or diffed against the copy a records database was built against. It is also dimension-agnostic on purpose: a 2D game hands the timer `Vector3(x, y, 0)` and leaves the third axis unbounded, so the same timer, records and leaderboards serve a 3D surf map and a 2D racing course.

```gdscript
var start := DotTimerZone.make(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
start.set_box(Vector3(-2, 0, -2), Vector3(2, 3, 2))
```

**`Kind`.** Kinds the timer cannot act on (GRAVITY, PUSH and the rest) are reported to the host as events rather than dropped. The alternative, a separate "trigger volume" system beside this one, means a mapper drawing two kinds of box, saving them in two files and getting the coordinates of one wrong. Maps and zone files are traded between communities, so a re-numbering is a silent corruption of every one.

**`is_thin_for`.** Per axis, because a floor and a wall are not crossed at the same speed. The horizontal extents are judged against ground speed; the Y extent against how fast the player FALLS through it, which on a jumping course is an order of magnitude different. A half-metre height band entered on the way up at 7 m/s is sampled on six ticks; the same band under a hundred-metre drop is not sampled at all. The vertical budget is not automatically the smaller one and defaults to the horizontal one, because a pit volume drawn as a thin horizontal plane (how the shipped surf maps draw them; 48 of one imported map's 53 zones were thin on Y) is exactly the case this has to keep catching. A game lowers the vertical budget only once it knows how far its players can fall.

## addons/dot_timer/core/dot_timer_zone_set.gd

**`DotTimerZoneSet`.** This is the artefact the genre runs on. Surf and bhop maps are made by people who are not the server operators: a map ships as geometry and somebody then stands in it with a console open and draws the start and finish. The file is traded, corrected and re-traded, so the format is plain JSON, readable and hand-editable, and carries the map name and a hash so a server can tell whether the zones it holds were drawn for the map it loaded.

```gdscript
var set := DotTimerZoneSet.new()
set.map_id = &"surf_beginner"
set.add(DotTimerZone.make(DotTimerZone.Kind.START).set_box(a, b))
set.save_json("user://zones/surf_beginner.json")
```

The set is authoritative on the server and advisory on a client: a client needs the zones to draw them and to predict its own crossing; only the server's copy decides a record.

**`PITLESS_TRACKS_KEY`.** Data, not an argument, because the zone file is what ships. A route a player cannot fall off (a circuit on a walled floor, a 2D course with ground under all of it) is real, and only the map knows. Declared in the set it travels with the file to every server and is visible to the next person who edits it, where a flag passed by one caller would be a mute button that caller alone holds.

**`route_tracks`.** A track with only a SPAWN on it (the main track of a sandbox map whose courses are all bonuses) is somewhere a player stands, not a route anybody runs, and asking it for a finish would fail the one map shape that proves a game does not quietly require a timer. The moment a track carries a timing zone it is a route, and `route_problems` asks all of it.

**`route_problems`.** Per track, which `problems` is not. That check is per zone and per pair, and cannot see a bonus with a start, an end and nothing else. Every zone carries a track and the timer acts only on its own, so a RESPAWN on the main route catches nobody on bonus 1: a set complete for track 0 and partial for track 1 passes `problems` while its players fall out of the world, and this family shipped that on five routes. Each route needs:

- a START and an END, or it cannot be run;
- a SPAWN, or `spawn_for` falls back to the MAIN track's and the bonus silently starts at the map's start;
- a RESPAWN, because there is no track-agnostic one: `DotTimer._request_effects` drops every zone off the run's track before asking the host for anything, and nothing catches a player below the world. A route a player truly cannot fall off says so under `PITLESS_TRACKS_KEY`; a declaration naming a track that has a pit anyway, or that is not a route, is reported too, so the exemption cannot outlive its reason;
- its stages numbered 1..n, the same rule `problems` applies.

Separate from `problems` deliberately: that one is "the set is unusable" and refuses a painter's save, while a half-drawn bonus with no spawn yet is a thing an admin saves on the way to finishing it. This is "a route on this map is not finished", which a map's own suite asserts is empty and `DotTimerManager` warns about on load.

**`thin_zones`.** Advisory, and the first thing to check when a zone "does not work". At 128 Hz a player at 30 m/s covers 23 cm per tick and at 64 Hz nearly half a metre; a finish thinner than that is not sampled on any tick the player is inside it, so the run never ends, for the fast players only. `fastest_fall_speed` is how fast a player crosses a zone's Y extent; it is separate because a height band entered on the way up at 7 m/s and a floor arrived at after a long drop are the same shape and only one is a bug. See `DotTimerZone.is_thin_for` for why the conservative default is the horizontal speed.

## addons/dot_timer/net/dot_timer_net.gd

**`DotTimerNet`.** dot-net is not a dependency and is not mentioned: a script naming a `class_name` the project lacks fails to parse and takes everything referencing it down, so writer and reader are typed Variant and called by name, as `DotFpsCommand.write` does. What needs to travel is smaller than it looks. A client runs its own `DotTimer` over its own copy of the zones and reaches the same answer a tick earlier than any packet could, which is the reason the timer is deterministic and counted in ticks. So the server does not stream a running clock; it sends the run's identity (is one going, on what track and style, since which tick) and the client computes the display: 30 bits, once, per state change. The exception is a finish, which is authoritative, goes on a leaderboard, and is the one thing a client must not compute.

## addons/dot_timer/replay/dot_timer_replay.gd

**`DotTimerReplay`.** A replay is the feature that makes a timer worth having: a leaderboard says somebody was fast, a replay shows how, and on a surf or bhop server the world-record replay is the tutorial. It is also the only way a disputed record can be adjudicated. Frames are quantised and delta-encoded for arithmetic reasons: a six-minute run at 128 Hz is 46,000 frames, and at a naive 32 bytes each (three position floats, two view floats, a flags word) that is 1.5 MB per record, times six styles times nine tracks times every map. Quantising position to a millimetre and view to a tenth of a degree and storing the difference between consecutive frames brings a typical frame to five or six bytes, about 250 KB, which a browser client can download before the map loads. Keeping the container dumb is what lets a replay be recorded on a server that never renders one and played on a client that never records one.

## addons/dot_timer/replay/dot_timer_replay_player.gd

**`DotTimerReplayPlayer`.** Sampled at a time, not stepped per frame. The obvious implementation advances an index once per rendered frame, which plays a 128 Hz replay at half speed on a 60 Hz monitor and differently on a 144 Hz one. Asking for "the pose at t seconds" makes playback correct on any display, makes scrubbing and rewinding free, and makes comparing two replays a matter of sampling both at the same t. Yaw is interpolated the short way round: a naive lerp through a 180 degree turn spins the model the long way round once per lap, which looks like a corrupt replay.

## addons/dot_timer/replay/dot_timer_replay_recorder.gd

**`DotTimerReplayRecorder`.** The whole design is about not paying for runs nobody keeps. A server records every attempt because it cannot know in advance which will be a record, and on a busy map that is thirty players failing every ninety seconds. Two things keep it affordable: a hard frame cap, so an idle player who started the timer and went to make tea does not accumulate an unbounded array, and `discard`, called on every run that did not beat anything. Recording is from the simulation, not the render loop, so a replay plays back at the rate it was recorded and a client and a server recording the same run produce the same number of frames.

## addons/dot_timer/runtime/dot_timer.gd

**`DotTimer`.** One instance per player, no singletons: a server times thirty at once, a replay viewer runs another over the same map, a test runs a hundred in one process.

```gdscript
var timer := DotTimer.new()
timer.bind(zone_set, 128)

# every simulated tick
sample.position = player_position
sample.velocity = player_velocity
sample.grounded = player_is_grounded
timer.tick(sample)
```

The timer decides; the game acts. Nothing teleports a player, kills one, changes gravity or refuses a jump. It reports what the zone asked for and the host does it, because "teleport" means something different in a first-person controller, a 2D game and a replay being scrubbed. Everything is counted in simulated ticks: a timer reading the system clock could be sped up by lagging the server, would not reproduce from a replay, and would disagree with itself after a stall.

**`_request_effects`.** For a long time nothing fired [signal effect_requested]. The signal was declared, the manager forwarded it and both games connected a handler, so a RESPAWN zone under a surf map did nothing and a player who fell off fell for ever. Nothing errored: a zone kind the timer has no rule for is legitimate, and the design says the timer must not act on one itself. It was a value consumed by nothing, except that here nothing produced it. Firing once on entry also matters because a teleport that fired every tick would be a loop for any two zones pointing at each other.

**`_crossing_fraction`.** This is what makes a 64 Hz run comparable with a 128 Hz one. A timer counting whole ticks quantises every run to its tickrate: the same play is worth up to 15 ms more on a 64 Hz server than on a 128 Hz one, and on a leaderboard sorted to the millisecond the tickrate decides the ordering. It is the single most important line in the file for anybody who wants two servers to share a records table. Linear along the segment using the signed distance to the zone's surface: the path within one tick is not exactly straight (gravity curves it), but over 8 ms at plausible speeds the error is micrometres, and the alternative (re-simulating the tick at a finer step) would have to be done identically on every machine that ever recomputes the time.

**`span`.** Both ends strictly on the same side means the boundary was not crossed on this segment; the player was already through when the tick began (teleported in, or the zone is thinner than a tick of travel). Zero is the honest answer: no part of the tick is discounted. Strictly, and a distance of exactly zero is neither side: zero IS the boundary, so it terminates the crossing at whichever end it is on. Folding it into "inside" (`d <= 0.0`) throws the fraction away in a case that is not rare: a player whose per-tick step divides the distance to the line lands on it exactly, which with a fixed step and an axis-aligned zone happens on any course built from round numbers. The 2D suite caught it as every run being exactly one tick long at both tickrates. The other spelling does not work either: a box is half-open (`DotTimerZone.contains` includes its lower bound and excludes its upper), so a distance of zero is inside at one face and outside at the opposite one, and a signed distance cannot tell which face it is at.

## addons/dot_timer/runtime/dot_timer_checkpoints.gd

**`DotTimerCheckpoints`.** After the timer itself this is the most-used feature on a surf or bhop server: a four-minute map with one hard section is four minutes of walking back per attempt without it, and every timer in the genre has had `+cp` / `+tp` bound to a key for fifteen years.

```gdscript
checkpoints.save(position, velocity, yaw, pitch)   # +cp
var cp := checkpoints.load_current()               # +tp
if cp != null:
    player.teleport_to(cp)
```

Using one taints the run, and the taint is sticky: `DotTimer.note_checkpoint_used` flags or abandons it depending on the style, and clearing the flag when the player stops would let anybody file a record for the last thirty seconds of a map. This class calls it for you, because a game that had to remember to will forget on one code path. It stores state, not a node, for the reason `DotTimerSample` does: restoring into a `DotFpsState`, a 2D body or a replay scrubber are three different things and none belongs here.

## addons/dot_timer/runtime/dot_timer_manager.gd

**`DotTimerManager`.** One manager, many players, never one per player: a dedicated server runs thirty at once and they share the zones, the index, the styles and the store, where a per-player node would rebuild the spatial index thirty times per map change and give thirty answers to "what is the record here". No autoload, for the family's reason and for one of its own: a replay viewer runs a second manager over the same map at the same time, and a test runs several.

```gdscript
var manager := DotTimerManager.new()
manager.authoritative = true          # on the server only
add_child(manager)
manager.load_zones("res://maps/surf_beginner.zones.json")

manager.add_player(&"p1", "Christian")

# every simulated tick, per player
manager.tick_player(&"p1", position, velocity, grounded, alive, yaw, pitch)
```

**`run_filed`.** The dictionary:

```gdscript
{
    "player": StringName, "record": DotTimerRecord,
    "previous": DotTimerRecord or null,   # their best before
    "previous_record": DotTimerRecord or null,  # the board's #1 before
    "improved": bool, "first": bool,      # a new personal best; their first finish
    "world_record": bool,                 # this run took first place
    "rank": int, "total": int,            # where it stands now, of how many
    "completions": int,                   # their finishes on this board
    "points": float, "title": Dictionary, # what it is worth; their title now
}
```

**`config`.** Changing the number under runs in progress reinterprets ticks already banked: a run half-simulated at 64 and half at 128 produces a time that is neither, and files it without an error anywhere. On a server, `adopt_engine_tick_rate` takes it from `Engine.physics_ticks_per_second`, which dot-server writes from its own `sv_tickrate` cvar: one number, in `server.cfg`, with everything else.

**`replays_directory`.** Set from `DotTimerConfig.replays_directory`, which was read by nothing for a long time. The recorder's memory cap was the same bug one field over: a server recorded every run, held the winner in `last_replay`, and lost it at exit, so a records server could not show the world-record replay.

**`allow_checkpoints`.** They are separate because a ranked style that took practice mode away would be one nobody could learn the map on, while a competition server turning the whole feature off for an evening is a real request.

**`adopt_engine_tick_rate`.** The chain this closes: an operator writes `sv_tickrate 128` in `server.cfg`; dot-server's `_apply_tickrate` writes `Engine.physics_ticks_per_second`; this reads it; the rate ends up on every `DotTimerRecord` the server files. Before it, the rate was an export on a node nobody would change, and a server retuned from 64 to 128 would have kept producing times against 64, twice what they should be, on a leaderboard shared with servers that got it right.

**`note_stats`.** A FINISHED run accepts them too, and that is the whole point of the method. The obvious guard is "only while the run is active", and it silently discards the one call that matters: the natural moment to fold in a run's statistics is when it ends, which is when the run is no longer active. game-playground's integration suite caught it as a record whose stats dictionary was empty, with no error anywhere. A first-person game passes `controller.stats.to_dictionary()` once when the run ends, or every tick for a live HUD.

**`replay_path`.** One file per map/track/style/player rather than per run: the store keeps one record per that tuple, so a second file would be a replay of a run the store already replaced. Ids are sanitised through `DotTimerStoreFile.safe_component`, the same function the records filename goes through and deliberately not a second one: a player id and a map id both reach this from the wire, so `../` in either is a write outside the directory, and substitution is many-to-one, so without that function's hash suffix `surf_kitsune2` and `surf_kitsune3` would share one replay file. That exact bug cost this addon a leaderboard once; a second sanitiser is how it comes back.

**`stage_count`.** The navigation half of a staged map, which is what the timer community's staged maps and Shavit's `sm_stages` / `sm_stagerestart` are. dot-timer carried stage zones, sub-tick splits and `stage_count` since it was written and nothing read any of it: `stage_count` occurred exactly once in the whole family, which is this tree's own mechanical detector for a value produced correctly and consumed by nothing. The timer still does not move anybody: `stage_requested` is emitted for the same reason `effect_requested` is, since what "put the player here" means differs between a first-person game, a 2D game and a replay being scrubbed.

**`request_stage`.** Practice checkpoints are the mechanism for "keep my time while I learn this" and carry their own `used_checkpoints` flag; a stage teleport is the other thing, and it is not a ranked attempt.

## addons/dot_timer/runtime/dot_timer_zone_index.gd

**`DotTimerZoneIndex`.** Why not loop over the list: a busy surf map has forty to a hundred zones, a server thirty players, and this is asked once per player per tick at 128 Hz, a hundred and twenty thousand box tests a second before anything else has run. A uniform grid turns that into a handful. It is a grid rather than a BVH deliberately: zones are large, few, mostly axis-aligned and never move, which is the case a grid is best at and a tree's build cost least justified by. Rebuilt, never mutated in place: an index that tracked edits would have to be correct under a mapper deleting a zone mid-frame while a player is inside it, and rebuilding takes under a millisecond for a hundred zones.

## addons/dot_timer/store/dot_timer_store.gd

**`DotTimerStore`.** Await every call, including the ones that do not need it. The memory store answers instantly and the SQL store crosses a network; an interface written against the fast case has to be rewritten the first time somebody points it at a database (the family's history has that mistake twice), so every caller writes `await store.top(...)`. Except the two `peek_` methods, which are synchronous on purpose: a HUD draws every frame and cannot wait on a database. They answer from whatever the store already holds, and null means "not known yet", never "nobody has a time".

A store never decides whether a record is allowed; it writes what it is given. Whether a run is fast enough, clean enough and on a ranked style is `DotTimer.can_record`, on the authoritative timer where the run happened; a check inside the store would have to be repeated in every implementation and missed in somebody's.

A board is (map, track, style, stage). Stage 0 is the whole run; stage k is section k of a staged map. Every board query takes the stage last, defaulting to the whole run, so a caller that has never heard of sections is unchanged. Ranks are shared by ties: two identical times are both rank 3 and the next is rank 5; awarding the older one the better rank is a rule nobody agreed to, and the site ranks the same way.

Shipped: `DotTimerStoreMemory` (tests, a scratch server, the reference implementation), `DotTimerStoreFile` (JSON files), `DotTimerStoreSql` (SQLite, Postgres or MySQL through a dot-sql driver).

**`put`.** The dictionary: `previous` (the player's best before, or null), `improved` (whether this run replaced it), `previous_record` (the board's #1 before, or null), `completions` (finishes on this board, this one included).

## addons/dot_timer/store/dot_timer_store_file.gd

**`DotTimerStoreFile`.** A file per board, not one for everything: a busy server holds records for hundreds of maps across six styles and nine tracks, and rewriting all of them because somebody finished one is slow and loses the lot if the process is killed halfway. One board is a few kilobytes and is written atomically. It extends the in-memory store rather than reimplementing it, since the sorting, "did it beat the previous" and ranking are the same code and a second copy is a second place for the comparison to be the wrong way round; this adds loading, saving and a write budget. Everything else is five small files beside the boards (players, maps, history, progress, saved runs), each written whole and atomically; their names begin with an underscore, which no board file's can (a board file is `map.track.style.json` and a map id cannot be empty). Not for a server with thousands of players: it reads a whole board to answer a query and writes a whole board to file a record (O(board)), and a profile or points re-total reads every board on disk once. Past a few thousand rows use `DotTimerStoreSql`; the interface is the same.

**`safe_component`.** Public, and the only one in this addon: `DotTimerManager` builds replay filenames out of the same wire-supplied ids and calls this rather than growing a second sanitiser. Two of them is how one gets the hash suffix and the other does not, and the one that does not silently merges two maps into one file.

An explicit alphabet, and not `String.is_valid_identifier`: that answers "is this a legal GDScript identifier", and an identifier may not begin with a digit, so on a single character it is false for every digit and using it replaced every digit in a map id with an underscore. `surf_kitsune2` and `surf_kitsune3` both became `surf_kitsune_` and shared one records file, merging two maps' times into one leaderboard.

The hash suffix is what makes a collision impossible rather than unlikely. Substitution is many-to-one by construction, so when sanitising changed anything, eight hex characters of the ORIGINAL id go on the end. Two different ids then always have different files, and an id that needed no substitution keeps its plain readable name.

## addons/dot_timer/store/dot_timer_store_memory.gd

**`DotTimerStoreMemory`.** [DotTimerStoreFile] is this plus a disk, and the SQL store's live suite checks it against this one. The board index is sorted on write because a leaderboard is read far more often than written (a HUD asks for the top ten every time somebody finishes, a scoreboard on every open).

## addons/dot_timer/store/dot_timer_store_sql.gd

**`DotTimerStoreSql`.** ```gdscript
var made := DotSql.from_config({"driver": "sqlite", "path": "user://g2gfast.db"}, self)
var store := DotTimerStoreSql.new(made.value)
var opened := await store.open()     # creates or migrates the tables
manager.store = store
```

The driver is held untyped and asked for `query`, `execute`, `batch`, `upsert_sql` and `migrate`, so dot-timer depends only on dot-core; anything with those five methods will do. Several servers can share one database, which is the reason to use this rather than the file store: every write is shaped so two of them cannot corrupt a board. An improvement is a conditional UPDATE (`WHERE time > ?`), so a slower run arriving second can never overwrite a faster one that landed first, in whatever order the requests reach the database. Reads are cached and writes go straight through: a HUD asks for the record and the player's best every frame and a scoreboard asks for the top ten on every open, and none of that can wait on a network. So the top of a board, its size and each player's best are kept for `cache_seconds`, and this server's own writes update the cache as they land. What the cache cannot see is another server's write, at most `cache_seconds` old; 0 turns caching off.

## addons/dot_timer/ui/dot_timer_hud.gd

**`DotTimerHud`.** No art, and no theme of its own: a bhop server's HUD is what its players stare at for hours and every community restyles it, so a shipped look would be fought rather than used. It draws text in the theme it is given and exposes what it draws as properties.

Fed, not polled: it holds no reference to a `DotTimerManager`. A replay viewer drives the same HUD from a replay, a spectator from another player's run, a test from nothing. Call `show_run` once per frame with whatever should be on screen.

It lays itself out in a corner of its own rect. It used to draw a column of lines from the top-left downward, which on a 1600x900 client reads as a debug readout rather than a timer; now everything drawn measures itself, packs into one block, and is placed in `corner` of `Rect2(0, 0, size)` with `margin` clear of the edge. Two consequences: give this a full-rect Control, not a small one (the rect is the area the block is placed inside, not the block; a host sizing it 360x200 gets an overlay pinned to that corner, and `set_anchors_preset` does not set offsets, so set all four, since this family has shipped 0 x 0 Controls twice); and the default corner is the bottom centre, where this genre's players have looked for a clock for fifteen years.

## addons/dot_timer/ui/dot_timer_splits_panel.gd

**`DotTimerSplitsPanel`.** Fed, not polled, and fed twice. Like `DotTimerHud` it holds no reference to a manager or store. A host calls `set_reference` when the map, the comparison or the records change, and `show_run` once per frame: the first is data the store produces slowly (awaited, and a client may not have it), the second is the live run, and a panel that fetched either would have to know which store the host uses.

Sections, not lines: a map with n stage lines has n + 1 sections and the last one ends at the finish. A row's time is the CUMULATIVE time at its end (what `DotTimerRun.split_time` and `DotTimerRecord.splits` hold), because that is how the comparison is stored and what a player reads against the clock; the per-section time only decides gold and the footer. The last row is called "Finish", not "Stage N+1": there is no stage zone N+1, a player can request stages 1..N, and naming it a stage would promise a teleport that does not exist.

Quiet on purpose: a translucent plate about 220 px wide, small type, an unreached row shows the comparison's time dimmed, and the live delta appears on the current row only once the run is behind the comparison's time at that line, so no number flashes while a player is doing well. It ignores the mouse and never takes focus. Row text is rebuilt only when something a row shows changes; between those only the current row's live delta and the footer's live segment are touched, once per hundredth.

A run is compared with the reference it started with: `set_reference` called mid-run or after the finish takes effect when the next run starts, with no run it applies at once. The block sits at the left edge, vertically centred, in the rect.

**`set_reference`.** `comparison_splits` is cumulative time by stage number, as `DotTimerManager.stage_splits_for` returns it (int or string keys both work; JSON gives strings). `comparison_total` is the finish time of the same record, 0 for none. `best_sections` is the player's best time for each SECTION (1..n+1), as `store.peek_best(map, track, style, player, section).time`; sections with no best are absent. `label` names the footer line. Everything is copied into packed arrays because sharing the record's own splits with a panel is the aliasing bug this family has had before.

## addons/dot_timer/zones/dot_timer_zone_painter.gd

**`DotTimerZonePainter`.** This is how these maps have actually been made for twenty years. A surf or bhop map ships as geometry from somebody who is not the server operator, and the zones are added afterwards by an admin standing in the map: walk to one corner, type the command, walk to the other, type it again (the community timers' `sm_zones`). A timer without it can only be used on maps whose author happened to use the same engine.

```gdscript
painter.begin(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
painter.mark(player_position)     # first corner
painter.mark(player_position)     # second corner, and the zone is added
```

## addons/dot_timer/zones/dot_timer_zone_volume_2d.gd

**`kind`.** The timer itself is dimension-agnostic (it works on Vector3 positions and does not care what they mean), so a 2D game gets timers, tracks, stages, styles, records, replays and leaderboards from the same addon a surf server uses. This node is the whole of the 2D-specific part: a sample of `Vector3(x, y, 0)` falls inside it.

## addons/dot_timer/zones/dot_timer_zone_volume_3d.gd

**`DotTimerZoneVolume3D`.** Both ways of authoring a zone are needed, and they are not alternatives: a mapper building a level in Godot places a start line as a node with the gizmo, while an operator adding a bonus to somebody else's map has no scene to open and needs `DotTimerZonePainter` and a console. One format, two ways in.

```gdscript
# in the map's own script
var set := DotTimerZoneVolume3D.collect(self, &"surf_beginner")
timer_manager.set_zones(set)
```

## examples/timer_2d_selftest.gd

**`TICK_RATE`.** The claim under test decides whether this addon is worth having twice: dot-timer says it is dimension-agnostic, and that is easy to claim and easy to be wrong about. So this file is a whole 2D game in miniature. Nothing mentions Vector3 except where the sample demands one, which is what a 2D game has to write: `sample.position = Vector3(body.position.x, body.position.y, 0.0)`. The trap is the third axis: a rectangle drawn in the 2D editor has zero thickness on Z, and a box with zero thickness contains nothing, so a zone authored the obvious way never fires and nothing errors. `DotTimerZone.flatten_for_2d` fixes it, `DotTimerZoneVolume2D` applies it, and both are checked here.

## examples/timer_selftest.gd

**`CHECKS`.** The most important test is `_test_tickrate_agreement`. Everything else checks that the timer does what it says; that one checks the claim the whole design rests on, that the same run timed on a 64 Hz server and a 128 Hz server produces the same time to well under a millisecond, so two servers can share a records table. If the sub-tick fractions are wrong every other test still passes and the leaderboard is decided by the tickrate. The runs are synthetic: a player is moved along a straight line at a fixed speed, one tick at a time, so against a hand-computed path a failure has exactly one possible cause.

## examples/timer_store_contract.gd

**`CHECKS`.** One contract, three stores. The memory store is the reference, the file store is that plus a disk, and the SQL store is the same answers from three databases. Writing the checks once and running them against each is the only way the three cannot drift; a second copy of a check is a second place for the expected rank to be wrong. The self-test runs it against memory and file; `timer_sql_live` against SQLite, Postgres and MySQL.

```gdscript
var contract := preload("res://examples/timer_store_contract.gd").new()
await contract.run(store, _check)   # _check(what: String, passed: bool)
```
