@tool
class_name DotTimerSplitsPanel
extends Control

## A stage-splits sidebar for a staged map, in the style of a speedrun splits panel that
## has been told to keep quiet: one row per section, the delta against a comparison, the
## time, and a short footer of sum of best and possible time save.
##
## [b]Fed, not polled, and fed twice.[/b] Like [DotTimerHud] it holds no reference to a
## manager or a store. A host calls [method set_reference] when the map, the comparison or
## the records change, and [method show_run] once per frame. The split is that the first
## is data the store produces slowly (it is awaited, and a client may not have it at all)
## and the second is the live run; a panel that fetched either itself would have to know
## which store the host uses.
##
## [b]Sections, not lines.[/b] A map with [code]n[/code] stage lines has [code]n + 1[/code]
## sections: the rows are those, and the last one ends at the finish. A row's time is the
## CUMULATIVE time at its end (what [method DotTimerRun.split_time] and
## [member DotTimerRecord.splits] hold), because that is the number the comparison is
## stored as and the one a player reads against the clock; the per-section time only
## decides gold and the footer.
##
## [b]The last row is called "Finish", not "Stage N+1".[/b] There is no stage zone N+1:
## a player can request stage 1..N (see [method DotTimerManager.request_stage]) and the
## finish is a different kind of line. Naming it a stage would also promise a teleport
## that does not exist.
##
## [b]Quiet on purpose.[/b] The plate is translucent and about 220 px wide, the type is
## small, and a row that has not been reached shows the comparison's time dimmed. The live
## delta appears on the current row only once the run is [i]behind[/i] the comparison's time
## at that line, which is how split timers avoid a number flashing the whole time a player
## is doing well. It ignores the mouse and never takes focus.
##
## [b]Redraws only on change.[/b] Row text is rebuilt when something a row shows changes
## (a line crossed, the run changing, the live delta or segment moving by a hundredth)
## rather than every frame, so a calm run costs a handful of integer compares.
##
## [b]Give it a full-rect Control[/b], as with [DotTimerHud]: the block sits at the left
## edge, vertically centred, inside the rect.

## What a section was compared with, for the colour of a finished row.
const _NONE := -1.0

## Gold: this run's section beat the player's best segment.
@export var gold_colour: Color = Color(1.0, 0.82, 0.25)
@export var ahead_colour: Color = Color(0.35, 0.9, 0.4)
@export var behind_colour: Color = Color(0.95, 0.4, 0.35)
@export var neutral_colour: Color = Color(0.92, 0.92, 0.92)

## Rows not yet reached, and the footer's labels.
@export var dim_colour: Color = Color(0.92, 0.92, 0.92, 0.62)

## The plate behind the block. Alpha 0 draws none. Translucent so a map shows through,
## and as dark as the clock block's: lighter, and the dim rows vanish against a bright sky.
@export var panel_colour: Color = Color(0.0, 0.0, 0.0, 0.45)
@export_range(0.0, 32.0, 1.0) var panel_radius: float = 5.0

## Subtle band behind the section being run.
@export var current_row_colour: Color = Color(1.0, 1.0, 1.0, 0.08)

@export_group("Layout")

## Width of the block at a UI scale of 1. About 220 px at 1080p.
@export_range(120.0, 480.0, 1.0) var panel_width: float = 220.0

## Font size at a UI scale of 1. Multiplied by the theme's base scale, so the block grows
## with the rest of the UI instead of staying a fixed size on a 4K screen.
@export_range(8, 32, 1) var font_size: int = 12

## Distance from the left edge of the rect.
@export_range(0.0, 128.0, 1.0) var margin_left: float = 8.0

## Padding inside the plate and between rows, at a UI scale of 1.
@export var padding: Vector2 = Vector2(8.0, 6.0)
@export_range(0.0, 16.0, 1.0) var row_spacing: float = 2.0

## The most section rows drawn, the pinned finish row included. A map with more sections
## shows a window of them that follows the current one.
@export_range(2, 40, 1) var max_rows: int = 8

@export_group("Footer")

## Each footer line can be hidden on its own.
@export var show_comparison: bool = true
@export var show_sum_of_best: bool = true
@export var show_possible_save: bool = true
@export var show_segment: bool = true

## Sections in the map (stage lines + 1), or 0 when the map has no stages.
var section_count: int = 0

## Label for the comparison total in the footer: "PB", "WR".
var comparison_name: String = "PB"

## The comparison's total time, or 0 when there is none.
var comparison_total: float = 0.0

## What is on screen. Written by [method show_run].
var run: DotTimerRun = null

# Per-section caches, index = section number (index 0 unused). Built in set_reference
# so show_run does array reads and no dictionary lookups, and so the panel never holds the
# caller's dictionaries.
var _cmp := PackedFloat64Array()
var _best := PackedFloat64Array()

# What each section row shows, rebuilt when the signature below changes.
var _delta_text := PackedStringArray()
var _time_text := PackedStringArray()
var _delta_col: Array[Color] = []
var _time_col: Array[Color] = []
var _footer_left := PackedStringArray()
var _footer_right := PackedStringArray()
var _footer_col: Array[Color] = []

var _current: int = 1
var _font: Font = null
var _plate: StyleBoxFlat = null

# The signature of the last rebuild.
var _sig_run: int = 0
var _sig_stage: int = -1
var _sig_status: int = -1
var _sig_live: int = -1
var _sig_version: int = 0
var _version: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = get_theme_default_font()
	set_process(false)


## Sets what the panel compares against. Call when the map, the comparison or the records
## change, not every frame.
##
## [param stage_count] is the number of stage LINES; 0 hides the panel entirely.
## [param comparison_splits] is cumulative time by stage number, as
## [method DotTimerManager.stage_splits_for] returns it (int or string keys both work, JSON
## gives strings). [param comparison_total] is the finish time of the same record, 0 for
## none. [param best_sections] is the player's best time for each SECTION (1..n+1), as
## [code]store.peek_best(map, track, style, player, section).time[/code]; sections with no
## best are simply absent. [param label] names the footer line.
##
## Everything is copied into packed arrays: a Dictionary is a reference, and sharing the
## record's own splits with a panel is the aliasing bug this family has had before.
func set_reference(
	stage_count: int,
	comparison_splits: Dictionary,
	comparison_total_time: float,
	best_sections: Dictionary,
	label: String = "PB"
) -> void:
	var lines := maxi(stage_count, 0)
	section_count = lines + 1 if lines > 0 else 0
	comparison_total = maxf(comparison_total_time, 0.0)
	comparison_name = label

	_cmp.resize(section_count + 1)
	_best.resize(section_count + 1)
	for k in range(section_count + 1):
		_cmp[k] = _NONE
		_best[k] = _NONE
	for k in range(1, section_count + 1):
		var split: Variant = _lookup(comparison_splits, k)
		if split != null and float(split) > 0.0 and k < section_count:
			_cmp[k] = float(split)
		var best: Variant = _lookup(best_sections, k)
		if best != null and float(best) > 0.0:
			_best[k] = float(best)
	if section_count > 0 and comparison_total > 0.0:
		_cmp[section_count] = comparison_total

	_delta_text.resize(section_count + 1)
	_time_text.resize(section_count + 1)
	_delta_col.resize(section_count + 1)
	_time_col.resize(section_count + 1)

	# Hidden rather than drawing nothing: a hidden Control costs no draw call and a host
	# that lays out beside it sees it gone.
	visible = section_count > 0
	_version += 1
	_refresh(true)


## Puts the run on screen. Call once per frame; it redraws only when something shown moved.
func show_run(p_run: DotTimerRun) -> void:
	run = p_run
	_refresh(false)


## The section being run: 1 before the first line, the finish section once finished.
func current_section() -> int:
	return _current


## First section number of the scrolling window (1 when everything fits).
func window_start() -> int:
	var slots := _window_slots()
	if slots >= section_count - 1:
		return 1
	# One row of context above the current one, and never past the last windowed section.
	return clampi(_current - 1, 1, (section_count - 1) - slots + 1)


## How many section rows are drawn, the pinned finish row included. 0 when hidden.
func rows_shown() -> int:
	if section_count <= 0:
		return 0
	return mini(max_rows, section_count)


## The row's label: "Stage 3", or "Finish" for the last section.
func label_for(section: int) -> String:
	return "Finish" if section >= section_count else "Stage %d" % section


## The delta text and colour a row is showing, for tests and for a host that draws its own.
func row_delta(section: int) -> String:
	return _delta_text[section] if section >= 1 and section < _delta_text.size() else ""


func row_delta_colour(section: int) -> Color:
	return _delta_col[section] if section >= 1 and section < _delta_col.size() else dim_colour


func row_time(section: int) -> String:
	return _time_text[section] if section >= 1 and section < _time_text.size() else ""


func row_time_colour(section: int) -> Color:
	return _time_col[section] if section >= 1 and section < _time_col.size() else dim_colour


## The sum of the player's best sections, or -1 when any section has none: a sum with a
## hole in it is a time nobody could set, and presenting it as the ideal would be wrong.
func sum_of_best() -> float:
	if section_count <= 0:
		return _NONE
	var sum := 0.0
	for k in range(1, section_count + 1):
		if _best[k] <= 0.0:
			return _NONE
		sum += _best[k]
	return sum


## Comparison total minus the sum of best, or [code]NAN[/code] when either is unknown.
## Negative is possible against a record the player's segments already beat, and is shown
## as it is.
func possible_save() -> float:
	var sum := sum_of_best()
	if sum < 0.0 or comparison_total <= 0.0:
		return NAN
	return comparison_total - sum


## Footer lines currently drawn, as "label  value" strings.
func footer_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(_footer_left.size()):
		out.append("%s  %s" % [_footer_left[i], _footer_right[i]])
	return out


## The block's size in pixels (0 x 0 when hidden); measured the way [method _draw] lays out.
func block_size() -> Vector2:
	if section_count <= 0:
		return Vector2.ZERO
	var s := _scale()
	var fs := _fsize()
	var line := _line_height(fs)
	var rows := float(rows_shown())
	var h := rows * line + maxf(rows - 1.0, 0.0) * row_spacing * s
	if _footer_left.size() > 0:
		h += float(_footer_left.size()) * line + 4.0 * s
	# Width is the whole plate: 220 means 220, padding included.
	return Vector2(panel_width * s, h + padding.y * s * 2.0)


func describe() -> Dictionary:
	return {
		"sections": section_count,
		"current": _current,
		"window_start": window_start() if section_count > 0 else 0,
		"rows": rows_shown(),
		"comparison": "%s %s" % [comparison_name, _fmt(comparison_total)],
		"sum_of_best": _fmt(sum_of_best()),
		"possible_save": _fmt(possible_save()),
		"block": "%.0f x %.0f" % [block_size().x, block_size().y],
	}


# --- state -----------------------------------------------------------------


## Window slots for non-finish rows: max_rows minus the pinned finish.
func _window_slots() -> int:
	return clampi(max_rows - 1, 1, maxi(section_count - 1, 1))


func _refresh(force: bool) -> void:
	if section_count <= 0:
		return

	var stage := 0
	var status := -1
	var live_cs := 0
	var finished := false
	if run != null:
		stage = run.stage
		status = int(run.status)
		finished = run.status == DotTimerRun.Status.FINISHED
		if run.is_running():
			# The live delta and the live segment are the only things that move between
			# line crossings; hundredths is as fine as they are drawn, so it is as often
			# as the text can change.
			live_cs = int(run.time() * 100.0)

	_current = section_count if finished else mini(stage + 1, section_count)
	var run_id := run.get_instance_id() if run != null else 0

	if (
		not force and run_id == _sig_run and stage == _sig_stage and status == _sig_status
		and live_cs == _sig_live and _version == _sig_version
		and (run == null or run.splits.size() == _sig_splits)
	):
		return

	_sig_run = run_id
	_sig_stage = stage
	_sig_status = status
	_sig_live = live_cs
	_sig_version = _version
	_sig_splits = run.splits.size() if run != null else 0

	for k in range(1, section_count + 1):
		_build_row(k, finished)
	_build_footer(finished)
	queue_redraw()


var _sig_splits: int = 0


func _build_row(k: int, finished: bool) -> void:
	var cmp := _cmp[k]
	var cum := _NONE
	var seg := _NONE
	if run != null:
		cum = run.line_time(-1 if k >= section_count else k)
		seg = run.section_time(k, section_count)
	var reached := cum >= 0.0 and (k < section_count or finished)

	if not reached:
		# Not reached: the comparison's time, dim; a dash when there is none rather than
		# 0:00.000, which would read as a record nobody could beat.
		_time_text[k] = _fmt(cmp)
		_time_col[k] = dim_colour
		_delta_text[k] = ""
		_delta_col[k] = dim_colour
		# Live delta, current row only, only once behind.
		if (
			k == _current and run != null and run.is_running() and cmp > 0.0
			and run.time() > cmp
		):
			_delta_text[k] = _delta(run.time() - cmp)
			_delta_col[k] = behind_colour
		return

	_time_text[k] = _fmt(cum)
	_time_col[k] = neutral_colour
	if cmp <= 0.0:
		_delta_text[k] = "-"
		_delta_col[k] = dim_colour
		return
	var d := cum - cmp
	_delta_text[k] = _delta(d)
	_delta_col[k] = ahead_colour if d < 0.0 else behind_colour
	# Gold beats ahead/behind: beating your best segment is the rarer and better news, and
	# it can happen while still behind overall. Needs a previous best to beat.
	if seg >= 0.0 and _best[k] > 0.0 and seg < _best[k]:
		_delta_col[k] = gold_colour


func _build_footer(_finished: bool) -> void:
	_footer_left.clear()
	_footer_right.clear()
	_footer_col.clear()

	if show_comparison:
		_add_footer(comparison_name, _fmt(comparison_total), neutral_colour)
	if show_sum_of_best:
		_add_footer("Sum of best", _fmt(sum_of_best()), neutral_colour)
	if show_possible_save:
		var save := possible_save()
		_add_footer(
			"Possible save",
			"-" if is_nan(save) else _fmt(save),
			dim_colour if is_nan(save) else ahead_colour
		)
	if show_segment:
		var best := _best[_current]
		var live := _NONE
		if run != null and run.is_running():
			var from := run.line_time(_current - 1)
			if from >= 0.0:
				live = run.time() - from
		var col := neutral_colour
		if live >= 0.0 and best > 0.0 and live > best:
			col = behind_colour
		_add_footer("Segment", "%s / %s" % [_fmt(live), _fmt(best)], col)


func _add_footer(left: String, right: String, col: Color) -> void:
	_footer_left.append(left)
	_footer_right.append(right)
	_footer_col.append(col)


## A time, or a dash for none. Never 0:00.000 for a missing value.
func _fmt(seconds: float) -> String:
	if is_nan(seconds) or seconds <= 0.0:
		return "-"
	return DotTimerRun.format_time(seconds)


## A signed delta with no leading "0:" under a minute: +1.234, not +0:01.234.
func _delta(seconds: float) -> String:
	var text := DotTimerRun.format_time(seconds, true)
	if absf(seconds) < 60.0:
		var rest := text.substr(3)
		if rest.length() > 1 and rest[1] != ".":
			rest = rest.substr(1)
		return text.substr(0, 1) + rest
	return text


static func _lookup(data: Dictionary, k: int) -> Variant:
	if data.has(k):
		return data[k]
	if data.has(str(k)):
		return data[str(k)]
	return null


# --- drawing ---------------------------------------------------------------


func _scale() -> float:
	return get_theme_default_base_scale()


func _fsize() -> int:
	return maxi(int(round(float(font_size) * _scale())), 8)


func _line_height(fs: int) -> float:
	if _font == null:
		_font = get_theme_default_font()
	if _font == null:
		return float(fs)
	return _font.get_ascent(fs) + _font.get_descent(fs)


func _draw() -> void:
	if section_count <= 0:
		return
	if _font == null:
		_font = get_theme_default_font()
	if _font == null:
		return

	var s := _scale()
	var fs := _fsize()
	var line := _line_height(fs)
	var gap := row_spacing * s
	var plate := block_size()
	var origin := Vector2(margin_left * s, (size.y - plate.y) * 0.5)

	if panel_colour.a > 0.0:
		_draw_plate(Rect2(origin, plate))

	var pad := padding * s
	var left := origin.x + pad.x
	var inner := plate.x - pad.x * 2.0
	# Columns: label left, time right, delta right-aligned just before the time.
	var time_w := _font.get_string_size("00:00.000", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var time_right := left + inner
	var delta_right := time_right - time_w - 6.0 * s
	var y := origin.y + pad.y

	var slots := _window_slots()
	var first := window_start()
	var rows := rows_shown()
	var windowed := section_count > max_rows

	for i in range(rows):
		var k := section_count
		if not windowed or i < rows - 1:
			k = first + i
		if windowed and i == rows - 1 and first + slots - 1 < section_count - 1:
			# A hairline marks that rows are skipped between the window and the finish.
			draw_line(
				Vector2(left, y - gap * 0.5), Vector2(time_right, y - gap * 0.5),
				Color(1.0, 1.0, 1.0, 0.15), 1.0
			)
		if k == _current:
			draw_rect(Rect2(left - 3.0 * s, y, inner + 6.0 * s, line), current_row_colour)

		var base := y + _font.get_ascent(fs)
		var label_col := neutral_colour if k <= _current else dim_colour
		draw_string(_font, Vector2(left, base), label_for(k),
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, label_col)
		_draw_right(_delta_text[k], delta_right, base, fs, _delta_col[k])
		_draw_right(_time_text[k], time_right, base, fs, _time_col[k])
		y += line + gap

	if _footer_left.size() > 0:
		y += 4.0 * s - gap
		draw_line(Vector2(left, y - 2.0 * s), Vector2(time_right, y - 2.0 * s),
			Color(1.0, 1.0, 1.0, 0.15), 1.0)
		for i in range(_footer_left.size()):
			var base := y + _font.get_ascent(fs)
			draw_string(_font, Vector2(left, base), _footer_left[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim_colour)
			_draw_right(_footer_right[i], time_right, base, fs, _footer_col[i])
			y += line


func _draw_right(text: String, right: float, base: float, fs: int, col: Color) -> void:
	if text == "":
		return
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(right - w, base), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## One StyleBoxFlat, so the translucent plate composites once (see DotTimerHud).
func _draw_plate(rect: Rect2) -> void:
	if _plate == null:
		_plate = StyleBoxFlat.new()
	if _plate.bg_color != panel_colour:
		_plate.bg_color = panel_colour
	var r := int(round(minf(panel_radius, minf(rect.size.x, rect.size.y) * 0.5)))
	if _plate.corner_radius_top_left != r:
		_plate.set_corner_radius_all(r)
	draw_style_box(_plate, rect)
