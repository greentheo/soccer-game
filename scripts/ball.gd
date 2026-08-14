extends Node2D
## The ball. Plain Node2D with hand-rolled 2.5D physics: 2D position on the
## pitch plus a height (z) with gravity and bouncing. Players dribble it by
## touching it and kick it via kick().

const GRAVITY := 900.0
const RADIUS := 6.5

var main: Node2D
var vel := Vector2.ZERO
var z := 0.0       # height above the ground
var vz := 0.0
var no_touch := 0.0 # brief window after a kick where dribble contact is ignored
var spin := 0.0     # curls the ball's flight path (radians/sec)
var holder: Node2D = null # human player carrying the ball (sticky dribble)
var shield_grace := 0.0   # steal protection right after winning the ball

var _players: Array = []


func set_players(players: Array) -> void:
	_players = players


func reset(pos: Vector2) -> void:
	position = pos
	vel = Vector2.ZERO
	z = 0.0
	vz = 0.0
	no_touch = 0.0
	spin = 0.0
	holder = null


func kick(dir: Vector2, power: float, lift: float, spin_amt := 0.0) -> void:
	holder = null
	vel = dir.normalized() * power
	vz = lift
	spin = spin_amt
	no_touch = 0.3


func _physics_process(delta: float) -> void:
	no_touch = maxf(0.0, no_touch - delta)

	# sticky dribble: ball rides at the human's feet until kicked or knocked loose
	if holder:
		shield_grace = maxf(0.0, shield_grace - delta)
		if not holder.is_human or not main.playing:
			holder = null
		else:
			position = holder.position + holder.facing * 13.0
			vel = holder.velocity
			z = 0.0
			vz = 0.0
			for p in _players:
				if p.team == holder.team or shield_grace > 0.0:
					continue
				# a defender only wins the ball if it's exposed to them —
				# turning your back (body between them and the ball) shields it
				var d_ball: float = p.position.distance_to(position)
				if d_ball < 15.0 and d_ball < p.position.distance_to(holder.position):
					var knock: Vector2 = (position - p.position).normalized() * 130.0
					holder = null
					vel = knock
					no_touch = 0.15
					break
			queue_redraw()
			return

	# vertical motion
	if z > 0.0 or vz > 0.0:
		vz -= GRAVITY * delta
		z += vz * delta
		if z <= 0.0:
			z = 0.0
			vz = -vz * 0.45 if vz < -80.0 else 0.0
		vel *= pow(0.85, delta)  # light air drag
	else:
		vel *= pow(0.4, delta)   # ground friction
		vel = vel.move_toward(Vector2.ZERO, 25.0 * delta)

	# dribble: a nearby player nudges the ball along. The human gets a bigger
	# control radius, wins contested touches, and keeps the ball closer.
	if no_touch <= 0.0 and z < 20.0 and main.playing:
		var toucher: Node2D = null
		for p in _players:
			if p.is_gk:
				continue  # keepers clear the ball properly instead of nudging it
			var reach: float = 24.0 if p.is_human else 19.0
			if p.position.distance_to(position) < reach:
				if toucher == null or (p.is_human and not toucher.is_human):
					toucher = p
		if toucher:
			# any touch by the human's team hands control to that player
			if toucher.team == main.human_team and not toucher.is_human:
				main.transfer_control(toucher)
			if toucher.is_human:
				if holder != toucher:
					shield_grace = 0.5
				holder = toucher
			else:
				vel = vel * 0.2 + toucher.velocity + (position - toucher.position).normalized() * 60.0

	# curl: spin bends the flight path while the ball is moving fast
	if absf(spin) > 0.01 and vel.length() > 120.0:
		vel = vel.rotated(spin * delta)
	spin = move_toward(spin, 0.0, 0.6 * delta)

	position += vel * delta
	_bounce_off_bounds()
	queue_redraw()


func _bounce_off_bounds() -> void:
	var hw: float = main.HALF_W
	var hh: float = main.HALF_H
	var in_goal_mouth: bool = absf(position.y) < main.GOAL_HALF and z < main.GOAL_H

	if absf(position.x) > hw:
		if in_goal_mouth:
			# inside the net: stop against the back
			var back: float = hw + main.GOAL_DEPTH - RADIUS
			if absf(position.x) > back:
				position.x = signf(position.x) * back
				vel *= 0.1
		elif z > 55.0:
			# sailing over the goal/wall: fly on, bounce off the boards behind
			if absf(position.x) > 690.0:
				position.x = signf(position.x) * 690.0
				vel.x = -vel.x * 0.4
				vel.y *= 0.6
		else:
			position.x = signf(position.x) * hw
			vel.x = -vel.x * 0.7

	if absf(position.y) > hh:
		position.y = signf(position.y) * hh
		vel.y = -vel.y * 0.7


func _draw() -> void:
	# shadow stays on the ground, fades as the ball rises
	var shadow_alpha := clampf(0.3 - z * 0.002, 0.08, 0.3)
	draw_set_transform(Vector2(0, 2), 0.0, Vector2(1, 0.5))
	draw_circle(Vector2.ZERO, RADIUS, Color(0, 0, 0, shadow_alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var pos := Vector2(0, -4.0 - z * 0.5)
	draw_circle(pos, RADIUS, Color.WHITE)
	draw_arc(pos, RADIUS, 0, TAU, 24, Color(0.2, 0.2, 0.2, 0.8), 1.2)
	draw_arc(pos, RADIUS * 0.5, 0.4, 2.6, 12, Color(0.3, 0.3, 0.3, 0.6), 1.2)
