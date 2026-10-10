# Records, points and the manager

## The store

`DotTimerStore` is the seam. It carries boards (with a `stage` for section records), history, players and points, a map catalogue, attempts per board, saved runs for reconnects, and wipes.

- **Every call is awaited**, including against the memory store where it returns at once, because the SQL store crosses a network and an interface written against the fast case is rewritten the first time somebody points it at a database (the family's history has that mistake twice). **The two `peek_*` methods are synchronous on purpose**: a HUD draws every frame. They answer from what the store already holds, and `null` means "not known yet", never "nobody has a time" (that is `false`, or an empty list).
- **A store never decides whether a record is allowed.** It writes what it is given. `DotTimer.can_record` runs on the authoritative timer where the run happened; a check inside the store would be repeated in every implementation and missing from somebody's.
- **`put()` returns a dictionary** (`previous`, `improved`, `previous_record`, `completions`). Every finish is counted on the row, kept or not, because the store is the only thing that sees every finish.
- **Ranks are shared by ties** (1, 2, 2, 4) in every store, and the site ranks the same way.
- **`player_id` is not a site user id.** The family's identity layer hands a server a per-scope pseudonymous id precisely so operators cannot correlate players across servers; a records table storing a global id would undo that. The backbone maps it to an account when reporting (dot-leaderboard).

## One contract, three stores

`examples/timer_store_contract.gd` runs unchanged against the memory and file stores (in `timer_records_selftest`) and against SQLite, Postgres and MySQL (in `timer_sql_live`). Add a store check there: a second copy of a check is a second place for an expected rank to be wrong.

## The memory store

`DotTimerStoreMemory` is the reference implementation, in dictionaries. With no records directory configured, the manager uses it.

## The file store

`DotTimerStoreFile` writes one board per file plus side files, to a temporary name and then renames: a records file is the one thing on a timer server that cannot be regenerated, and a process killed mid-write must leave the previous board intact. Past a few thousand rows per board, use a database; nothing above the store changes.

- **It is only kept if it is flushed.** `DotTimerManager` flushes every `flush_seconds` and on leaving the tree. Before that, nothing called `flush()` and every record was lost at restart, with no error, because a record in memory reads back exactly like one on disk until the process ends.
- **It refuses to write with an empty directory**, which would make every side file a relative path in the process's working directory.
- **Filenames go through `DotTimerStoreFile.safe_component`.** Map ids and player ids arrive from the wire, so a `../` is a write outside the directory; and substitution is many-to-one, so anything the substitution changed gets eight hex characters of the original id appended. `String.is_valid_identifier()` must not be used to sanitise: it is false for every single digit, which once merged `surf_map2` and `surf_map3` into one records file. Replays use the same function; a second sanitiser is how that bug comes back.

## The SQL store

`DotTimerStoreSql` holds a **duck-typed** dot-sql driver (dot-sql's own docs say why no addon names a dot-sql class). Six tables under a configurable prefix: `records`, `history`, `players`, `maps`, `progress`, `resume`, versioned through dot-sql's migrator as `dot_timer:<prefix>`.

- **Two servers can share a board.** An improvement is `UPDATE ... WHERE time > ?`, so a slower run filed by a server whose read was stale can never overwrite a faster one. It then reads the row back and asks the board whether this run took first place, so it never announces an improvement another server already beat.
- **Reads are cached, writes go straight through.** A board's top, its size and each player's best are cached for `cache_seconds` (10); this server's own writes update the cache as they land, so a record set here is on the HUD at once, and another server's is at most `cache_seconds` old. `peek_*` returns the cache and starts one background fetch per key, not one per frame.
- **MySQL evaluates `SET a = ..., b = a + 1` left to right with the new `a`**; Postgres and SQLite read the old row. Bind a computed value instead (as `note_progress` does).
- Floats must cross the gateway at full precision, or a fresh best ranks behind itself; the store caches the row it read back.

## Points

`DotTimerPoints` has three formulas, chosen by `DotTimerConfig.points_formula`:

- `curve`: `DotTimerStyle.points_for`, the default, still called through the style so an override keeps working;
- `tiered`: linear in tier plus a share of the record's length, bonuses at a fraction;
- `placement`: by place on a crowded board, plus a completion award by tier.

**A board is re-scored whenever its record changes**, and on any change under `placement`, because every row's worth depends on the record. A player's total is `sum(points[i] * weighting^i)` over their whole-run records, best first. `remove_record` and `wipe_player` re-total and re-score every map involved, and `points_changed` names everybody whose total moved. Standings are named by `DotTimerRankTitles`, from data.

## The manager's filing

Filing is a coroutine: `put`, then re-score, then `record_accepted` and `run_filed` (everything a message needs). A refused finish gets `practice_finished` with the place it would have taken.

A dropped run is saved on `remove_player` and offered back on `add_player` (`resume_available`, `restore_player`) if the zones and tick rate are unchanged; it comes back paused, marked `stats.resumed`, with no replay, and `restore_run` refuses a style mismatch (it would file on the wrong board).
