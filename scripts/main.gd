extends Node2D
## Soccer Game — 5v5 arcade soccer with selectable clubs, two 5-minute halves,
## and link-join multiplayer (first to connect hosts; each person is one player).
## Side 0 is the home team and defends the left goal in the first half.

const HALF_W := 520.0    # pitch half-width (x)
const HALF_H := 280.0    # pitch half-height (y)
const GOAL_HALF := 70.0  # half-height of the goal mouth
const GOAL_H := 60.0     # ball must be below this height to count
const GOAL_DEPTH := 36.0 # net depth behind the goal line

const TEAM_RED := 0   # left / home side
const TEAM_BLUE := 1  # right / away side

const HALF_LENGTH := 300.0  # 5 minutes per half

const NET_SOLO := 0
const NET_HOST := 1
const NET_CLIENT := 2

const TEAMS := [
	{"name": "MAN UTD", "home": Color(0.83, 0.09, 0.12), "away": Color(0.92, 0.92, 0.92)},
	{"name": "MAN CITY", "home": Color(0.42, 0.72, 0.92), "away": Color(0.15, 0.17, 0.35)},
	{"name": "BARCELONA", "home": Color(0.55, 0.1, 0.3), "away": Color(0.95, 0.85, 0.2)},
	{"name": "REAL MADRID", "home": Color(0.95, 0.95, 0.95), "away": Color(0.12, 0.14, 0.4)},
	{"name": "PSG", "home": Color(0.1, 0.12, 0.35), "away": Color(0.93, 0.93, 0.93)},
	{"name": "LYON", "home": Color(0.9, 0.9, 0.95), "away": Color(0.15, 0.2, 0.5)},
	{"name": "COLORADO RAPIDS", "home": Color(0.55, 0.15, 0.25), "away": Color(0.6, 0.8, 0.95)},
	{"name": "INTER MIAMI", "home": Color(0.95, 0.55, 0.75), "away": Color(0.15, 0.15, 0.15)},
	{"name": "INTER MILAN", "home": Color(0.15, 0.25, 0.6), "away": Color(0.9, 0.9, 0.9)},
	{"name": "AC MILAN", "home": Color(0.55, 0.08, 0.1), "away": Color(0.92, 0.92, 0.92)},
]

const PlayerScene := preload("res://scripts/player.gd")
const BallScene := preload("res://scripts/ball.gd")
const PitchScene := preload("res://scripts/pitch.gd")
const StreakerScene := preload("res://scripts/streaker.gd")

# multiplayer slot order: strikers first, then forwards, then defenders.
# Indices into `players`; goalkeepers (0 and 5) are never given to a person.
const ASSIGN_ORDER := [4, 9, 3, 8, 1, 6, 2, 7]

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

# match setup menu
var sel_step := 0    # 0 = your team, 1 = opponent, 2 = home/away
var sel_cursor := 0
var sel_mine := 0

# networking
var net_mode := NET_SOLO
var ws: WebSocketPeer = null
var net_connected := false
var my_id := 0
var host_id := 0
var assignments := {}    # peer id -> player index (host authoritative)
var remote_inputs := {}  # peer id -> latest input packet (host side)
var client_ring_idx := -1
var snap_timer := 0.0
var in_pc := 0  # client: cumulative pass presses
var in_sc := 0  # client: cumulative steal presses

var players: Array = []
var ball: Node2D
var red_chaser: Node2D
var blue_chaser: Node2D

var score_label: Label
var time_label: Label
var message_label: Label

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
			p.human_slot = entry[2]
			players.append(p)
			add_child(p)

	add_child(ball)
	ball.set_players(players)
	_build_hud()
	_to_team_select()
	_net_setup()

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


## The kit a side wears: home team in home colors, away team in away colors.
func kit_color(side: int) -> Color:
	return TEAMS[team_idx[side]]["home" if side == TEAM_RED else "away"]


func _update_score() -> void:
	score_label.text = "%s  %d - %d  %s" % [team_name(TEAM_RED), red_score, blue_score, team_name(TEAM_BLUE)]


func is_net_client() -> bool:
	return net_mode == NET_CLIENT and ws != null


func _process(delta: float) -> void:
	_net_poll(delta)

	if team_select and net_mode == NET_SOLO:
		_menu_input()
	elif net_mode == NET_SOLO and Input.is_action_just_pressed("restart"):
		_to_team_select()
	elif playing and net_mode != NET_CLIENT and Input.is_action_just_pressed("switch_player"):
		switch_player()

	var secs := int(ceilf(time_left))
	time_label.text = "%s HALF   %d:%02d" % ["1st" if half == 1 else "2nd", secs / 60, secs % 60]


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
					_start_match(TEAM_RED)
				else:
					team_idx = [opp_final, sel_mine]
					_start_match(TEAM_BLUE)
				return
		_menu_render()


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
	return [0, 1]


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
	lines.append("\nUp/Down: move    Space: confirm")
	_show_message("\n".join(lines), 24)


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
	sel_step = 0
	sel_cursor = 0
	_menu_render()


func _start_match(side: int) -> void:
	human_team = side
	for p in players:
		p.is_human = p.human_slot and p.team == side
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
	if is_net_client():
		return
	red_chaser = _pick_chaser(TEAM_RED)
	blue_chaser = _pick_chaser(TEAM_BLUE)
	if playing:
		time_left -= delta
		if time_left <= 0.0:
			time_left = 0.0
			_end_half()
			return
		if net_mode == NET_SOLO and not streaker_done and randf() < delta / 800.0:
			streaker_done = true
			_spawn_streaker()
		_check_dead_ball()
		_check_goal()


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
			result = "%s WINS!" % team_name(TEAM_RED)
		elif blue_score > red_score:
			result = "%s WINS!" % team_name(TEAM_BLUE)
		_show_message("FULL TIME\n%s\n(R for a rematch)" % result, 44)
		if net_mode == NET_HOST:
			await get_tree().create_timer(5.0).timeout
			_start_net_match()


## Teams swap ends for the second half.
func _apply_sides() -> void:
	for p in players:
		p.home_pos = p.base_home if half == 1 else Vector2(-p.base_home.x, p.base_home.y)


func _pick_chaser(team: int) -> Node2D:
	# a human's ball: AI teammates don't contest when a person is close to it
	if team == human_team or net_mode != NET_SOLO:
		for p in players:
			if p.team == team and p.is_human and p.position.distance_to(ball.position) < 140.0:
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


## Hand control to this player (used when a teammate touches the ball). Solo only.
func transfer_control(p: Node2D) -> void:
	if net_mode != NET_SOLO:
		return
	if p.team != human_team or p.is_human or p.is_gk:
		return
	for q in players:
		if q.team == human_team and q.is_human:
			q.is_human = false
			q.queue_redraw()
	p.is_human = true
	p.queue_redraw()


## Move control to the outfield teammate nearest the ball. Solo only.
func switch_player() -> void:
	if net_mode != NET_SOLO:
		return
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


# ---------- multiplayer ----------

## Join a relay if a server was given via `?server=` (web) or `--server` (desktop).
func _net_setup() -> void:
	var url := ""
	var args := OS.get_cmdline_user_args()
	var si := args.find("--server")
	if si != -1 and si + 1 < args.size():
		url = args[si + 1]
	elif OS.has_feature("web"):
		var search := str(JavaScriptBridge.eval("window.location.search", true))
		for part in search.trim_prefix("?").split("&"):
			if part.begins_with("server="):
				url = part.trim_prefix("server=").uri_decode()
	if url == "":
		return
	ws = WebSocketPeer.new()
	if ws.connect_to_url(url) != OK:
		ws = null
		_show_message("CONNECTION FAILED", 40)
		return
	net_mode = NET_CLIENT
	team_select = false
	playing = false
	_show_message("CONNECTING...", 40)


func _net_poll(delta: float) -> void:
	if ws == null:
		return
	ws.poll()
	var state := ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		ws = null
		net_connected = false
		_show_message("DISCONNECTED\n(refresh to rejoin)", 40)
		playing = false
		return
	if state != WebSocketPeer.STATE_OPEN:
		return
	while ws.get_available_packet_count() > 0:
		var d = JSON.parse_string(ws.get_packet().get_string_from_utf8())
		if d is Dictionary:
			_net_msg(d)

	# client: count button presses between sends so quick taps aren't lost
	if net_mode == NET_CLIENT and net_connected:
		if Input.is_action_just_pressed("pass"):
			in_pc += 1
		if Input.is_action_just_pressed("steal"):
			in_sc += 1

	snap_timer -= delta
	if snap_timer <= 0.0:
		snap_timer = 0.05
		if net_mode == NET_HOST:
			_send_snap()
		elif net_mode == NET_CLIENT and net_connected:
			_send_input()


func _net_msg(d: Dictionary) -> void:
	match str(d.get("t", "")):
		"welcome":
			my_id = int(d.id)
			net_connected = true
			_net_set_host(int(d.host))
		"join":
			if net_mode == NET_HOST:
				var pid := int(d.id)
				for slot in ASSIGN_ORDER:
					if not assignments.values().has(slot):
						assignments[pid] = slot
						break
				_setup_controllers()
		"leave":
			var pid := int(d.id)
			remote_inputs.erase(pid)
			if assignments.has(pid):
				assignments.erase(pid)
				if net_mode == NET_HOST:
					_setup_controllers()
			var h := int(d.get("host", host_id))
			if h != host_id:
				_net_set_host(h)
		"in":
			if net_mode == NET_HOST:
				remote_inputs[int(d.id)] = d
		"snap":
			if net_mode == NET_CLIENT:
				_apply_snap(d)


func _net_set_host(h: int) -> void:
	host_id = h
	if h == my_id and net_mode != NET_HOST:
		net_mode = NET_HOST
		assignments = {my_id: ASSIGN_ORDER[0]}
		client_ring_idx = ASSIGN_ORDER[0]
		_setup_controllers()
		_start_net_match()


## Host: sync player nodes with the current peer->slot table.
func _setup_controllers() -> void:
	for p in players:
		p.controller = -1
		p.is_human = false
	for pid in assignments:
		var p = players[assignments[pid]]
		p.controller = pid
		p.is_human = true
	human_team = -1  # chaser-yield logic checks all humans in multiplayer
	for p in players:
		p.queue_redraw()


func _start_net_match() -> void:
	team_select = false
	match_over = false
	streaker_done = true  # keep multiplayer snapshots simple
	red_score = 0
	blue_score = 0
	half = 1
	time_left = HALF_LENGTH
	_apply_sides()
	_update_score()
	message_label.visible = false
	kickoff()
	playing = true


var _dbg_sends := 0


func _send_input() -> void:
	var v := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var err := ws.send_text(JSON.stringify({"t": "probe"}))
	_dbg_sends += 1
	if _dbg_sends % 40 == 1:
		print("dbg send_text err=", err, " state=", ws.get_ready_state(), " sends=", _dbg_sends)
	ws.send_text(JSON.stringify({
		"t": "in",
		"x": snappedf(v.x, 0.01), "y": snappedf(v.y, 0.01),
		"spr": Input.is_action_pressed("sprint"),
		"k": Input.is_action_pressed("kick"),
		"pc": in_pc, "sc": in_sc,
	}))


func _send_snap() -> void:
	var ps := []
	var cs := []
	for p in players:
		ps.append([snappedf(p.position.x, 0.1), snappedf(p.position.y, 0.1)])
		cs.append(snappedf(minf(p.charge_t / 0.9, 1.0), 0.01) if p.charging else 0.0)
	ws.send_text(JSON.stringify({
		"t": "snap",
		"p": ps, "c": cs,
		"b": [snappedf(ball.position.x, 0.1), snappedf(ball.position.y, 0.1), snappedf(ball.z, 0.1)],
		"s": [red_score, blue_score],
		"tl": snappedf(time_left, 0.1), "h": half,
		"m": message_label.text if message_label.visible else "",
		"map": assignments,
	}))


func _apply_snap(d: Dictionary) -> void:
	for i in players.size():
		players[i].position = Vector2(float(d.p[i][0]), float(d.p[i][1]))
		players[i].set_net_charge(float(d.c[i]))
	ball.position = Vector2(float(d.b[0]), float(d.b[1]))
	ball.z = float(d.b[2])
	ball.queue_redraw()
	red_score = int(d.s[0])
	blue_score = int(d.s[1])
	_update_score()
	time_left = float(d.tl)
	half = int(d.h)
	var m := str(d.get("m", ""))
	if m != "":
		_show_message(m, 44)
	else:
		message_label.visible = false

	var ring := -1
	for k in d.map:
		if int(k) == my_id:
			ring = int(d.map[k])
	if ring != client_ring_idx:
		client_ring_idx = ring
		for p in players:
			p.queue_redraw()
		if ring == -1:
			_show_message("MATCH FULL — SPECTATING", 30)
