## The "now playing" mark: a few bars that dance while `playing` and rest as short stubs
## otherwise. Decorative: the motion is a fixed pattern, not the audio's spectrum.
extends Control

const BARS: int = 4
const GAP: float = 4.0
const REST: float = 0.22
## Radians per second for each bar; unequal so the pattern does not visibly repeat.
const SPEEDS: PackedFloat32Array = [7.3, 5.1, 8.9, 6.2]
const OFFSETS: PackedFloat32Array = [0.0, 1.7, 3.1, 4.4]
## Levels ease to their target by this share per second, so starting and stopping are soft.
const EASE: float = 9.0

var color: Color = Color.WHITE:
	set(value):
		color = value
		queue_redraw()
var playing: bool = false:
	set(value):
		playing = value
		set_process(true)

var _time: float = 0.0
var _levels: PackedFloat32Array = [REST, REST, REST, REST]


func _init(side: float = 28.0) -> void:
	custom_minimum_size = Vector2(side, side)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func _process(delta: float) -> void:
	_time += delta
	var settled := not playing
	for i in BARS:
		var target := REST
		if playing:
			target = 0.35 + 0.65 * absf(sin(_time * SPEEDS[i] + OFFSETS[i]))
		_levels[i] = lerpf(_levels[i], target, minf(delta * EASE, 1.0))
		if absf(_levels[i] - target) > 0.01:
			settled = false
	queue_redraw()
	if settled:
		set_process(false)


func _draw() -> void:
	var width := (size.x - GAP * (BARS - 1)) / BARS
	for i in BARS:
		var height := maxf(size.y * _levels[i], width)
		draw_rect(Rect2(i * (width + GAP), size.y - height, width, height), color)
