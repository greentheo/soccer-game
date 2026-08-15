extends CharacterBody2D
## One soccer player. Controlled by the keyboard if is_human, otherwise by a
## simple AI: the designated chaser goes for the ball, everyone else holds a
## formation position that shifts with the ball. Goalkeepers guard the line.

const HUMAN_SPEED := 190.0
const AI_CHASE_SPEED := 175.0
const AI_HOLD_SPEED := 130.0
const SPRINT_MULT := 1.35
const KICK_RANGE := 30.0
const HUMAN_ACCEL := 1300.0  # responsive but not instant
const AI_ACCEL := 700.0      # AI eases in and out of runs
const SKIN := Color(0.96, 0.8, 0.65)

var main: Node2D
var team := 0
var idx := 0            # index in main.players
var is_human := false
var human_slot := false
var is_gk := false
var is_def := false
var benched := false    # practice mode: off the pitch entirely
var home_pos := Vector2.ZERO
var base_home := Vector2.ZERO
var facing := Vector2.RIGHT
var kick_cooldown := 0.0
var tackle_timer := 0.0   # active lunge time remaining
var steal_cooldown := 0.0
var charging := false     # holding Space to power up a shot
var charge_t := 0.0
var celebrate_t := 0.0    # post-goal celebration time remaining
var carry_t := 0.0        # keep momentum right after gaining control
var dive_t := 0.0         # goalkeeper dive time remaining
var dive_vel := Vector2.ZERO


func _process(delta: float) -> void:
	if celebrate_t > 0.0:
		celebrate_t -= delta
		queue_redraw()
	if dive_t > 0.0:
		dive_t = maxf(0.0, dive_t - delta)
		queue_redraw()


func _ready() -> void:
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 9.0
	shape.shape = circle
	add_child(shape)


func _physics_process(delta: float) -> void:
	if benched:
		return
	kick_cooldown = maxf(0.0, kick_cooldown - delta)
	steal_cooldown = maxf(0.0, steal_cooldown - delta)
	if not main.playing:
		velocity = Vector2.ZERO
		return

	if tackle_timer > 0.0:
		tackle_timer -= delta
		_tackle_lunge()
	elif is_human:
		_human_control(delta)
	else:
		_ai_control(delta)

	move_and_slide()
	position.x = clampf(position.x, -main.HALF_W - 20.0, main.HALF_W + 20.0)
	position.y = clampf(position.y, -main.HALF_H - 10.0, main.HALF_H + 10.0)


func _human_control(delta: float) -> void:
	_apply_control(delta,
		Input.get_vector("move_left", "move_right", "move_up", "move_down"),
		Input.is_action_pressed("sprint"),
		Input.is_action_pressed("kick"),
		Input.is_action_just_pressed("pass"),
		Input.is_action_just_pressed("steal"))


## Shared human-control logic for local and remote players.
func _apply_control(delta: float, dir: Vector2, sprint_held: bool, kick_held: bool, pass_p: bool, steal_p: bool) -> void:
	var speed := HUMAN_SPEED * (SPRINT_MULT if sprint_held else 1.0)
	if dir == Vector2.ZERO and carry_t > 0.0:
		# just took over this player: keep their run going until steered
		carry_t -= delta
		if velocity.length() > 20.0:
			facing = velocity.normalized()
	else:
		carry_t = 0.0
		velocity = velocity.move_toward(dir * speed, HUMAN_ACCEL * delta)
		if dir != Vector2.ZERO:
			facing = dir.normalized()

	# shot charging: hold the kick button to wind up, release to shoot
	if charging:
		charge_t += delta
		queue_redraw()
		if not kick_held:
			charging = false
			queue_redraw()
			if _ball_in_range(40.0):
				_release_shot(minf(charge_t / 0.9, 1.0))
		return

	if steal_p and steal_cooldown <= 0.0:
		tackle_timer = 0.18
		steal_cooldown = 0.8
		_tackle_lunge()
		return

	if kick_cooldown > 0.0 or not _ball_in_range(40.0):
		return
	if kick_held:
		charging = true
		charge_t = 0.0
	elif pass_p:
		var mate := _best_pass_mate()
		if mate:
			_pass_to(mate)
		else:
			main.ball.kick(facing, 260.0, 20.0)
		kick_cooldown = 0.3


## Fire a charged shot: dead straight into the corner away from the keeper.
## The keeper saves 60% of on-target shots; overcharging (>85%) skies it.
func _release_shot(charge: float) -> void:
	var power := 280.0 + 300.0 * charge
	var lift := 40.0 + 200.0 * charge
	if charge > 0.85:
		lift += 220.0  # leaned back too far — this one's going over
	var aim: Vector2 = main.attack_goal(team) + Vector2(0, _far_corner_side() * (main.GOAL_HALF - 14.0))
	main.ball.kick(position.direction_to(aim), power, lift, 0.0)
	if charge <= 0.85:
		main.ball.mark_shot(randf() < 0.6)
	kick_cooldown = 0.3


## Corner away from wherever the opposing keeper is standing.
func _far_corner_side() -> float:
	for p in main.players:
		if p.team != team and p.is_gk:
			if absf(p.position.y) > 2.0:
				return -signf(p.position.y)
	return 1.0 if randf() < 0.5 else -1.0


## Quick dash toward facing; pokes the ball loose if we reach it.
func _tackle_lunge() -> void:
	velocity = facing * HUMAN_SPEED * 1.9
	var ball: Node2D = main.ball
	if ball.z < 25.0 and position.distance_to(ball.position) < 32.0:
		ball.kick(facing, 150.0, 0.0)
		tackle_timer = 0.0


## Teammate closest to the direction we're facing (within ~75 degrees).
func _best_pass_mate() -> Node2D:
	var best: Node2D = null
	var best_angle := 1.3
	for p in main.players:
		if p == self or p.team != team:
			continue
		var to_mate: Vector2 = position.direction_to(p.position)
		var angle := absf(facing.angle_to(to_mate))
		if angle < best_angle and position.distance_to(p.position) > 30.0:
			best_angle = angle
			best = p
	return best


func _ai_control(delta: float) -> void:
	var ball: Node2D = main.ball
	var target := home_pos
	var chasing := false

	if is_gk:
		# mid-dive: committed, keep flying
		if dive_t > 0.0:
			velocity = dive_vel
			_ai_try_kick()
			return
		# incoming shot: dive! Toward it if we read it, the wrong way if sold.
		if ball.is_shot and ball.z < 80.0 and position.distance_to(ball.position) < 120.0:
			var toward := signf(ball.position.y - position.y)
			if toward == 0.0:
				toward = 1.0
			dive_t = 0.5
			dive_vel = Vector2(0, toward if ball.shot_saveable else -toward) * 230.0
			velocity = dive_vel
			_ai_try_kick()
			return
		# hold the line, track the ball's y; rush out only if it's very close
		target = Vector2(home_pos.x, clampf(ball.position.y, -main.GOAL_HALF - 15.0, main.GOAL_HALF + 15.0))
		if position.distance_to(ball.position) < 70.0:
			target = ball.position
			chasing = true
	elif main.get_chaser(team) == self:
		target = ball.position
		chasing = true
	else:
		var attack_dir: float = signf(main.attack_goal(team).x)
		if main.possession == team:
			# attacking phase: push upfield in support of the ball
			var push := 90.0 if is_def else 170.0
			target = home_pos + Vector2(ball.position.x * 0.35 + attack_dir * push, ball.position.y * 0.25)
		elif main.possession != -1:
			# defending phase: drop deep; defenders man-mark goal-side
			var threat := _nearest_opponent() if is_def else null
			if threat:
				var own_goal: Vector2 = -main.attack_goal(team)
				target = threat.position + threat.position.direction_to(own_goal) * 26.0
			else:
				target = home_pos + Vector2(ball.position.x * 0.3 - attack_dir * 60.0, ball.position.y * 0.35)
		else:
			# neutral: drift with play
			target = home_pos + Vector2(ball.position.x * 0.3, ball.position.y * 0.2)
		target.x = clampf(target.x, -main.HALF_W + 20.0, main.HALF_W - 20.0)
		target.y = clampf(target.y, -main.HALF_H + 20.0, main.HALF_H - 20.0)

	# formation players settle and stand once they're near their spot;
	# only an active chase warrants a tight follow
	var arrive_dist := 8.0 if chasing else 35.0
	var desired := Vector2.ZERO
	if position.distance_to(target) > arrive_dist:
		var speed := AI_CHASE_SPEED if chasing else AI_HOLD_SPEED
		if chasing and main.possession != team:
			speed += 15.0  # press harder when the other side has it
		desired = position.direction_to(target) * speed
	velocity = velocity.move_toward(desired, AI_ACCEL * delta)
	if velocity.length() > 20.0:
		facing = velocity.normalized()

	_ai_try_kick()


func _ai_try_kick() -> void:
	var ball: Node2D = main.ball
	var goal: Vector2 = main.attack_goal(team)

	if is_gk:
		# save, then distribute: prefer an open teammate in our own half,
		# otherwise boot it long and high over everyone's heads.
		# Shots on goal are pre-rolled: 60% the keeper reads it (long reach),
		# 40% the corner placement sells him (tiny reach, it flies past).
		var reach := 48.0
		if ball.is_shot:
			reach = 85.0 if ball.shot_saveable else 20.0
		if kick_cooldown <= 0.0 and ball.z < 65.0 and position.distance_to(ball.position) < reach:
			var outlet := _gk_outlet()
			if outlet and randf() < 0.65:
				var aim: Vector2 = outlet.position + outlet.velocity * 0.3
				var d := position.distance_to(aim)
				ball.kick(position.direction_to(aim), clampf(d * 1.4, 260.0, 460.0), 130.0)
			else:
				var dir := position.direction_to(goal).rotated(randf_range(-0.35, 0.35))
				ball.kick(dir, 540.0, randf_range(340.0, 420.0))
			kick_cooldown = 0.4
		return

	if kick_cooldown > 0.0 or not _ball_in_range(KICK_RANGE):
		return

	if position.distance_to(goal) < 260.0 and randf() < 0.75:
		# straight shot into the corner away from the keeper; occasionally over
		var aim := Vector2(goal.x, (main.GOAL_HALF - 14.0) * _far_corner_side())
		var ai_lift := randf_range(60.0, 140.0)
		var skied := randf() < 0.12
		if skied:
			ai_lift = randf_range(360.0, 430.0)
		ball.kick(position.direction_to(aim), 430.0, ai_lift, 0.0)
		if not skied:
			ball.mark_shot(randf() < 0.6)
	else:
		var mate := _pass_target(goal)
		if mate and randf() < 0.85:
			_pass_to(mate)
		else:
			# dribble: nudge the ball toward goal
			ball.kick(position.direction_to(goal).rotated(randf_range(-0.2, 0.2)), 190.0, 0.0)
	kick_cooldown = 0.7


## Closest opposing outfield player (marking target for defenders).
func _nearest_opponent() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in main.players:
		if p.team == team or p.is_gk:
			continue
		var d: float = position.distance_squared_to(p.position)
		if d < best_d:
			best_d = d
			best = p
	return best


## Safest short outlet for the keeper: a teammate in our own half with no
## opponent near them. Returns null if everyone is marked.
func _gk_outlet() -> Node2D:
	var own_side: float = -signf(main.attack_goal(team).x)
	var best: Node2D = null
	var best_open := 0.0
	for p in main.players:
		if p == self or p.team != team or p.is_gk:
			continue
		if p.position.x * own_side < 0.0:
			continue  # not on our half
		var d: float = position.distance_to(p.position)
		if d < 80.0 or d > 430.0:
			continue
		var openness := INF
		for q in main.players:
			if q.team != team:
				openness = minf(openness, q.position.distance_to(p.position))
		if openness > best_open:
			best_open = openness
			best = p
	return best if best_open > 90.0 else null


## Kick the ball to a teammate, leading their run a little.
func _pass_to(mate: Node2D) -> void:
	var aim: Vector2 = mate.position + mate.velocity * 0.3
	var dist := position.distance_to(aim)
	main.ball.kick(position.direction_to(aim), clampf(dist * 1.5, 220.0, 430.0), 30.0)


## Random teammate in a passable spot: not too close, not way behind us.
func _pass_target(goal: Vector2) -> Node2D:
	var my_d := position.distance_to(goal)
	var candidates: Array = []
	for p in main.players:
		if p == self or p.team != team or p.is_gk:
			continue
		var dist := position.distance_to(p.position)
		if dist < 50.0 or dist > 450.0:
			continue
		if p.position.distance_to(goal) < my_d + 80.0:  # allows square/slightly-back passes
			candidates.append(p)
	# feed the human when they're an option
	for c in candidates:
		if c.is_human and randf() < 0.6:
			return c
	return candidates.pick_random() if not candidates.is_empty() else null


func _ball_in_range(r: float) -> bool:
	var ball: Node2D = main.ball
	return ball.z < 30.0 and position.distance_to(ball.position) < r


func _draw() -> void:
	# drop shadow (squashed circle for the 2.5D look)
	draw_set_transform(Vector2(0, 3), 0.0, Vector2(1, 0.45))
	draw_circle(Vector2.ZERO, 9.0, Color(0, 0, 0, 0.25))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if is_human:
		draw_set_transform(Vector2(0, 3), 0.0, Vector2(1, 0.5))
		draw_arc(Vector2.ZERO, 14.0, 0, TAU, 32, Color(1, 0.9, 0.2, 0.9), 2.5)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if charging:
		var c := minf(charge_t / 0.9, 1.0)
		draw_rect(Rect2(-13, -37, 26, 5), Color(0, 0, 0, 0.55))
		var col := Color(0.2, 0.9, 0.2).lerp(Color(1, 0.15, 0.1), c)
		draw_rect(Rect2(-12, -36, 24.0 * c, 3), col)

	var kit: Dictionary = main.kit(team)
	var body: Color = kit.body
	var trim: Color = kit.trim
	var trim2: Color = kit.trim2
	if is_gk:
		body = body.darkened(0.45)
		trim = trim.darkened(0.45)
		trim2 = trim2.darkened(0.45)

	# goalkeeper dive: body tips over and lunges in the dive direction
	if dive_t > 0.0:
		var prog := clampf((0.5 - dive_t) * 3.5, 0.0, 1.0)
		var dn := dive_vel.normalized()
		draw_set_transform(dn * prog * 9.0, dn.y * prog * 1.1, Vector2.ONE)
	# goal celebration: hop up and down with arms in the air
	elif celebrate_t > 0.0:
		var hop := absf(sin(celebrate_t * 9.0)) * 6.0
		draw_set_transform(Vector2(0, -hop), 0.0, Vector2.ONE)
		draw_circle(Vector2(-9, -22), 3.5, SKIN)
		draw_circle(Vector2(9, -22), 3.5, SKIN)

	draw_circle(Vector2(0, -9), 9.0, body)
	if kit.body2 != null:
		# two-tone club: right half of the shirt in the second color
		var half: Color = kit.body2
		if is_gk:
			half = half.darkened(0.45)
		var pts := PackedVector2Array()
		pts.append(Vector2(0, -9))
		for i in 13:
			var a := -PI / 2.0 + PI * i / 12.0
			pts.append(Vector2(0, -9) + Vector2(cos(a), sin(a)) * 9.0)
		draw_colored_polygon(pts, half)
	draw_arc(Vector2(0, -9), 9.0, 0, TAU, 24, trim, 2.0)
	if kit.body2 == null:
		draw_rect(Rect2(-6.0, -11.0, 6.0, 3.0), trim)
		draw_rect(Rect2(0.0, -11.0, 6.0, 3.0), trim2)
	draw_circle(Vector2(0, -20), 5.5, SKIN)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

