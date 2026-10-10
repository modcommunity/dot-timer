# History

Bugs worth recognising if they come back. None produced an error anywhere. The rule each left is in the topic docs.

- **The finishing tick was subtracted instead of added**, costing exactly one tick (7.8 ms at 128 Hz, 15.6 ms at 64 Hz). Every single-tick-rate test passed; `_test_tickrate_agreement` found it.
- **`DotTimerNet.Finish.time()` still subtracted it** after the run was fixed: the wire's copy of the arithmetic was a second copy, and every finish a server announced was two fractions short. Found by game-g2gfast's netcode suite comparing the two at 1e-4 s.
- **Splits were quantised to the tick** while the run's time was not.
- **A signed distance of exactly zero was folded into "inside"**, so every run on a course of round numbers was exactly one tick long, at every tick rate. Found by the 2D suite.
- **`effect_requested` was emitted by nothing at all.** Declared here, forwarded by the manager, handled by game-playground and game-g2gfast, and fired by no line in the addon: RESPAWN, SLAY and TELEPORT zones did nothing anywhere, and a player who fell off a surf map fell for ever. A zone kind the timer has no rule for is legitimate, so "reached a RESPAWN and did nothing" was indistinguishable from correct behaviour inside this addon: a value consumed by two games and produced by nobody. It also invalidated a passing test in game-g2gfast, which had been counting a bot falling through the void as "airborne, so surfing".
- **`is_inside(START)` was always false**, because `is_inside` answers for EFFECT zones only; game-g2gfast's prespeed clamp never ran. `in_zone` is the membership query.
- **A replay truncated inside its header parsed as a valid replay of nothing**, because `StreamPeerBuffer` reads zeros past its end.
- **`set_box` normalised the corners and the first test asserted it did not**: the test's fault, listed because it cost the same time.
- **`String.is_valid_identifier()` is false for a digit**, so a filename sanitiser built on it merged two numbered maps into one records file and one leaderboard. Fixed with an explicit alphabet and a hash suffix (`safe_component`).
- **`replays_directory` was read by nothing**: the recorder ran, `save()` existed, and the world-record replay was lost at exit.
- **The file store was never flushed**: every record lost at restart, because a record in memory reads back exactly like one on disk.
- **An empty records directory wrote side files into the working directory** (a stray `_maps.json` in a game's project root). The file store now refuses.
- **A style that allowed checkpoints could never file a run**: `can_record` refused any run with the flag, and the old suite asserted the refusal.
- **Points never moved when a record did**: computed once at filing against the record of the moment.
- **A review pass found five more**: a restored run filed on whatever style the player had switched to; a removed player's total still counting removed records; the SQL store announcing an improvement another server had already beaten; floats losing digits on the gateway so a fresh best ranked behind itself; the SQLite driver reporting `true` instead of an affected-row count (the last two were dot-sql's).
- **An incomplete bonus route** (`[track-zone-1]`): five suites walked tracks by hand, one named track at a time, and the one map none of them asked about (game-g2gfast's `bhop_g2g_stages`) had a bonus with no respawn. `route_problems()` asks every route.
- **The engine-rate warning told every web client** at every map change that its times would be wrong, about a client that files none.
- **`stage_count` occurred exactly once in the family**: the stage model existed and nothing showed, compared or practised a stage. That is the family's detector for a value produced correctly and consumed by nothing ([detectors.md](../../../docs/detectors.md)).
- **A replay smeared a 30 m teleport over one tick** before format 2's teleport flag (`[dot-timer-replays-1]`).
- **A re-entered start zone was nothing**: the run kept counting until the player left again, and a style refusing an air start never saw them leave when they jumped out.
- **The HUD drew a scattered column of grey text** down a quarter of the screen, then four dark dots at its plate's corners.
