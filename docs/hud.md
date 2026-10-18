# The HUD

`DotTimerHud` is the clock, the split, and the speedometer, and it ships no art. It is what a hop player stares at for hours, so it is an overlay rather than a debug readout: it measures everything it draws, packs it into one block, and places that block in `corner` of its own rect with `margin` clear of the edge. The default is the **bottom centre**, under the crosshair, where the genre has put a clock for a long time.

- **Give it a full-rect `Control`.** The rect is the area the block is laid out inside, not the block. A host that sizes it 360 x 200 gets an overlay pinned to the corner of a box in the corner. `set_anchors_preset` does not set offsets.
- **The placement enum is `Placement`, not `Corner`.** Godot has a global built-in `Corner` (what `StyleBox` radii are indexed by), and an inner enum shadowing it makes every assignment to the property a parse error ("Cannot assign a value of type DotTimerHud.Corner as Corner") that points at the assignment rather than the name.
- **The plate is one `StyleBoxFlat`, drawn once.** A rect plus four corner circles blended twice where translucent shapes overlapped, and the plate had four dark dots. Any decomposition into overlapping pieces has that bug.
- **`block_size()` is measured the same way `_draw` measures it**, and the suite asserts a size, because the family has shipped 0 x 0 `Control`s with every property correct.

An interface is the part whose bugs no assertion reaches: look at it with `tools/screenshot.sh dot-timer out.png --scene res://examples/hud_preview.tscn` (from game-dev), which draws every line it can.

Speed units are `_stats_line` and its `u/s` conversion; override that for a game that measures in its own units.

# The stage-splits panel

`DotTimerSplitsPanel` is a quiet sidebar for staged maps: one row per **section** (n stage lines make n + 1), the delta against a comparison, and the time. Like the HUD it ships no art, holds no manager or store, and is fed.

```gdscript
panel.set_reference(stage_count, comparison_splits, comparison_total, best_sections, "PB")  # when the map, comparison or records change
panel.show_run(run)                                                                          # every frame; redraws only when something shown moved
```

- `comparison_splits` is `DotTimerManager.stage_splits_for(id, against_record)` (cumulative, int or string keys), `comparison_total` the finish time of the same record, `best_sections` the player's best time per section (`store.peek_best(map, track, style, player, section).time`, absent where unknown). The comparison (PB or WR) is the caller's choice: pass the one you want and name it.
- A row not yet reached shows the comparison's cumulative time, dim. A reached row shows this run's cumulative time and the delta (green ahead, red behind, **gold** when that section beat the player's previous best segment). The current row shows a live delta only once the run is behind the comparison's time at that line.
- The last row is **Finish**, not "Stage N+1": there is no stage zone N+1 to request, and the finish is a different kind of line.
- Footer lines (`show_comparison`, `show_sum_of_best`, `show_possible_save`, `show_segment`) are each hideable. Sum of best is unknown (a dash) if any section has no best, because a sum with a hole is a time nobody could set; possible save is the comparison total minus it. Missing data is always a dash, never `0:00.000`.
- Compact: `panel_width` 220 px, `font_size` 12, both multiplied by the theme's base scale; translucent plate; left edge, vertically centred in its rect (give it a full-rect Control, as with the HUD); `mouse_filter` ignore. More than `max_rows` sections show a window that follows the current stage with the Finish row pinned. No stage lines hides it entirely.
- Footer toggles take effect at the next change of the run or `set_reference`.
- Look at it: `tools/screenshot.sh dot-timer out.png --scene res://examples/splits_preview.tscn`.
- **Online clients**: per-section records live in the server's store and are not replicated by `DotTimerNet`, so a client has no `best_sections` (and no `comparison_splits`) unless the game sends them. Without them the panel still works, with dashes.
