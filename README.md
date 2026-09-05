This is the **timer** asset for TMC's **Dot** collection. It is for anything run against the clock, and it is careful about the one thing that decides a leaderboard, which is that two servers at different tick rates have to agree.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Speedrun Timers
**Speedrun timers for Godot 4** — bunny-hop, surf, KZ, and anything else run against
the clock.

Zones a mapper draws in the world, tracks and bonuses, stages and splits, styles,
per-run statistics, replays, records and leaderboards. Counted in ticks with sub-tick
zone crossings, so **a run set on a 64 Hz server is comparable with one set on a
128 Hz server** — which is what lets two servers share a records table.

Shaped by the community timer plugins the genre grew up on, rewritten for Godot and
for a client that
predicts its own clock.

## What it gives you

- **Zones**: start, end, stage, checkpoint, teleport, respawn, slay, stop, spawn,
  speed limit, gravity, air acceleration, push, no-jump, auto-hop, freestyle, slide,
  and your own. Drawn in the editor **or** from inside the game with two console
  commands, into the same JSON file.
- **Tracks**: a main route and up to eight bonuses, each with its own zones, records
  and leaderboard.
- **Styles**: sideways, half-sideways, backwards, low gravity, prebhop — a ranking
  weight and a minimum time here, the movement transform in
  [dot-fps-controller](../dot-fps-controller).
- **Replays**: quantised and delta-encoded to under 12 bytes a frame, with playback
  sampled at a time so it runs at the right speed on any monitor.
- **Records**: a store interface with in-memory and file implementations, ranking
  points, and the structural refusals that make the obvious exploits impossible.
- **Practice mode**: `+cp` / `+tp` checkpoints, with the taint rules the genre
  expects — saving is free, restoring costs you the run.
- **A HUD**: clock, split against a personal best or the record, speedometer, strafe
  statistics. No art, no theme — you style it.
- **Configured like a server**, not like a scene: `DotTimerConfig` layers a file, the
  environment and the command line, and takes its tick rate from `sv_tickrate`.
- **2D as well as 3D.** The timer works on positions, not on a controller — a 2D game
  passes `Vector3(x, y, 0)` against zones authored with `DotTimerZoneVolume2D`, and
  files into the same records table a surf server does.

## Installing

Copy `addons/dot_timer/` and [`dot-core`](../dot-core)'s `addons/dot_core/` into your
project, and enable dot-timer in *Project → Project Settings → Plugins*.

Only dot-core is required. dot-fps-controller, dot-net and dot-server are optional.

## Five minutes

```gdscript
var manager := DotTimerManager.new()
manager.authoritative = true          # on the server. A client leaves this false.
manager.tick_rate = 128
manager.store = DotTimerStoreFile.at("user://records")
add_child(manager)

manager.set_styles(DotTimerStyle.defaults())
manager.adopt_engine_tick_rate()      # on a server: whatever sv_tickrate says
manager.load_zones("res://maps/surf_beginner.zones.json")
manager.add_player(&"p1", "Christian")

manager.record_accepted.connect(
    func(record, previous, rank):
        print("%s — rank %d" % [record.formatted_time(), rank])
)
```

and once per **simulated** tick, from your movement loop:

```gdscript
manager.tick_player(
    &"p1", state.position, state.velocity, state.is_grounded(),
    alive, state.yaw, state.pitch
)
```

Not from `_process`. A timer sampled per frame counts a different number of ticks on
a 144 Hz monitor than on a 60 Hz one, and the player's time then depends on their
hardware.

## Drawing zones without an editor

The way these maps have been zoned for twenty years — walk to one corner, run a
command, walk to the other, run it again:

```gdscript
var painter := DotTimerZonePainter.on(manager.zones)

painter.begin(DotTimerZone.Kind.START, DotTimerTrack.MAIN)
painter.mark(player_position)   # first corner
painter.mark(player_position)   # second corner, and the zone exists

manager.zones.save_json("user://zones/surf_beginner.json")
```

It adds height above the marked corners for you, because both marks are taken at your
feet and a zone with no height is one nothing ever enters.

## Documentation

[`CLAUDE.md`](CLAUDE.md) has the design reasoning: why a time is a tick count plus two
fractions, why the timer depends on nothing but dot-core, what each refusal in
`can_record` is defending against, and the four bugs the self-test found.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/timer_selftest.tscn      # 255 checks
godot --headless --path . res://examples/timer_2d_selftest.tscn   # 25 checks
```

## Licence

MIT. See [LICENSE](LICENSE).
