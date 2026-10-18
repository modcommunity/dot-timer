extends Control

## The splits panel mid-run over a dark backdrop, for a screenshot: a 9-stage map, stage 4
## being run and behind, gold on one section. `tools/screenshot.sh dot-timer out.png --scene
## res://examples/splits_preview.tscn` from game-dev.


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.12, 0.16)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var cmp := {}
	var best := {}
	for k in range(1, 10):
		cmp[k] = 11.0 * k + 0.37 * k
		best[k] = 10.4 + 0.2 * k
	best[10] = 12.0

	var run := DotTimerRun.make(0, &"normal", 1.0 / 128.0)
	run.begin(0.0)
	var at := [[1, 11.0], [2, 23.1], [3, 33.2], [4, 47.0]]
	for line: Array in at:
		run.ticks = int(float(line[1]) * 128.0)
		run.mark_stage(int(line[0]), 0.0)
	run.ticks = int(58.4 * 128.0)

	var panel := DotTimerSplitsPanel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 0.0
	panel.offset_top = 0.0
	panel.offset_right = 0.0
	panel.offset_bottom = 0.0
	add_child(panel)
	panel.set_reference(9, cmp, 131.5, best, "PB")
	panel.show_run(run)
