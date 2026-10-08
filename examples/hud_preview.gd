extends Control

## The HUD with every line it can draw, for a screenshot: a practised run on a staged
## map, behind the comparison, with a standing line. `tools/screenshot.sh dot-timer
## out.png --scene res://examples/hud_preview.tscn` from game-dev.


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.18, 0.22, 0.27)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var run := DotTimerRun.make(0, &"normal", 1.0 / 128.0)
	run.begin(0.0)
	for i in range(128 * 62):
		run.advance(9.0)
	run.mark_stage(1)
	run.mark_stage(2)
	run.used_checkpoints = true

	var hud := DotTimerHud.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(hud)
	hud.style_name = "Normal"
	hud.show_run(run, 9.3, {"jumps": 41, "strafes": 77, "sync": 0.83})
	hud.set_comparisons(61.204, 57.880)
	hud.set_standing(14, 212)
	hud.set_stage_reference(4, {2: 20.0})
