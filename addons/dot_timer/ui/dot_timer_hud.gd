@tool
class_name DotTimerHud
extends Control

## The timer's own HUD: the clock, the split against a comparison, the speedometer,
## the stage and the strafe statistics — as a compact overlay rather than a panel.
##
## [b]No art, and no theme of its own.[/b] The family rule from dot-ui, and it matters
## more here than usual: a bhop server's HUD is the thing its players stare at for
## hours, every community restyles it, and a HUD that shipped a look would be fought
## rather than used. This draws text in the theme it is given and exposes what it
## draws as properties.
##
## [b]Fed, not polled.[/b] It has no reference to a [DotTimerManager] and does not go
## looking for one. A replay viewer drives the same HUD from a replay; a spectator
## drives it from another player's run; a test drives it from nothing. Call
## [method show_run] once per frame with whatever should be on screen.
##
## [b]It lays itself out, in a corner of its own rect.[/b] It used to draw a column of
## lines from the top-left downward at whatever font size it was given, which on a
## 1600×900 client is a scattered block of grey text down a quarter of the screen —
## a debug readout rather than a timer. Everything drawn now measures itself, packs
## into one block, and is placed in [member corner] of [code]Rect2(0, 0, size)[/code]
## with [member margin] clear of the edge.
##
## Two consequences worth knowing:
##
## - [b]Give this a full-rect Control, not a small one.[/b] The rect is the area the
##   block is placed [i]inside[/i], not the block. A host that sizes it 360×200 gets
##   an overlay pinned to the corner of that 360×200, which is almost certainly not
##   what it wanted. `set_anchors_preset` does not set offsets — this family has
##   shipped 0 × 0 `Control`s twice — so set the four offsets as well.
## - [b]The default corner is the bottom centre[/b], which is where this genre's
##   players have looked for a clock for fifteen years. Change it, do not fight it.

## What the clock shows.
enum Comparison {
	## Nothing. Just the running time.
	NONE,
	## The player's own best on this map, track and style.
	PERSONAL_BEST,
	## The board's record.
	WORLD_RECORD,
}

## Where in this Control's rect the block sits.
##
## [b]Not called `Corner`.[/b] Godot has a global built-in enum of that name — the one
## `StyleBox` corner radii are indexed by — and an inner enum shadowing it makes every
## assignment to a property of this type a parse error reading
## "Cannot assign a value of type DotTimerHud.Corner as Corner", which points at the
## assignment rather than at the name.
enum Placement {
	TOP_LEFT,
	TOP_CENTRE,
	TOP_RIGHT,
	BOTTOM_LEFT,
	BOTTOM_CENTRE,
	BOTTOM_RIGHT,
}

@export_group("Content")

## Which lines are drawn. A server that only wants a clock turns the rest off.
@export var show_time: bool = true
@export var show_speed: bool = true
@export var show_split: bool = true
@export var show_stats: bool = true
@export var show_track: bool = true

## Whether the stage line is drawn on a map that has stages.
##
## Drawn as [code]Stage 2 / 5[/code], from [member stage_count]. A map with no stages
## draws nothing regardless, so this can be left on.
@export var show_stage: bool = true

## Which comparison the split line is against.
@export var comparison: Comparison = Comparison.PERSONAL_BEST

@export_group("Layout")

## Where the block sits in this Control's rect.
##
## [b]The bottom centre by default[/b], under the crosshair, which is where every
## timer in this genre has put its clock. A HUD in the top-left corner competes with
## the scoreboard, the chat and the kill feed of whatever game hosts it.
@export var corner: Placement = Placement.BOTTOM_CENTRE

## How far the block is kept from the edge of the rect, in pixels.
@export var margin: Vector2 = Vector2(24.0, 24.0)

## Space between the panel's edge and the text inside it.
@export var padding: Vector2 = Vector2(14.0, 8.0)

## Gap between lines. Small on purpose: the block is one thing to glance at.
@export_range(0.0, 32.0, 1.0) var line_spacing: float = 2.0

## Gap between the fields packed onto one detail line.
@export_range(0.0, 64.0, 1.0) var field_spacing: float = 14.0

## Whether the track, style, stage and statistics share one line.
##
## [b]On by default, and it is most of why this reads as an overlay.[/b] Those are
## four short fields; as four lines they are a paragraph, and a player reads a
## paragraph rather than glancing at it.
@export var compact: bool = true

@export_group("Appearance")

## Colour for a split that is ahead of the comparison.
@export var ahead_colour: Color = Color(0.35, 0.9, 0.4)

## Colour for a split that is behind it.
@export var behind_colour: Color = Color(0.95, 0.4, 0.35)

@export var neutral_colour: Color = Color(0.92, 0.92, 0.92)

## The detail line's colour. Dimmer than the clock, because it is reference rather
## than the thing being watched.
@export var detail_colour: Color = Color(0.72, 0.74, 0.78)

## The plate drawn behind the block. Alpha 0 draws none.
##
## [b]Not art, and not a theme.[/b] A clock drawn as bare text over a bhop map is
## light grey on light grey the moment the player looks at the sky, and this genre's
## maps are mostly sky. A translucent plate is the cheapest thing that keeps the one
## number a player is watching legible against arbitrary geometry; a host that has its
## own panel sets the alpha to zero.
@export var panel_colour: Color = Color(0.0, 0.0, 0.0, 0.45)

@export_range(0.0, 32.0, 1.0) var panel_radius: float = 6.0

## Font size for the clock. The rest scale from it.
@export_range(8, 128, 1) var clock_size: int = 30

## Font size for everything that is not the clock. 0 derives it from [member
## clock_size], which is what keeps one exported number in charge of the whole block.
@export_range(0, 64, 1) var detail_size: int = 0

## What is currently on screen. Written by [method show_run].
var run: DotTimerRun = null
var speed: float = 0.0
var personal_best: float = 0.0
var world_record: float = 0.0
var stats: Dictionary = {}
var style_name: String = ""

## How many stages the track being run has, or 0 for a map without stages.
##
## Set by the host from [method DotTimerZoneSet.stage_count]. It is here because a
## split with no denominator does not tell a player how much of the map is left, and
## because until this existed `stage_count` occurred exactly once in this family —
## a value produced correctly and consumed by nothing, which is the shape most of the
## bugs in this tree have had.
var stage_count: int = 0

## The comparison's split at each stage, by stage number, as
## [method DotTimerRecord.splits] stores them.
##
## Set from the same record [member personal_best] came from. With it the stage line
## shows the gap at the last stage reached rather than only its time, which is the
## number a player is actually racing.
var stage_comparison: Dictionary = {}

## A message shown instead of the clock — "finished", "not ranked", a refusal.
##
## Cleared by the next [method show_run] that passes an empty one, so a caller does
## not have to remember to unset it.
var notice: String = ""

var _font: Font = null

## The plate, rebuilt only when its colour or radius changes — `_draw` runs every
## frame and a StyleBoxFlat per frame is a resource allocation per frame.
var _plate: StyleBoxFlat = null


func _ready() -> void:
	# The theme's default font, whatever the host set. Cached because
	# get_theme_default_font walks the theme chain and this draws every frame.
	_font = get_theme_default_font()
	set_process(false)


## Puts a run on screen. Call once per frame with whatever should be shown.
func show_run(
	p_run: DotTimerRun,
	p_speed: float = 0.0,
	p_stats: Dictionary = {}
) -> void:
	run = p_run
	speed = p_speed
	stats = p_stats
	queue_redraw()


## Sets the comparison times. Call when they change, not every frame.
func set_comparisons(p_personal_best: float, p_world_record: float) -> void:
	personal_best = p_personal_best
	world_record = p_world_record
	queue_redraw()


## Sets what the stage line compares and counts against. Call when the map or the
## comparison record changes, not every frame.
func set_stage_reference(p_stage_count: int, p_splits: Dictionary = {}) -> void:
	stage_count = maxi(p_stage_count, 0)
	# Copied, not adopted. A Dictionary is a reference in GDScript, and handing this
	# one a record's own splits means the HUD and the record are one object — the
	# aliasing that put every leaderboard on the server into the last scope anybody
	# asked for. See DotLeaderboardDef.scoped.
	stage_comparison = p_splits.duplicate(true)
	queue_redraw()


func set_notice(text: String) -> void:
	notice = text
	queue_redraw()


## The time the split is measured against, or 0 for none.
func comparison_time() -> float:
	match comparison:
		Comparison.PERSONAL_BEST:
			return personal_best
		Comparison.WORLD_RECORD:
			return world_record
		_:
			return 0.0


## The font size everything that is not the clock is drawn at.
func detail_font_size() -> int:
	if detail_size > 0:
		return detail_size
	return maxi(int(round(float(clock_size) * 0.52)), 9)


# --- what is on screen -------------------------------------------------------
#
# Built as data first and drawn afterwards, because the block has to be MEASURED
# before it can be placed: its own width and height decide where its top-left corner
# goes, and a draw routine that computes positions as it goes cannot know either
# until it has finished. It is also the only way the plate behind it is the right
# size, and a plate that is the wrong size is worse than no plate.
#
# Each entry is one drawn row: an Array of [text, size, colour] fragments that share
# a baseline, packed left to right with field_spacing between them.


func _rows() -> Array:
	var rows: Array = []
	var small := detail_font_size()

	if notice != "":
		rows.append([[notice, small, neutral_colour]])

	if show_time:
		var clock: Array = [
			[run.formatted_time() if run != null else "0:00.000", clock_size, _clock_colour()]
		]

		# The split rides ON the clock line rather than under it. It is the same
		# number in two forms and a player reads them together; two lines is two
		# glances for one fact.
		if show_split and run != null and run.is_running():
			var against := comparison_time()

			if against > 0.0:
				var delta := run.time() - against
				clock.append([
					DotTimerRun.format_time(delta, true),
					small,
					ahead_colour if delta < 0.0 else behind_colour
				])

		rows.append(clock)

	var details: Array = []

	if show_speed:
		details.append(["%.0f u/s" % (speed * 100.0), small, neutral_colour])

	if show_stage and stage_count > 0:
		details.append(_stage_fragment(small))

	if show_track and run != null:
		var label := DotTimerTrack.name_of(run.track)

		if style_name != "":
			label += " · " + style_name

		details.append([label, small, detail_colour])

	if show_stats and not stats.is_empty():
		details.append([_stats_line(), small, detail_colour])

	if compact:
		if not details.is_empty():
			rows.append(details)
	else:
		for field: Array in details:
			rows.append([field])

	return rows


## The stage field: how far through a staged map the run is, and the gap there.
##
## Coloured against the comparison's split rather than left neutral, because on a
## staged map the split at the last stage is the only feedback a player gets between
## the start and the finish — a stage number on its own says where they are and
## nothing about how it is going.
func _stage_fragment(small: int) -> Array:
	var reached := run.stage if run != null else 0
	var text := "Stage %d / %d" % [reached, stage_count]

	if run == null or reached <= 0:
		return [text, small, detail_colour]

	var against := float(stage_comparison.get(reached, stage_comparison.get(str(reached), 0.0)))
	var split := run.split_time(reached)

	if against <= 0.0 or split < 0.0:
		return [text, small, detail_colour]

	var delta := split - against

	return [
		"%s  %s" % [text, DotTimerRun.format_time(delta, true)],
		small,
		ahead_colour if delta < 0.0 else behind_colour,
	]


func _draw() -> void:
	if _font == null:
		_font = get_theme_default_font()

	if _font == null:
		return

	var rows := _rows()

	if rows.is_empty():
		return

	# Measure. Ascent and descent rather than the string's height, so rows with a
	# 30px clock and rows of 15px text share one consistent baseline rule and the
	# block does not change height when the notice appears and disappears.
	var widths := PackedFloat32Array()
	var heights := PackedFloat32Array()
	var block := Vector2.ZERO

	for row: Array in rows:
		var w := 0.0
		var h := 0.0

		for i in range(row.size()):
			var fragment: Array = row[i]
			var size := int(fragment[1])
			w += _font.get_string_size(
				String(fragment[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, size
			).x
			if i < row.size() - 1:
				w += field_spacing
			h = maxf(h, _font.get_ascent(size) + _font.get_descent(size))

		widths.append(w)
		heights.append(h)
		block.x = maxf(block.x, w)
		block.y += h

	block.y += line_spacing * float(maxi(rows.size() - 1, 0))

	var plate := block + padding * 2.0
	var origin := _plate_origin(plate)

	# Not a ternary: both arms are void calls, and a void function has no value in
	# GDScript, so `a() if c else b()` is a parse error rather than a style choice.
	if panel_colour.a > 0.0:
		if panel_radius <= 0.0:
			draw_rect(Rect2(origin, plate), panel_colour)
		else:
			_draw_rounded(Rect2(origin, plate), panel_radius, panel_colour)

	# The text's own top-left, inside the plate.
	var at := origin + padding
	var y := at.y

	for i in range(rows.size()):
		var row: Array = rows[i]
		var row_height := heights[i]
		var x := at.x

		# Centred rows under a centred corner, so a block whose widest row is the
		# clock does not hang its detail line off the left edge.
		if corner == Placement.TOP_CENTRE or corner == Placement.BOTTOM_CENTRE:
			x += (block.x - widths[i]) * 0.5
		elif corner == Placement.TOP_RIGHT or corner == Placement.BOTTOM_RIGHT:
			x += block.x - widths[i]

		for fragment: Array in row:
			var size := int(fragment[1])
			var text := String(fragment[0])

			# Bottom-aligned within the row: a small fragment beside a big one sits
			# on the big one's baseline, which is what makes "+0.42" read as part of
			# the clock rather than as a separate line that happens to be near it.
			draw_string(
				_font,
				Vector2(x, y + row_height - _font.get_descent(size)),
				text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(fragment[2])
			)

			x += _font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, size
			).x + field_spacing

		y += row_height + line_spacing


## Where the plate's top-left goes, given how big it turned out to be.
func _plate_origin(plate: Vector2) -> Vector2:
	var rect := Vector2(size.x, size.y)
	var out := Vector2(margin.x, margin.y)

	match corner:
		Placement.TOP_CENTRE, Placement.BOTTOM_CENTRE:
			out.x = (rect.x - plate.x) * 0.5
		Placement.TOP_RIGHT, Placement.BOTTOM_RIGHT:
			out.x = rect.x - plate.x - margin.x
		_:
			pass

	match corner:
		Placement.BOTTOM_LEFT, Placement.BOTTOM_CENTRE, Placement.BOTTOM_RIGHT:
			out.y = rect.y - plate.y - margin.y
		_:
			pass

	return out


## A rounded rectangle, composited ONCE.
##
## [b]Not "a rect plus four circles", which is what this was and which visibly did not
## work.[/b] Translucent shapes that overlap blend twice, so a plate drawn as three
## rects and four corner circles came out with four dark dots at its corners — the
## alpha is right everywhere the shapes are disjoint and doubled everywhere they are
## not. Any decomposition into overlapping pieces has that bug; the fix is to draw one
## shape.
##
## A [StyleBoxFlat] built here from the two exported values, rather than a theme
## resource, so this is still an addon that ships no art: it has a colour and a radius
## and nothing a designer would recognise as a style.
func _draw_rounded(rect: Rect2, radius: float, colour: Color) -> void:
	if _plate == null:
		_plate = StyleBoxFlat.new()

	if _plate.bg_color != colour:
		_plate.bg_color = colour

	var r := int(round(minf(radius, minf(rect.size.x, rect.size.y) * 0.5)))

	if _plate.corner_radius_top_left != r:
		_plate.set_corner_radius_all(r)

	draw_style_box(_plate, rect)


## Speed shown in the genre's units per second, not metres.
##
## [b]Because that is the number this genre thinks in.[/b] Every bhop and surf player
## knows what 3500 means and none of them know what 35 m/s means; a HUD that showed
## metres would be converted back by everybody who reads it. One unit is one
## inch, so the factor is 39.37 — but the maps here are built in metres and the
## convention that has stuck is 100 units to the metre, which is what
## [code]speed * 100[/code] is. A game whose scale differs overrides this.
func _stats_line() -> String:
	var parts := PackedStringArray()

	if stats.has("jumps"):
		parts.append("%d jumps" % int(stats["jumps"]))

	if stats.has("strafes"):
		parts.append("%d strafes" % int(stats["strafes"]))

	if stats.has("sync"):
		parts.append("%.0f%% sync" % (float(stats["sync"]) * 100.0))

	return "  ".join(parts)


func _clock_colour() -> Color:
	if run == null:
		return neutral_colour

	match run.status:
		DotTimerRun.Status.FINISHED:
			return ahead_colour
		DotTimerRun.Status.PAUSED:
			return behind_colour
		_:
			return neutral_colour


## The block's size in pixels, for a host laying something out beside it and for a
## test that wants to know this drew anything at all.
##
## Measured the same way [method _draw] measures it, and 0 × 0 when there is nothing
## on screen. A suite asserting a SIZE is the check this family learned to write after
## shipping 0 × 0 `Control`s twice — every property was correct both times.
func block_size() -> Vector2:
	if _font == null:
		_font = get_theme_default_font()

	if _font == null:
		return Vector2.ZERO

	var rows := _rows()

	if rows.is_empty():
		return Vector2.ZERO

	var out := Vector2.ZERO

	for row: Array in rows:
		var w := 0.0
		var h := 0.0

		for i in range(row.size()):
			var fragment: Array = row[i]
			var fsize := int(fragment[1])
			w += _font.get_string_size(
				String(fragment[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, fsize
			).x
			if i < row.size() - 1:
				w += field_spacing
			h = maxf(h, _font.get_ascent(fsize) + _font.get_descent(fsize))

		out.x = maxf(out.x, w)
		out.y += h

	out.y += line_spacing * float(maxi(rows.size() - 1, 0))

	return out + padding * 2.0


func describe() -> Dictionary:
	return {
		"run": str(run) if run != null else "-",
		"speed": "%.1f m/s" % speed,
		"comparison": Comparison.keys()[comparison],
		"corner": Placement.keys()[corner],
		"block": "%.0f x %.0f" % [block_size().x, block_size().y],
		"stages": stage_count,
		"pb": DotTimerRun.format_time(personal_best),
		"wr": DotTimerRun.format_time(world_record),
	}
