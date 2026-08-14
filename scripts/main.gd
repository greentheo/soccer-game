extends Node2D
## Soccer Game — Man United (red) vs Man City (sky blue), 5v5 arcade soccer.
## Red defends the left goal and attacks right; Blue mirrors it.

const HALF_W := 520.0    # pitch half-width (x)
const HALF_H := 280.0    # pitch half-height (y)
const GOAL_HALF := 70.0  # half-height of the goal mouth
const GOAL_H := 60.0     # ball must be below this height to count
const GOAL_DEPTH := 36.0 # net depth behind the goal line

const TEAM_RED := 0
const TEAM_BLUE := 1
const TEAM_NAMES := ["MAN UTD", "MAN CITY"]

const HALF_LENGTH := 300.0  # 5 minutes per half

const PlayerScene := preload("res://scripts/player.gd")
const BallScene := preload("res://scripts/ball.gd")
const PitchScene := preload("res://scripts/pitch.gd")
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

var players: Array = []
var ball: Node2D
var red_chaser: Node2D
var blue_chaser: Node2D

var score_label: Label
var time_label: Label
var message_label: Label

# home formation for the red team; blue is mirrored in x.
# [position, is_goalkeeper, is_human]
const FORMATION := [
	[Vector2(-480, 0), true, false],     # goalkeeper
	[Vector2(-320, -120), false, false], # defenders
	[Vector2(-320, 120), false, false],
	[Vector2(-140, -130), false, false], # forwards
	[Vector2(-140, 20), false, true],    # <- you
]


func _ready() -> void:
	y_sort_enabled = true
	var cam := Camera2D.new()
	add_child(cam)

	var pitch = PitchScene.new()
	pitch.main = self
	pitch.z_index = -1
	add_child(pitch)

	ball = BallScene.new()
	ball.main = self

	for team in [TEAM_RED, TEAM_BLUE]:
		for entry in FORMATION:
			var p = PlayerScene.new()
			p.main = self
			p.team = team
			p.base_home = entry[0] if team == TEAM_RED else Vector2(-entry[0].x, entry[0].y)
			p.home_pos = p.base_home
			p.is_gk = entry[1]
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
	hint.text = "Arrows: move    Space: shoot    A: pass    E: steal    S: switch player    Shift: sprint    R: menu"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint.position.y = -28
	hud.add_child(hint)

	_update_score()


func _update_score() -> void:
	score_label.text = "%s  %d - %d  %s" % [TEAM_NAMES[0], red_score, blue_score, TEAM_NAMES[1]]


func _process(_delta: float) -> void:
	if team_select:
		if Input.is_action_just_pressed("move_left"):
			_start_match(TEAM_RED)
		elif Input.is_action_just_pressed("move_right"):
			_start_match(TEAM_BLUE)
	elif Input.is_action_just_pressed("restart"):
		_to_team_select()
	elif playing and Input.is_action_just_pressed("switch_player"):
		switch_player()

	var secs := int(ceilf(time_left))
	time_label.text = "%s HALF   %d:%02d" % ["1st" if half == 1 else "2nd", secs / 60, secs % 60]


func _to_team_select() -> void:
	playing = false
	team_select = true
	match_over = false
	red_score = 0
	blue_score = 0
	half = 1
	time_left = HALF_LENGTH
	_apply_sides()
	_update_score()
	kickoff()
	_show_message("CHOOSE YOUR TEAM\n\n[ ← ]  MAN UTD        MAN CITY  [ → ]", 36)


func _start_match(chosen_team: int) -> void:
	human_team = chosen_team
	for p in players:
		p.is_human = p.human_slot and p.team == chosen_team
		p.queue_redraw()
	team_select = false
	streaker_done = false
	message_label.visible = false
	kickoff()
	playing = true


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


## Hand control to this player (used when a teammate touches the ball).
func transfer_control(p: Node2D) -> void:
	if p.team != human_team or p.is_human or p.is_gk:
		return
	for q in players:
		if q.team == human_team and q.is_human:
			q.is_human = false
			q.queue_redraw()
	p.is_human = true
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
		best.facing = current.facing
		current.queue_redraw()
		best.queue_redraw()


func _show_message(text: String, size: int) -> void:
	message_label.add_theme_font_size_override("font_size", size)
	message_label.text = text
	message_label.visible = true


func _physics_process(delta: float) -> void:
	red_chaser = _pick_chaser(TEAM_RED)
	blue_chaser = _pick_chaser(TEAM_BLUE)
	if playing:
		time_left -= delta
		if time_left <= 0.0:
			time_left = 0.0
			_end_half()
			return
		# rare pitch invasion: on average about one every game or two
		if not streaker_done and randf() < delta / 800.0:
			streaker_done = true
			_spawn_streaker()
		_check_goal()


func _end_half() -> void:
	playing = false
	if half == 1:
		_show_message("HALF TIME", 56)
		await get_tree().create_timer(3.0).timeout
		half = 2
		time_left = HALF_LENGTH
		_apply_sides()
		message_label.visible = false
		kickoff()
		playing = true
	else:
		match_over = true
		var result := "DRAW"
		if red_score > blue_score:
			result = "%s WINS!" % TEAM_NAMES[TEAM_RED]
		elif blue_score > red_score:
			result = "%s WINS!" % TEAM_NAMES[TEAM_BLUE]
		_show_message("FULL TIME\n%s\n(R for a rematch)" % result, 44)


## Teams swap ends for the second half.
func _apply_sides() -> void:
	for p in players:
		p.home_pos = p.base_home if half == 1 else Vector2(-p.base_home.x, p.base_home.y)


func _pick_chaser(team: int) -> Node2D:
	# your ball: AI teammates don't contest when the human is close to it
	if team == human_team:
		for p in players:
			if p.is_human and p.position.distance_to(ball.position) < 140.0:
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


## Goal position a team is attacking (ends swap at half time).
func attack_goal(team: int) -> Vector2:
	var dir := 1.0 if (team == TEAM_RED) == (half == 1) else -1.0
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
		_show_message("GOAL!  %s" % TEAM_NAMES[scorer], 56)
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
