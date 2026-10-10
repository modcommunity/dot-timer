# Testing

The family's method is in [game-dev/docs/testing.md](../../../docs/testing.md); this is what is specific here.

| Suite | What it covers |
| --- | --- |
| `examples/timer_selftest.tscn` | the timer: fractions and tick-rate agreement, zones and tracks, effects reaching the host, stages, practice, styles, rules, replays (flags, teleports, run-up and run-out, reaching the disk), the HUD's size, the manager |
| `examples/timer_2d_selftest.tscn` | a whole 2D game in miniature: a `Node2D` world, `DotTimerZoneVolume2D` zones, a body moved by 2D vectors, a run that starts, splits, finishes and files, a replay round-tripped through the 3D container |
| `examples/timer_records_selftest.tscn` | the records half: the store contract against memory and file stores, points, re-scoring, filing, resume, the file store's flush |
| `examples/timer_sql_live.tscn` | the store contract and two servers sharing a board, against SQLite, Postgres and MySQL. Run with `../dot-sql/tools/test_live.sh . res://examples/timer_sql_live.tscn` |

All exit non-zero on failure. Run the `--check-only` pass first (a scene that fails to parse hangs), and re-run `--import` after adding a `class_name`.

- **`timer_2d_selftest` is not a formality.** "Dimension-agnostic" is easy to claim; it found the zero-distance crossing bug in the shared code on its first run, with a 3D control beside it.
- **Test at two tick rates.** Every single-tick-rate test passed while the finish fraction was subtracted.
- **Test the other end of every signal.** A signal declared, forwarded and connected by two games was fired by nothing; a check inside this addon could not tell. `_test_entry_zones_reach_the_host` is the pattern.
- **Recent sections are armed**: they state what they measured with the fix reverted. Revert and watch one fail before trusting it.
- **The store contract is shared** (`timer_store_contract.gd`); never copy a store check into one suite.
