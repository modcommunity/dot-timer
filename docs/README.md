# dot-timer docs

The reasoning behind the timer, one subject per file. [CLAUDE.md](../CLAUDE.md) has the short rules; these say why.

| File | What it covers |
| --- | --- |
| [timing.md](timing.md) | A time as ticks plus two fractions, why only dot-core, the tick-rate chain, the timer's behaviour, what `can_record` refuses, start/finish/pause rules, wiring to a controller, 2D, what is deliberately not here |
| [zones.md](zones.md) | Zones as data, the painter, `problems` / `thin_zones` / `route_problems` / `fingerprint`, stages, practice checkpoints |
| [records.md](records.md) | The store interface, the shared contract, memory/file/SQL stores, points, the manager's filing and resume |
| [replays.md](replays.md) | The container and format 2, playback, the recorder, writing to disk |
| [hud.md](hud.md) | `DotTimerHud` and `DotTimerSplitsPanel`: layout, the `Placement` name, the plate, the stage-splits sidebar, looking at them |
| [testing.md](testing.md) | The four suites and what each lesson here says to test |
| [history.md](history.md) | The bugs, and how each looked |
