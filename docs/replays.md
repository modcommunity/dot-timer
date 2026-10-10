# Replays

## The container

A six-minute run at 128 Hz is 46,000 frames; at a naive 32 bytes each that is 1.5 MB per record, times every style, track and map. Quantising position to a millimetre and view to a tenth of a degree, and storing per-frame deltas with keyframes, brings it under 12 bytes a frame: a file a browser client can fetch while the map loads.

**Format 2** (version 1 is still read) adds:

- **A teleport flag** (`FLAG_TELEPORT`), set by the game through `tick_player(..., replay_flags)` or by the recorder for a move further than `teleport_distance` (4 m) in one tick. A teleport frame is always written whole.
- **`FLAG_DUCKED` and `FLAG_JUMPED`**, through `replay_flags`. The held buttons are kept per frame as a byte that follows the angles only when non-zero (`FLAG_BUTTONS`, set by the encoder).
- **The run-up and the run-out**: the header carries `start_frame` and `end_frame` (`run_start_seconds` / `run_end_seconds`).

A replay truncated inside its header must fail to parse: `StreamPeerBuffer` reads past its end as zeros, so `_get_string` returns `null` to tell "the name was blank" from "the file ends here".

## Playback

- **Sampled at a time, not stepped per frame.** Advancing an index once per rendered frame plays a 128 Hz replay at half speed on a 60 Hz monitor. Asking for "the pose at t" also makes scrubbing free and comparing two replays a matter of sampling both at the same t.
- **Yaw is interpolated the short way round.** 179° to -179° is two degrees; a naive lerp spins the model 358° once per lap, which reads as a corrupt replay.
- **`sample_at` never blends across a teleport, and `speed_at` never derives a speed across one.** Blending smeared a 30 m teleport over one tick: a ghost flying through the map and a readout of thousands of metres a second.

## The recorder

**It throws almost everything away, and has to.** A server records every attempt because it cannot know which will be a record; on a busy map that is thirty players failing every ninety seconds. `discard()` on every run that beat nothing, and a hard frame cap so a player who started the timer and walked away does not grow an unbounded array.

**It is fed every tick** (`feed`), not only during a run, and keeps a rolling `pre_roll_seconds` (2) before the start and `post_roll_seconds` (1) after the finish, so a ghost or a bot starts at the player's run-up speed and does not stop dead on the line. `DotTimerConfig.replay_pre_roll_seconds` and `replay_post_roll_seconds` set them; 0 turns either off.

## Writing to disk

The kept replay is written under `DotTimerConfig.replays_directory` **when its run-out ends** (`pending_replay_record`), not at the finish. A new run, a player leaving or a map change ends a run-out early and writes it as it stands (`_flush_trail`). For a long time `replays_directory` was read by nothing and the world-record replay lived only in `last_replay` until exit: a replay in memory looks exactly like one that was kept.

- **Only replays of runs the store kept are written.** `last_replay` is nulled wherever the record was refused or the old one survived, so the file set is the record set.
- **A failed write is logged, not propagated.** The record is already in the store and `record_accepted` has gone out; a full disk must not turn an accepted record into a refused one.
- **The filename goes through `DotTimerStoreFile.safe_component`**, for the reasons in [records.md](records.md#the-file-store). The suite checks two ids that flatten to the same string still get two files.

A resumed run has no replay.
