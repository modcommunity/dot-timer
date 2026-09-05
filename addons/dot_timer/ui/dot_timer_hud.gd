@tool
class_name DotTimerHud
extends Control

## The timer's own HUD: the clock, the split against a comparison, the speedometer
## and the strafe statistics.
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

## What the clock shows.
enum Comparison {
	## Nothing. Just the running time.
	NONE,
	## The player's own best on this map, track and style.
	PERSONAL_BEST,
	## The board's record.
	WORLD_RECORD,
}

@export_group("Content")

## Which lines are drawn. A server that only wants a clock turns the rest off.
@export var show_time: bool = true
@export var show_speed: bool = true
@export var show_split: bool = true
@export var show_stats: bool = true
@export var show_track: bool = true

## Which comparison the split line is against.
@export var comparison: Comparison = Comparison.PERSONAL_BEST

@export_group("Appearance")

## Colour for a split that is ahead of the comparison.
@export var ahead_colour: Color = Color(0.35, 0.9, 0.4)

## Colour for a split that is behind it.
@export var behind_colour: Color = Color(0.95, 0.4, 0.35)

@export var neutral_colour: Color = Color(0.85, 0.85, 0.85)

## Font size for the clock. The rest scale from it.
@export_range(8, 128, 1) var clock_size: int = 34

@export_range(0.0, 64.0, 1.0) var line_spacing: float = 4.0

## What is currently on screen. Written by [method show_run].
var run: DotTimerRun = null
var speed: float = 0.0
var personal_best: float = 0.0
var world_record: float = 0.0
var stats: Dictionary = {}
var style_name: String = ""

## A message shown instead of the clock — "finished", "not ranked", a refusal.
##
## Cleared by the next [method show_run] that passes an empty one, so a caller does
## not have to remember to unset it.
var notice: String = ""

var _font: Font = null


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


func _draw() -> void:
	if _font == null:
		_font = get_theme_default_font()

	if _font == null:
		return

	var y := float(clock_size)
	var small := maxi(clock_size / 2, 8)

	if notice != "":
		_line(notice, y, small, neutral_colour)
		y += float(small) + line_spacing

	if show_time:
		var text := run.formatted_time() if run != null else "0:00.000"
		_line(text, y, clock_size, _clock_colour())
		y += float(clock_size) + line_spacing

	if show_split and run != null and run.is_running():
		var against := comparison_time()

		if against > 0.0:
			var delta := run.time() - against
			_line(
				DotTimerRun.format_time(delta, true),
				y,
				small,
				ahead_colour if delta < 0.0 else behind_colour
			)
			y += float(small) + line_spacing

	if show_speed:
		_line("%.0f u/s" % (speed * 100.0), y, small, neutral_colour)
		y += float(small) + line_spacing

	if show_track and run != null:
		var label := DotTimerTrack.name_of(run.track)

		if style_name != "":
			label += " · " + style_name

		_line(label, y, small, neutral_colour)
		y += float(small) + line_spacing

	if show_stats and not stats.is_empty():
		_line(_stats_line(), y, small, neutral_colour)


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


func _line(text: String, y: float, size: int, colour: Color) -> void:
	draw_string(
		_font, Vector2(0.0, y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour
	)


func describe() -> Dictionary:
	return {
		"run": str(run) if run != null else "-",
		"speed": "%.1f m/s" % speed,
		"comparison": Comparison.keys()[comparison],
		"pb": DotTimerRun.format_time(personal_best),
		"wr": DotTimerRun.format_time(world_record),
	}
