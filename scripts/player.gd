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
var is_human := false   # controlled by a person (local or remote)
var controller := -1    # multiplayer: peer id driving this player, -1 = AI/local
var human_slot := false
var seen_pc := 0        # multiplayer: consumed remote button-press counters
var seen_sc := 0
var is_gk := false
var home_pos := Vector2.ZERO
var base_home := Vector2.ZERO
var facing := Vector2.RIGHT
var kick_cooldown := 0.0
var tackle_timer := 0.0   # active lunge time remaining
var steal_cooldown := 0.0
var charging := false     # holding Space to power up a shot
var charge_t := 0.0


func _ready() -> void:
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 9.0
	shape.shape = circle
	add_child(shape)


func _physics_process(delta: float) -> void:
	kick_cooldown = maxf(0.0, kick_cooldown - delta)
	steal_cooldown = maxf(0.0, steal_cooldown - delta)
	if not main.playing:
		velocity = Vector2.ZERO
		return

	if main.is_net_client():
		return  # puppet: position comes from host snapshots

	if tackle_timer > 0.0:
		tackle_timer -= delta
		_tackle_lunge()
	elif is_human:
		if controller != -1 and controller != main.my_id:
			_remote_control(delta)
		else:
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


## Multiplayer: drive this player from the latest input its owner sent.
func _remote_control(delta: float) -> void:
	var inp = main.remote_inputs.get(controller)
	if inp == null:
		_apply_control(delta, Vector2.ZERO, false, false, false, false)
		return
	var dirv := Vector2(float(inp.get("x", 0)), float(inp.get("y", 0))).limit_length(1.0)
	var pc := int(inp.get("pc", 0))
	var sc := int(inp.get("sc", 0))
	var pass_p := pc > seen_pc
	var steal_p := sc > seen_sc
	seen_pc = pc
	seen_sc = sc
	_apply_control(delta, dirv, bool(inp.get("spr", false)), bool(inp.get("k", false)), pass_p, steal_p)


## Shared human-control logic for local and remote players.
func _apply_control(delta: float, dir: Vector2, sprint_held: bool, kick_held: bool, pass_p: bool, steal_p: bool) -> void:
	var speed := HUMAN_SPEED * (SPRINT_MULT if sprint_held else 1.0)
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


## Multiplayer client: mirror the host's view of this player's shot charge.
func set_net_charge(v: float) -> void:
	var was := charging
	charging = v > 0.0
	charge_t = v * 0.9
	if charging or was:
		queue_redraw()


## Fire a charged shot. More charge = harder and higher — overdo it (>85%)
## and the ball sails over the bar. Slight aim scatter plus random curl means
## shots bend toward corners instead of arrowing straight at the keeper.
func _release_shot(charge: float) -> void:
	var power := 280.0 + 300.0 * charge
	var lift := 40.0 + 200.0 * charge
	if charge > 0.85:
		lift += 220.0  # leaned back too far — this one's going over
	var dir := facing.rotated(clampf(randfn(0.0, 0.06), -0.22, 0.22))
	main.ball.kick(dir, power, lift, clampf(randfn(0.0, 1.6), -2.6, 2.6))
	kick_cooldown = 0.3


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
		# hold the line, track the ball's y; rush out only if it's very close
		target = Vector2(home_pos.x, clampf(ball.position.y, -main.GOAL_HALF - 15.0, main.GOAL_HALF + 15.0))
		if position.distance_to(ball.position) < 70.0:
			target = ball.position
			chasing = true
	elif main.get_chaser(team) == self:
		target = ball.position
		chasing = true
	else:
		# drift with play, stay on the pitch
		target = home_pos + Vector2(ball.position.x * 0.3, ball.position.y * 0.2)
		target.x = clampf(target.x, -main.HALF_W + 20.0, main.HALF_W - 20.0)
		target.y = clampf(target.y, -main.HALF_H + 20.0, main.HALF_H - 20.0)

	# formation players settle and stand once they're near their spot;
	# only an active chase warrants a tight follow
	var arrive_dist := 8.0 if chasing else 35.0
	var desired := Vector2.ZERO
	if position.distance_to(target) > arrive_dist:
		var speed := AI_CHASE_SPEED if chasing else AI_HOLD_SPEED
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
		# otherwise boot it long and high over everyone's heads
		if kick_cooldown <= 0.0 and ball.z < 65.0 and position.distance_to(ball.position) < 48.0:
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
		# shoot at a corner with some curl; occasionally blaze it over
		var aim := Vector2(goal.x, randf_range(-main.GOAL_HALF + 20.0, main.GOAL_HALF - 20.0))
		var ai_lift := randf_range(60.0, 140.0)
		if randf() < 0.12:
			ai_lift = randf_range(360.0, 430.0)
		ball.kick(position.direction_to(aim), 430.0, ai_lift, randf_range(-1.6, 1.6))
	else:
		var mate := _pass_target(goal)
		if mate and randf() < 0.85:
			_pass_to(mate)
		else:
			# dribble: nudge the ball toward goal
			ball.kick(position.direction_to(goal).rotated(randf_range(-0.2, 0.2)), 190.0, 0.0)
	kick_cooldown = 0.7


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

	# yellow ring marks the player YOU control
	var ringed: bool = (main.net_mode == main.NET_SOLO and is_human) or idx == main.client_ring_idx
	if ringed:
		draw_set_transform(Vector2(0, 3), 0.0, Vector2(1, 0.5))
		draw_arc(Vector2.ZERO, 14.0, 0, TAU, 32, Color(1, 0.9, 0.2, 0.9), 2.5)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if charging:
		var c := minf(charge_t / 0.9, 1.0)
		draw_rect(Rect2(-13, -37, 26, 5), Color(0, 0, 0, 0.55))
		var col := Color(0.2, 0.9, 0.2).lerp(Color(1, 0.15, 0.1), c)
		draw_rect(Rect2(-12, -36, 24.0 * c, 3), col)

	var shirt := _team_color()
	if is_gk:
		shirt = shirt.darkened(0.45)
	draw_circle(Vector2(0, -9), 9.0, shirt)
	draw_arc(Vector2(0, -9), 9.0, 0, TAU, 24, shirt.darkened(0.4), 1.5)
	draw_circle(Vector2(0, -20), 5.5, SKIN)


func _team_color() -> Color:
	return main.kit_color(team)
