# The HUD

`DotTimerHud` is the clock, the split, and the speedometer, and it ships no art. It is what a hop player stares at for hours, so it is an overlay rather than a debug readout: it measures everything it draws, packs it into one block, and places that block in `corner` of its own rect with `margin` clear of the edge. The default is the **bottom centre**, under the crosshair, where the genre has put a clock for a long time.

- **Give it a full-rect `Control`.** The rect is the area the block is laid out inside, not the block. A host that sizes it 360 x 200 gets an overlay pinned to the corner of a box in the corner. `set_anchors_preset` does not set offsets.
- **The placement enum is `Placement`, not `Corner`.** Godot has a global built-in `Corner` (what `StyleBox` radii are indexed by), and an inner enum shadowing it makes every assignment to the property a parse error ("Cannot assign a value of type DotTimerHud.Corner as Corner") that points at the assignment rather than the name.
- **The plate is one `StyleBoxFlat`, drawn once.** A rect plus four corner circles blended twice where translucent shapes overlapped, and the plate had four dark dots. Any decomposition into overlapping pieces has that bug.
- **`block_size()` is measured the same way `_draw` measures it**, and the suite asserts a size, because the family has shipped 0 x 0 `Control`s with every property correct.

An interface is the part whose bugs no assertion reaches: look at it with `tools/screenshot.sh dot-timer out.png --scene res://examples/hud_preview.tscn` (from game-dev), which draws every line it can.

Speed units are `_stats_line` and its `u/s` conversion; override that for a game that measures in its own units.
