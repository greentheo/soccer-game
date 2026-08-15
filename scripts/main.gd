extends Node2D
## Soccer Game — 5v5 arcade soccer with selectable clubs and two 5-minute halves.
## Side 0 is the home team and defends the left goal in the first half.

const HALF_W := 520.0    # pitch half-width (x)
const HALF_H := 280.0    # pitch half-height (y)
const GOAL_HALF := 70.0  # half-height of the goal mouth
const GOAL_H := 60.0     # ball must be below this height to count
const GOAL_DEPTH := 36.0 # net depth behind the goal line

const TEAM_RED := 0   # left / home side
const TEAM_BLUE := 1  # right / away side

const HALF_LENGTH := 300.0  # 5 minutes per half
const ET_LENGTH := 120.0    # 2-minute extra-time halves when it's a draw

const TEAMS := [
	{"name": "MAN UTD", "color": Color(0.85, 0.09, 0.12)},
	{"name": "MAN CITY", "color": Color(0.6, 0.82, 0.95)},
	{"name": "BARCELONA", "color": Color(0.7, 0.1, 0.2), "color2": Color(0.1, 0.2, 0.55)},
	{"name": "REAL MADRID", "color": Color(0.0, 0.65, 0.65)},
	{"name": "PSG", "color": Color(0.08, 0.12, 0.38)},
	{"name": "LYON", "color": Color(0.2, 0.35, 0.8)},
	{"name": "COLORADO RAPIDS", "color": Color(0.75, 0.12, 0.15), "color2": Color(0.6, 0.82, 0.95)},
	{"name": "INTER MIAMI", "color": Color(0.95, 0.6, 0.78)},
	{"name": "INTER MILAN", "color": Color(0.15, 0.25, 0.75)},
	{"name": "AC MILAN", "color": Color(0.75, 0.08, 0.1), "color2": Color(0.1, 0.1, 0.12)},
]

const PlayerScene := preload("res://scripts/player.gd")
const BallScene := preload("res://scripts/ball.gd")
const PitchScene := preload("res://scripts/pitch.gd")
const BoardsScene := preload("res://scripts/boards.gd")
const StreakerScene := preload("res://scripts/streaker.gd")

var playing := true
var red_score := 0
var blue_score := 0
var half := 1
var time_left := HALF_LENGTH
var match_over := false
var team_select := true
var human_team := -1
var streaker_done := false  # at most one pitch invasion per match

var team_idx := [0, 1]  # [left/home team, right/away team] indices into TEAMS
var possession := -1    # team currently with the ball (drives attack/defense phases)
var in_shootout := false
var practice := false   # free-play training: no clock, no opposing outfielders

# match setup menu
var sel_step := 0    # 0 = your team, 1 = opponent, 2 = home/away, 3 = match type
var sel_cursor := 0
var sel_mine := 0
var sel_side := 0    # which side the human chose (home 0 / away 1)

var players: Array = []
var ball: Node2D
var red_chaser: Node2D
var blue_chaser: Node2D

var score_label: Label
var time_label: Label
var message_label: Label
var pitch_node: Node2D
var cheer_sfx: AudioStreamPlayer

# home formation for the left team; the right team is mirrored in x.
# [position, is_goalkeeper, is_human_slot]
const FORMATION := [
	[Vector2(-480, 0), true, false],     # goalkeeper
	[Vector2(-320, -120), false, false], # defenders
	[Vector2(-320, 120), false, false],
	[Vector2(-140, -130), false, false], # forwards
	[Vector2(-140, 20), false, true],    # <- solo-mode human slot
]


func _ready() -> void:
	y_sort_enabled = true
	var cam := Camera2D.new()
	add_child(cam)

	var pitch = PitchScene.new()
	pitch.main = self
	pitch.z_index = -1
	add_child(pitch)
	pitch_node = pitch

	cheer_sfx = AudioStreamPlayer.new()
	cheer_sfx.stream = preload("res://assets/crowd_cheer.wav")
	cheer_sfx.volume_db = -4.0
	add_child(cheer_sfx)

	var boards = BoardsScene.new()
	boards.z_index = -1
	add_child(boards)

	ball = BallScene.new()
	ball.main = self

	for team in [TEAM_RED, TEAM_BLUE]:
		for entry in FORMATION:
			var p = PlayerScene.new()
			p.main = self
			p.team = team
			p.idx = players.size()
			p.base_home = entry[0] if team == TEAM_RED else Vector2(-entry[0].x, entry[0].y)
			p.home_pos = p.base_home
			p.is_gk = entry[1]
			p.is_def = absf(entry[0].x) > 250.0 and not entry[1]
			p.human_slot = entry[2]
			players.append(p)
			add_child(p)

	add_child(ball)
	ball.set_players(players)
	_build_hud()
	_to_team_select()

	# dev helper: `godot -- --screenshot <path>` saves a frame and quits
	var args := OS.get_cmdline_user_args()
	var shot_idx := args.find("--screenshot")
	if shot_idx != -1 and shot_idx + 1 < args.size():
		await get_tree().create_timer(1.0).timeout
		get_viewport().get_texture().get_image().save_png(args[shot_idx + 1])
		_start_match(TEAM_RED)
		if args.has("--streaker"):
			_spawn_streaker()
		if args.has("--pens"):
			playing = false
			_run_shootout()
			await get_tree().create_timer(3.0).timeout
		await get_tree().create_timer(1.5).timeout
		get_viewport().get_texture().get_image().save_png(args[shot_idx + 1] + ".match.png")
		get_tree().quit()


func _build_hud() -> void:
	var hud := CanvasLayer.new()
	add_child(hud)

	score_label = Label.new()
	score_label.add_theme_font_size_override("font_size", 26)
	score_label.add_theme_color_override("font_color", Color.WHITE)
	score_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	score_label.add_theme_constant_override("outline_size", 6)
	score_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	score_label.position.y = 8
	hud.add_child(score_label)

	time_label = Label.new()
	time_label.add_theme_font_size_override("font_size", 18)
	time_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	time_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	time_label.add_theme_constant_override("outline_size", 4)
	time_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	time_label.position.y = 42
	hud.add_child(time_label)

	message_label = Label.new()
	message_label.add_theme_font_size_override("font_size", 56)
	message_label.add_theme_color_override("font_color", Color(1, 0.9, 0.2))
	message_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	message_label.add_theme_constant_override("outline_size", 10)
	message_label.set_anchors_preset(Control.PRESET_CENTER)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	message_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	message_label.visible = false
	hud.add_child(message_label)

	var hint := Label.new()
	hint.text = "Arrows: move    Space: shoot (hold for power)    A: pass    E: steal    S: switch player    Shift: sprint    R: menu"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint.position.y = -28
	hud.add_child(hint)

	_update_score()


func team_name(side: int) -> String:
	return TEAMS[team_idx[side]].name


## The kit a side wears. Home: club colors (two-tone clubs get half/half
## shirts). Away: white with the club's colors as trim.
func kit(side: int) -> Dictionary:
	var t: Dictionary = TEAMS[team_idx[side]]
	var c: Color = t.color
	var c2 = t.get("color2")
	if side == TEAM_RED:
		var trim: Color = c.darkened(0.35) if c2 == null else c.lerp(c2, 0.5).darkened(0.4)
		return {"body": c, "body2": c2, "trim": trim, "trim2": trim}
	return {"body": Color(0.95, 0.95, 0.95), "body2": null,
		"trim": c, "trim2": c2 if c2 != null else c}


func _update_score() -> void:
	score_label.text = "%s  %d - %d  %s" % [team_name(TEAM_RED), red_score, blue_score, team_name(TEAM_BLUE)]


func _process(_delta: float) -> void:
	if team_select:
		_menu_input()
	elif Input.is_action_just_pressed("restart"):
		_to_team_select()
	elif playing and Input.is_action_just_pressed("switch_player"):
		switch_player()

	if practice:
		time_label.text = "PRACTICE"
	elif in_shootout:
		time_label.text = "PENALTIES"
	else:
		var secs := int(ceilf(time_left))
		var period := "1st HALF" if half == 1 else ("2nd HALF" if half == 2 else "EXTRA TIME")
		time_label.text = "%s   %d:%02d" % [period, secs / 60, secs % 60]


# ---------- match setup menu ----------

func _menu_input() -> void:
	var opts := _menu_options()
	if Input.is_action_just_pressed("move_up") or Input.is_action_just_pressed("move_left"):
		sel_cursor = (sel_cursor - 1 + opts.size()) % opts.size()
		_menu_render()
	elif Input.is_action_just_pressed("move_down") or Input.is_action_just_pressed("move_right"):
		sel_cursor = (sel_cursor + 1) % opts.size()
		_menu_render()
	elif Input.is_action_just_pressed("kick"):
		match sel_step:
			0:
				sel_mine = sel_cursor
				sel_step = 1
				sel_cursor = 0
			1:
				var opp: int = opts[sel_cursor]
				sel_step = 2
				sel_cursor = 0
				team_idx = [sel_mine, opp]  # provisional; step 2 may flip it
			2:
				var opp_final: int = team_idx[1]
				if sel_cursor == 0:
					team_idx = [sel_mine, opp_final]
					sel_side = TEAM_RED
				else:
					team_idx = [opp_final, sel_mine]
					sel_side = TEAM_BLUE
				sel_step = 3
				sel_cursor = 0
			3:
				match sel_cursor:
					0:
						_start_match(sel_side)
					1:
						_start_match(sel_side)
						playing = false
						_run_shootout()
					2:
						_start_practice(sel_side)
				return
		_menu_render()


## Free-play training: just you, your teammates, and the opposing keeper.
func _start_practice(side: int) -> void:
	_start_match(side)
	practice = true
	streaker_done = true
	for p in players:
		if p.team != side and not p.is_gk:
			p.benched = true
			p.visible = false
	_show_message("PRACTICE ARENA\nDribble around, pass with A, steal with E,\nhold Space to shoot at the far goal\nR: back to menu", 24)
	await get_tree().create_timer(6.0).timeout
	if practice and message_label.text.begins_with("PRACTICE ARENA"):
		message_label.visible = false


## Selectable entries for the current menu step (team indices, or 0/1 for home/away).
func _menu_options() -> Array:
	match sel_step:
		0:
			return range(TEAMS.size())
		1:
			var r := []
			for i in TEAMS.size():
				if i != sel_mine:
					r.append(i)
			return r
		2:
			return [0, 1]
	return [0, 1, 2]


func _menu_render() -> void:
	var lines := []
	match sel_step:
		0:
			lines.append("CHOOSE YOUR TEAM\n")
			for i in TEAMS.size():
				lines.append(("»  %s  «" if i == sel_cursor else "%s") % TEAMS[i].name)
		1:
			lines.append("CHOOSE YOUR OPPONENT\n")
			var opts := _menu_options()
			for j in opts.size():
				lines.append(("»  %s  «" if j == sel_cursor else "%s") % TEAMS[opts[j]].name)
		2:
			lines.append("PLAY AS\n")
			lines.append("»  HOME  «" if sel_cursor == 0 else "HOME")
			lines.append("»  AWAY  «" if sel_cursor == 1 else "AWAY")
			lines.append("\n(home wears home kit and defends the left goal)")
		3:
			lines.append("MATCH TYPE\n")
			lines.append("»  FULL MATCH  «" if sel_cursor == 0 else "FULL MATCH")
			lines.append("»  PENALTY SHOOTOUT  «" if sel_cursor == 1 else "PENALTY SHOOTOUT")
			lines.append("»  PRACTICE ARENA  «" if sel_cursor == 2 else "PRACTICE ARENA")
	lines.append("\nUp/Down: move    Space: confirm")
	_show_message("\n".join(lines), 24)


func _to_team_select() -> void:
	playing = false
	team_select = true
	match_over = false
	in_shootout = false
	practice = false
	red_score = 0
	blue_score = 0
	half = 1
	time_left = HALF_LENGTH
	_apply_sides()
	_update_score()
	kickoff()
	sel_step = 0
	sel_cursor = 0
	_menu_render()


func _start_match(side: int) -> void:
	human_team = side
	practice = false
	for p in players:
		p.is_human = p.human_slot and p.team == side
		p.benched = false
		p.visible = true
		p.queue_redraw()
	team_select = false
	streaker_done = false
	message_label.visible = false
	_update_score()
	kickoff()
	playing = true


func _show_message(text: String, size: int) -> void:
	message_label.add_theme_font_size_override("font_size", size)
	message_label.text = text
	message_label.visible = true


# ---------- simulation (host/solo only) ----------

func _physics_process(delta: float) -> void:
	_update_possession()
	red_chaser = _pick_chaser(TEAM_RED)
	blue_chaser = _pick_chaser(TEAM_BLUE)
	if playing:
		if not practice:
			time_left -= delta
			if time_left <= 0.0:
				time_left = 0.0
				_end_half()
				return
		if not streaker_done and randf() < delta / 800.0:
			streaker_done = true
			_spawn_streaker()
		_check_dead_ball()
		_check_goal()


## Whoever is on the ball (or nearest to a loose one) has possession.
func _update_possession() -> void:
	if ball.holder:
		possession = ball.holder.team
		return
	var best_d := 60.0
	for p in players:
		var d: float = p.position.distance_to(ball.position)
		if d < best_d:
			best_d = d
			possession = p.team


## A ball that sailed over the goal and died out of play becomes a goal kick.
func _check_dead_ball() -> void:
	if absf(ball.position.x) > HALF_W + 6.0 and ball.z <= 0.5 and ball.vel.length() < 50.0:
		var attacker := TEAM_RED if attack_goal(TEAM_RED).x * ball.position.x > 0 else TEAM_BLUE
		var defender := TEAM_BLUE if attacker == TEAM_RED else TEAM_RED
		for p in players:
			if p.team == defender and p.is_gk:
				ball.reset(p.position + Vector2(signf(-ball.position.x) * 34.0, 0))
				return


func _end_half() -> void:
	playing = false
	if half % 2 == 1:
		# break between halves (regulation or extra time)
		_show_message("HALF TIME", 56)
		await get_tree().create_timer(3.0).timeout
		half += 1
		time_left = HALF_LENGTH if half <= 2 else ET_LENGTH
		_apply_sides()
		message_label.visible = false
		kickoff()
		playing = true
	elif red_score == blue_score:
		if half >= 4:
			# still level after extra time: penalties decide it
			_run_shootout()
			return
		# level at full time: two 2-minute extra-time halves first
		_show_message("STILL LEVEL!\nEXTRA TIME", 48)
		await get_tree().create_timer(3.0).timeout
		half += 1
		time_left = ET_LENGTH
		_apply_sides()
		message_label.visible = false
		kickoff()
		playing = true
	else:
		match_over = true
		var result := "%s WINS!" % team_name(TEAM_RED if red_score > blue_score else TEAM_BLUE)
		_show_message("FULL TIME\n%s\n(R for a rematch)" % result, 44)


## Teams swap ends each half (regulation and extra time alike).
func _apply_sides() -> void:
	for p in players:
		p.home_pos = p.base_home if half % 2 == 1 else Vector2(-p.base_home.x, p.base_home.y)


func _pick_chaser(team: int) -> Node2D:
	# AI teammates yield the ball to the human — but only when the human is
	# genuinely the closest option. A teammate already on the ball keeps
	# playing it instead of abandoning it mid-dribble.
	if team == human_team:
		var human: Node2D = null
		for p in players:
			if p.team == team and p.is_human:
				human = p
		if human:
			var hd: float = human.position.distance_to(ball.position)
			var ai_nearer := false
			for p in players:
				if p.team == team and not p.is_human and not p.is_gk \
						and p.position.distance_to(ball.position) < hd:
					ai_nearer = true
					break
			if hd < 140.0 and not ai_nearer:
				return null
	var best: Node2D = null
	var best_d := INF
	for p in players:
		if p.team != team or p.is_human or p.is_gk:
			continue
		var d: float = p.position.distance_squared_to(ball.position)
		if d < best_d:
			best_d = d
			best = p
	return best


func get_chaser(team: int) -> Node2D:
	return red_chaser if team == TEAM_RED else blue_chaser


## Goal position a team is attacking (ends swap every half).
func attack_goal(team: int) -> Vector2:
	var dir := 1.0 if (team == TEAM_RED) == (half % 2 == 1) else -1.0
	return Vector2(dir * HALF_W, 0)


func _check_goal() -> void:
	if absf(ball.position.x) > HALF_W + 8.0 and absf(ball.position.y) < GOAL_HALF and ball.z < GOAL_H:
		var scorer := TEAM_RED if attack_goal(TEAM_RED).x * ball.position.x > 0 else TEAM_BLUE
		if scorer == TEAM_RED:
			red_score += 1
		else:
			blue_score += 1
		_update_score()
		playing = false
		pitch_node.cheer()
		cheer_sfx.play()
		for p in players:
			if p.team == scorer:
				p.celebrate_t = 2.0
		_show_message("GOAL!  %s" % team_name(scorer), 56)
		await get_tree().create_timer(2.0).timeout
		message_label.visible = false
		kickoff()
		playing = true


func kickoff() -> void:
	ball.reset(Vector2.ZERO)
	for p in players:
		p.position = p.home_pos
		p.velocity = Vector2.ZERO
		p.facing = Vector2.RIGHT if attack_goal(p.team).x > 0 else Vector2.LEFT


func _gk_of(t: int) -> Node2D:
	for p in players:
		if p.team == t and p.is_gk:
			return p
	return null


func _striker_of(t: int) -> Node2D:
	for p in players:
		if p.team == t and p.human_slot:
			return p
	return null


## Best-of-5 penalty shootout (sudden death if needed). Your kicks: Up/Down
## picks a corner, Space shoots. The keeper guesses a side — wrong guess is a
## goal, right guess saves half the time.
func _run_shootout() -> void:
	in_shootout = true
	_show_message("PENALTY SHOOTOUT!", 48)
	var spot := Vector2(HALF_W - 95.0, 0.0)
	await get_tree().create_timer(2.0).timeout
	# park everyone near the centre circle
	for p in players:
		p.position = Vector2(-160.0 + (p.idx % 5) * 44.0, -170.0 if p.team == TEAM_RED else 170.0)
		p.velocity = Vector2.ZERO
	var pens := [0, 0]
	var taken := [0, 0]
	var kicker := TEAM_RED
	while true:
		if team_select:
			return
		var def_team := TEAM_BLUE if kicker == TEAM_RED else TEAM_RED
		var gk = _gk_of(def_team)
		var idle_gk = _gk_of(kicker)
		var shooter = _striker_of(kicker)
		gk.position = Vector2(HALF_W - 6.0, 0.0)
		gk.velocity = Vector2.ZERO
		gk.facing = Vector2.LEFT
		idle_gk.position = Vector2(-200.0, 0.0)
		shooter.position = spot + Vector2(-32.0, 0.0)
		shooter.facing = Vector2.RIGHT
		ball.reset(spot)

		var side := 0.0
		if kicker == human_team:
			_show_message("YOUR PENALTY\nUP / DOWN picks a corner, then SPACE", 26)
			while true:
				if team_select:
					return
				await get_tree().process_frame
				if Input.is_action_just_pressed("move_up"):
					side = -1.0
					_show_message("YOUR PENALTY\nTOP corner — SPACE to shoot", 26)
				elif Input.is_action_just_pressed("move_down"):
					side = 1.0
					_show_message("YOUR PENALTY\nBOTTOM corner — SPACE to shoot", 26)
				elif Input.is_action_just_pressed("kick"):
					if side == 0.0:
						side = 1.0 if randf() < 0.5 else -1.0
					break
		else:
			_show_message("%s STEPS UP..." % team_name(kicker), 30)
			await get_tree().create_timer(1.5).timeout
			if team_select:
				return
			side = 1.0 if randf() < 0.5 else -1.0

		# keeper picks a side; wrong guess = goal, right guess saves half of them
		var ty := side * (GOAL_HALF - 16.0)
		var guess := 1.0 if randf() < 0.5 else -1.0
		var goal := guess != side or randf() < 0.5
		ball.kick(spot.direction_to(Vector2(HALF_W + 8.0, ty)), 470.0, 80.0)
		gk.dive_t = 0.5
		gk.dive_vel = Vector2(0, guess * 230.0)
		var tw := create_tween()
		tw.tween_property(gk, "position:y", guess * 44.0, 0.3)
		await get_tree().create_timer(0.32).timeout
		if team_select:
			return
		if goal:
			pens[kicker] += 1
			pitch_node.cheer()
			cheer_sfx.play()
			shooter.celebrate_t = 1.5
		else:
			ball.kick(Vector2(-1.0, -side * 0.4), 240.0, 140.0)  # parried away
		taken[kicker] += 1
		_show_message("%s\n%s %d - %d %s" % ["GOAL!" if goal else "SAVED!",
			team_name(TEAM_RED), pens[0], pens[1], team_name(TEAM_BLUE)], 34)
		await get_tree().create_timer(1.8).timeout

		var rem_a: int = maxi(0, 5 - int(taken[0]))
		var rem_b: int = maxi(0, 5 - int(taken[1]))
		if int(pens[0]) > int(pens[1]) + rem_b or int(pens[1]) > int(pens[0]) + rem_a:
			break
		if taken[0] == taken[1] and rem_a == 0 and pens[0] != pens[1]:
			break
		kicker = def_team
	in_shootout = false
	match_over = true
	var w := TEAM_RED if int(pens[0]) > int(pens[1]) else TEAM_BLUE
	_show_message("%s WINS ON PENALTIES  %d - %d\n(R for a rematch)" % [team_name(w), pens[0], pens[1]], 38)


## Hand control to this player (used when a teammate touches the ball).
func transfer_control(p: Node2D) -> void:
	if p.team != human_team or p.is_human or p.is_gk:
		return
	for q in players:
		if q.team == human_team and q.is_human:
			q.is_human = false
			q.queue_redraw()
	p.is_human = true
	p.carry_t = 0.5
	p.queue_redraw()


## Move control to the outfield teammate nearest the ball.
func switch_player() -> void:
	var current: Node2D = null
	var best: Node2D = null
	var best_d := INF
	for p in players:
		if p.team != human_team or p.is_gk:
			continue
		if p.is_human:
			current = p
			continue
		var d: float = p.position.distance_squared_to(ball.position)
		if d < best_d:
			best_d = d
			best = p
	if current and best:
		current.is_human = false
		best.is_human = true
		best.carry_t = 0.5
		current.queue_redraw()
		best.queue_redraw()


func _spawn_streaker() -> void:
	var s = StreakerScene.new()
	s.dir = 1.0 if randf() < 0.5 else -1.0
	s.base_y = randf_range(-150.0, 150.0)
	s.position = Vector2(-s.dir * 700.0, s.base_y)
	add_child(s)
	if not message_label.visible:
		_show_message("A STREAKER IS ON THE PITCH!", 30)
		await get_tree().create_timer(2.5).timeout
		if message_label.text == "A STREAKER IS ON THE PITCH!":
			message_label.visible = false
