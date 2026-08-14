extends Node2D
## Rare cosmetic event: a streaker sprints across the pitch on a wobbly line,
## arms waving, modesty preserved by a censor bar. No gameplay interaction.

const SKIN := Color(0.95, 0.74, 0.58)

var dir := 1.0      # +1 runs left-to-right, -1 the other way
var base_y := 0.0
var speed := 250.0
var t := 0.0


func _physics_process(delta: float) -> void:
	t += delta
	position.x += dir * speed * delta
	position.y = base_y + sin(t * 3.5) * 45.0
	if absf(position.x) > 720.0:
		queue_free()
	queue_redraw()


func _draw() -> void:
	# drop shadow
	draw_set_transform(Vector2(0, 3), 0.0, Vector2(1, 0.45))
	draw_circle(Vector2.ZERO, 9.0, Color(0, 0, 0, 0.25))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# waving arms
	var wave := sin(t * 12.0) * 4.0
	draw_circle(Vector2(-10, -16 - wave), 3.5, SKIN)
	draw_circle(Vector2(10, -16 + wave), 3.5, SKIN)
	# body (no shirt!) and head
	draw_circle(Vector2(0, -9), 9.0, SKIN)
	draw_arc(Vector2(0, -9), 9.0, 0, TAU, 24, SKIN.darkened(0.35), 1.5)
	draw_circle(Vector2(0, -20), 5.5, SKIN)
	# the all-important censor bar
	draw_rect(Rect2(-9, -12, 18, 6), Color.BLACK)
