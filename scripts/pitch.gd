extends Node2D
## Draws the pitch. Lives at z_index = -1 so it always renders below the
## Y-sorted players and ball.

var main: Node2D


func _draw() -> void:
	var half_w: float = main.HALF_W
	var half_h: float = main.HALF_H
	var goal_half: float = main.GOAL_HALF
	var goal_depth: float = main.GOAL_DEPTH

	# stadium bowl (stands background)
	draw_rect(Rect2(-700, -420, 1400, 840), Color(0.09, 0.09, 0.12))
	# grass apron around the pitch, out to the perimeter boards
	draw_rect(Rect2(-572, -314, 1144, 628), Color(0.13, 0.35, 0.16))
	# mowing stripes
	var stripe_w := half_w * 2.0 / 10.0
	for i in range(10):
		var shade := Color(0.2, 0.5, 0.22) if i % 2 == 0 else Color(0.17, 0.45, 0.19)
		draw_rect(Rect2(-half_w + i * stripe_w, -half_h, stripe_w, half_h * 2.0), shade)

	var line := Color(1, 1, 1, 0.85)
	# touchlines and center line
	draw_rect(Rect2(-half_w, -half_h, half_w * 2.0, half_h * 2.0), line, false, 3.0)
	draw_line(Vector2(0, -half_h), Vector2(0, half_h), line, 3.0)
	draw_arc(Vector2.ZERO, 70.0, 0, TAU, 48, line, 3.0)
	draw_circle(Vector2.ZERO, 4.0, line)

	# penalty boxes
	for side: float in [-1.0, 1.0]:
		var bx := side * half_w
		draw_rect(Rect2(minf(bx, bx - side * 130.0), -140, 130, 280), line, false, 3.0)
		draw_rect(Rect2(minf(bx, bx - side * 50.0), -80, 50, 160), line, false, 3.0)
		draw_circle(Vector2(bx - side * 95.0, 0), 3.0, line)

		# goal net
		var nx := bx if side > 0 else bx - goal_depth
		draw_rect(Rect2(nx, -goal_half, goal_depth, goal_half * 2.0), Color(1, 1, 1, 0.15))
		for gy in range(int(-goal_half), int(goal_half) + 1, 10):
			draw_line(Vector2(nx, gy), Vector2(nx + goal_depth, gy), Color(1, 1, 1, 0.3), 1.0)
		for gx in range(0, int(goal_depth) + 1, 9):
			draw_line(Vector2(nx + gx, -goal_half), Vector2(nx + gx, goal_half), Color(1, 1, 1, 0.3), 1.0)
		# posts
		draw_circle(Vector2(bx, -goal_half), 4.0, Color.WHITE)
		draw_circle(Vector2(bx, goal_half), 4.0, Color.WHITE)

	_draw_crowd()


## Thousands of seeded-random fans filling the stands on all four sides.
func _draw_crowd() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var palette := [
		Color(0.85, 0.85, 0.9), Color(0.6, 0.6, 0.65), Color(0.25, 0.25, 0.3),
		Color(0.9, 0.3, 0.3), Color(0.3, 0.5, 0.9), Color(0.95, 0.85, 0.3),
		Color(0.3, 0.8, 0.5), Color(0.96, 0.8, 0.65), Color(0.9, 0.55, 0.75),
	]
	var stands := [
		Rect2(-700, -420, 1400, 88),  # top
		Rect2(-700, 332, 1400, 88),   # bottom
		Rect2(-700, -326, 110, 652),  # left, behind the goal
		Rect2(590, -326, 110, 652),   # right
	]
	for stand: Rect2 in stands:
		var y := stand.position.y + 5.0
		while y < stand.end.y:
			var x := stand.position.x + 5.0
			while x < stand.end.x:
				if rng.randf() > 0.18:  # a few empty seats
					var c: Color = palette[rng.randi() % palette.size()]
					var p := Vector2(x + rng.randf_range(-2, 2), y + rng.randf_range(-2, 2))
					draw_circle(p, 2.4, c.darkened(rng.randf_range(0.0, 0.25)))
				x += 11.0
			y += 10.0
