extends Node2D
## Animated electronic perimeter boards: pink and blue LED segments that
## slowly scroll around the pitch.

const PINK := Color(1.0, 0.25, 0.7)
const BLUE := Color(0.25, 0.55, 1.0)
const SEG := 76.0

var t := 0.0
var _tick := 0


func _process(delta: float) -> void:
	t += delta
	var k := int(t * 10.0)
	if k != _tick:  # redraw ~10x/s, enough for a smooth crawl
		_tick = k
		queue_redraw()


func _draw() -> void:
	var off := fmod(t * 30.0, SEG * 2.0)

	# boards along the touchlines
	for board: Rect2 in [Rect2(-572, -328, 1144, 14), Rect2(-572, 314, 1144, 14)]:
		draw_rect(board, Color(0.05, 0.05, 0.08))
		var start := board.position.x - SEG * 2.0 + off
		for j in int(board.size.x / SEG) + 4:
			var sx := start + j * SEG
			var x0 := maxf(sx, board.position.x + 2.0)
			var x1 := minf(sx + SEG - 5.0, board.end.x - 2.0)
			if x1 > x0:
				draw_rect(Rect2(x0, board.position.y + 2.0, x1 - x0, board.size.y - 4.0), PINK if j % 2 == 0 else BLUE)

	# boards behind each goal
	for board: Rect2 in [Rect2(-586, -280, 14, 560), Rect2(572, -280, 14, 560)]:
		draw_rect(board, Color(0.05, 0.05, 0.08))
		var start := board.position.y - SEG * 2.0 + off
		for j in int(board.size.y / SEG) + 4:
			var sy := start + j * SEG
			var y0 := maxf(sy, board.position.y + 2.0)
			var y1 := minf(sy + SEG - 5.0, board.end.y - 2.0)
			if y1 > y0:
				draw_rect(Rect2(board.position.x + 2.0, y0, board.size.x - 4.0, y1 - y0), BLUE if j % 2 == 0 else PINK)
