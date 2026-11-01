extends Node3D
## Official SOMA Gym, with an optional flat-ground mode for gait comparisons.

const Bridge = preload("res://scripts/motion_bridge.gd")
const GymWorld = preload("res://scripts/gym_world.gd")
const ACCENT := Color("b6f260")
const MUTED := Color("8c999a")
const WALK_SPEED := 2.3
const RUN_SPEED := 4.5
@export var draw_target_skeletons: bool = false
@export_group("Camera")
@export var follow_player: bool = true
@export var orient_camera_on_teleport: bool = true
@export_range(0.08, 1.1, 0.01) var camera_pitch: float = 0.28
@export_range(2.5, 10.0, 0.1) var camera_distance: float = 5.5
@export var camera_yaw: float = -PI / 2
@export_range(0, 2, 0.05) var shoulder_offset: float = 0.8
var bridge := Bridge.new()
var skeleton: Skeleton3D
var camera: Camera3D
var joint_map := PackedInt32Array()
var previous_pose := PackedFloat32Array()
var current_pose := PackedFloat32Array()
var interpolation_time: float = 0.0
var root_position := Vector3.ZERO
var camera_target := Vector3(0, 1, 0)
var backend_pid: int = -1
var status_label: Label
var fps_label: Label
var inference_label: Label
var response_label: Label
var motion_label: Label
var details_label: Label
var target_toggle: CheckButton
var target_label: Label
var target_debug_draw: Node3D
var _target_revision: int = -1
var _seconds: float = 0.0
var _hud_tick: float = 0.0
var _backend_attempted: bool = false
var _automated: bool = false
var _duration: float = 600.0
var _live_seconds: float = 0.0
var _capture_done: bool = false
var _frame_times: Array[float] = []
var _metrics_file: FileAccess
var _fatal_message: String = ""
var _preview: bool = false
var _connection_gaps: int = 0
var _was_live: bool = false
var _first_connection: bool = false
var _tap_axis := Vector2.ZERO
var _tap_sprint: bool = false
var _sprint_for_frame: bool = false
var _tap_remaining: float = 0.0
@export_group("Demo")
@export var flat_mode: bool = false
var gym_world: Node3D
var scene_hint: Label
var auto_toggle: CheckButton
var trigger_toggle: CheckButton
@export var overview: bool = false
var overview_camera: Camera3D
var _scene_revision: int = -1
var _teleport_serial: int = -1
var _test_station: int = 0
var _test_phase: int = 0
var _test_elapsed: float = 0.0
var _test_saw_action: bool = false
var _test_hold: float = 0.0
var _test_stand: bool = false
var _test_completed_base: int = 0
var _test_finish_time: float = -1.0
var _test_best_capture: float = -INF


func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--flat":
			flat_mode = true
		if argument == "--overview":
			overview = true
		if argument.begins_with("--interaction-test="):
			_test_station = int(argument.trim_prefix("--interaction-test="))
		if argument == "--debug-targets":
			draw_target_skeletons = true
		if argument == "--preview":
			_preview = true
		if argument.begins_with("--soak="):
			_automated = true
			flat_mode = true
			_duration = float(argument.trim_prefix("--soak="))
	_bind_world()
	_bind_hud()
	_load_character()
	_set_debug_targets(draw_target_skeletons)
	var socket_error := bridge.open()
	if socket_error != OK:
		_fatal_message = "无法建立本地连接：%s" % error_string(socket_error)
	if _test_station > 0:
		bridge.select_station(_test_station)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://logs"))
	_metrics_file = FileAccess.open("res://logs/session.csv", FileAccess.WRITE)
	if _metrics_file:
		_metrics_file.store_line("seconds,fps,inference_ms,generation_ms,command_to_pose_ms,generations,root_x,root_z,live")
	get_tree().auto_accept_quit = false
	_update_camera(1.0)


func _load_character() -> void:
	if not ResourceLoader.exists("res://assets/soma/soma.glb"):
		_fatal_message = "人物资源尚未生成，请先运行 tools/setup.ps1"
		return
	var character := $Player/Model
	if flat_mode:
		$Player.transform = Transform3D.IDENTITY
		character.transform = Transform3D.IDENTITY
	skeleton = _find_skeleton(character)
	if skeleton == null:
		_fatal_message = "官方人物未包含可用骨架"
		return
	var rig: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/soma/rig.json"))
	for joint: String in rig["joints"]:
		var index := skeleton.find_bone(joint)
		if index < 0:
			_fatal_message = "骨架缺少关节：" + joint
		joint_map.append(index)
	target_debug_draw = $Debug/TargetSkeletonDebug
	target_debug_draw.configure(rig["parents"])
	root_position = (skeleton.global_transform * skeleton.get_bone_global_pose(joint_map[0])).origin
	print("SOMA_BINDING joints=%d mapped=%d" % [joint_map.size(), skeleton.get_bone_count()])


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child: Node in node.get_children():
		var result := _find_skeleton(child)
		if result != null:
			return result
	return null


func _process(delta: float) -> void:
	_seconds += delta
	_hud_tick += delta
	if _fatal_message.is_empty():
		var direction := _read_direction()
		_tap_remaining = maxf(0.0, _tap_remaining - delta)
		if _tap_remaining <= 0:
			_tap_axis = Vector2.ZERO
			_tap_sprint = false
		var speed := 0.0
		if not direction.is_zero_approx():
			speed = RUN_SPEED if _sprint_for_frame else WALK_SPEED
		if _automated:
			var phase := fmod(_live_seconds, 20.0)
			var heading := floorf(_live_seconds / 20.0) * PI / 2.0
			if phase >= 14.0:
				heading += PI / 2.0
			direction = Vector3(sin(heading), 0, -cos(heading))
			speed = 0.0 if phase < 3.0 or phase >= 17.0 else (WALK_SPEED if phase < 10.0 else RUN_SPEED)
		if _test_station > 0:
			var control := _interaction_test_control(delta)
			direction = control[0]
			speed = control[1]
		if not _preview:
			bridge.send_control(direction, speed)
		motion_label.text = "待机 / IDLE" if speed == 0 else ("跑步 / RUN" if speed > WALK_SPEED else "行走 / WALK")
		if not _preview and bridge.poll(joint_map.size()):
			previous_pose = current_pose if not current_pose.is_empty() else bridge.latest_pose
			current_pose = bridge.latest_pose
			interpolation_time = 0
		if not flat_mode and _scene_revision != bridge.scene_revision:
			_scene_revision = bridge.scene_revision
			_apply_scene_status()
		if _target_revision != bridge.target_revision and target_debug_draw != null:
			_target_revision = bridge.target_revision
			target_debug_draw.show_targets(bridge.latest_targets, bridge.target_pose_count)
		interpolation_time += delta
		_apply_pose(clampf(interpolation_time / bridge.packet_interval, 0, 1))
		if not flat_mode and bridge.scene_status.get("interacting", false):
			var station_id := int(bridge.scene_status.get("active", 0))
			motion_label.text = "坐姿保持 / SITTING" if bridge.scene_status.get("seated", false) else str(GymWorld.TITLES.get(station_id, "场景交互")) + " / ACTION"
			if bridge.scene_status.get("jumping", false):
				motion_label.text = "跳跃 / JUMP"
		if bridge.is_live():
			_first_connection = true
			_live_seconds += delta
			if _automated:
				_frame_times.append(delta)
		elif _seconds > 1.5 and not _backend_attempted and not _preview:
			_start_backend()
		if _was_live and not bridge.is_live() and _first_connection:
			_connection_gaps += 1
		_was_live = bridge.is_live()
	_update_camera(delta)
	if _hud_tick >= 0.25:
		_update_hud()
		_hud_tick = 0
	if _automated and _live_seconds > 7 and not _capture_done:
		_capture_done = true
		_capture.call_deferred()
	if _automated and _live_seconds >= _duration:
		_finish_soak()
	if _preview and _seconds > 3 and not _capture_done:
		_capture_done = true
		_capture.call_deferred()
	if _preview and _seconds > 4:
		_quit()
	if _test_station > 0:
		_update_interaction_test()
	# An unavailable backend must fail the test, not masquerade as a stationary pass.
	if _automated and _seconds > 900 and _live_seconds < 1:
		push_error("MotionBricks backend did not become ready")
		get_tree().quit(1)


func _apply_pose(weight: float) -> void:
	if skeleton == null or current_pose.is_empty():
		return
	for joint: int in range(joint_map.size()):
		var bone := joint_map[joint]
		if bone < 0:
			continue
		var offset := joint * 7
		var a := Vector3(previous_pose[offset], previous_pose[offset + 1], previous_pose[offset + 2])
		var b := Vector3(current_pose[offset], current_pose[offset + 1], current_pose[offset + 2])
		var qa := Quaternion(previous_pose[offset + 3], previous_pose[offset + 4], previous_pose[offset + 5], previous_pose[offset + 6]).normalized()
		var qb := Quaternion(current_pose[offset + 3], current_pose[offset + 4], current_pose[offset + 5], current_pose[offset + 6]).normalized()
		var position := a.lerp(b, weight)
		var rotation := qa.slerp(qb, weight)
		if joint == 0:
			root_position = position
			# Model/Player are editable scene instances. Convert streamed world
			# roots into the skeleton's space instead of overwriting those nodes.
			var local := skeleton.global_transform.affine_inverse() * Transform3D(Basis(rotation), position)
			position = local.origin
			rotation = local.basis.get_rotation_quaternion()
		skeleton.set_bone_pose_position(bone, position)
		skeleton.set_bone_pose_rotation(bone, rotation)


func _read_direction() -> Vector3:
	if not DisplayServer.window_is_focused():
		_tap_axis = Vector2.ZERO
		_tap_sprint = false
		_tap_remaining = 0
		return Vector3.ZERO
	var axis := Vector2(
		float(_key_down(KEY_D)) - float(_key_down(KEY_A)),
		float(_key_down(KEY_S)) - float(_key_down(KEY_W)))
	# Keep very short taps long enough to survive the 60 Hz bridge's coalescing.
	if axis.is_zero_approx():
		axis = _tap_axis
	_sprint_for_frame = _key_down(KEY_SHIFT) or _tap_sprint
	var active_camera := get_viewport().get_camera_3d()
	var forward := -active_camera.global_basis.z
	forward.y = 0
	forward = forward.normalized()
	var right := active_camera.global_basis.x
	right.y = 0
	right = right.normalized()
	return (right * axis.x - forward * axis.y).normalized()


func _key_down(key: Key) -> bool:
	return Input.is_physical_key_pressed(key) or Input.is_key_pressed(key)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		camera_yaw -= event.relative.x * 0.005
		camera_pitch = clampf(camera_pitch + event.relative.y * 0.004, 0.08, 1.1)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = maxf(2.5, camera_distance - 0.4)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = minf(10.0, camera_distance + 0.4)
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = event.physical_keycode
		if key not in [KEY_W, KEY_A, KEY_S, KEY_D]:
			key = event.keycode
		match key:
			KEY_W: _tap_axis.y -= 1
			KEY_S: _tap_axis.y += 1
			KEY_A: _tap_axis.x -= 1
			KEY_D: _tap_axis.x += 1
		if key in [KEY_W, KEY_A, KEY_S, KEY_D]:
			_tap_remaining = 0.06
		_tap_sprint = _tap_sprint or event.shift_pressed or _key_down(KEY_SHIFT)
		if event.physical_keycode == KEY_R or event.keycode == KEY_R:
			bridge.reset_character()
		elif event.physical_keycode == KEY_F2 or event.keycode == KEY_F2:
			_set_debug_targets(not draw_target_skeletons)
		elif not flat_mode:
			match key:
				KEY_SPACE: bridge.jump()
				KEY_E, KEY_I: bridge.interact()
				KEY_M: overview = not overview
				KEY_F3: _set_trigger_debug(not bridge.debug_scene)
				KEY_1: _go_to_station(2)
				KEY_2: _go_to_station(5)
				KEY_3: _go_to_station(10)
				KEY_4: _go_to_station(12)
		if event.physical_keycode == KEY_ESCAPE or event.keycode == KEY_ESCAPE:
			_quit()


func _update_camera(delta: float) -> void:
	if gym_world != null:
		gym_world.show_station_labels(overview)
	overview_camera.current = overview and not flat_mode
	camera.current = not overview_camera.current
	if overview and not flat_mode:
		return
	if not follow_player:
		return
	var target := Vector3(root_position.x, 0.95, root_position.z)
	camera_target = camera_target.lerp(target, 1.0 - exp(-8.0 * delta))
	var offset := Vector3(sin(camera_yaw) * cos(camera_pitch), sin(camera_pitch), cos(camera_yaw) * cos(camera_pitch))
	# Shift position and aim together so the obstacle stays visible and W keeps
	# the authored approach direction. Flat gait comparisons retain their view.
	var shoulder := Vector3.ZERO if flat_mode else Vector3(cos(camera_yaw), 0, -sin(camera_yaw)) * shoulder_offset
	camera.global_position = camera_target + offset * camera_distance + shoulder
	camera.look_at(camera_target + shoulder)


func _go_to_station(station_id: int) -> void:
	bridge.select_station(station_id)
	overview = false


func _set_trigger_debug(enabled: bool) -> void:
	bridge.debug_scene = enabled
	if trigger_toggle != null:
		trigger_toggle.set_pressed_no_signal(enabled)
	if gym_world != null:
		gym_world.trigger_visible = enabled
		gym_world.update_status(bridge.scene_status)


func _apply_scene_status() -> void:
	if gym_world == null or bridge.scene_status.is_empty():
		return
	var snapshot := bridge.scene_status
	gym_world.update_status(snapshot)
	var serial := int(snapshot.get("teleport", -1))
	if serial != _teleport_serial and not current_pose.is_empty():
		_teleport_serial = serial
		previous_pose = current_pose
		_apply_pose(1.0)
		camera_target = Vector3(root_position.x, 0.95, root_position.z)
		var facing := GymWorld.vector(snapshot["facing"])
		if orient_camera_on_teleport:
			camera_yaw = atan2(-facing.x, -facing.z)
			if _test_station > 0:
				camera_yaw += PI / 2
	if snapshot.get("jumping", false):
		scene_hint.text = "跳跃中\n落地后恢复移动"
	elif snapshot.get("seated", false):
		scene_hint.text = "坐姿保持\n按 E / I 起身"
	elif snapshot.get("interacting", false):
		scene_hint.text = str(GymWorld.TITLES.get(int(snapshot.get("active", 0)), "场景交互")) + "\n正在按官方目标序列生成动作"
	elif int(snapshot.get("near", 0)) != 0:
		scene_hint.text = "可交互：" + str(GymWorld.TITLES.get(int(snapshot["near"]), "")) + "\nE / I 手动触发"
	else:
		scene_hint.text = "1–4 前往挑战入口，W 接近物体\nE / I 交互 · M 场景总览"


func _set_debug_targets(enabled: bool) -> void:
	draw_target_skeletons = enabled
	bridge.debug_targets_enabled = enabled
	bridge.clear_targets()
	if target_toggle != null:
		target_toggle.set_pressed_no_signal(enabled)
	if target_debug_draw != null:
		target_debug_draw.visible = enabled
		target_debug_draw.clear()


func _start_backend() -> void:
	_backend_attempted = true
	var python := ProjectSettings.globalize_path("res://.runtime/motionbricks/.venv/Scripts/python.exe")
	if not FileAccess.file_exists(python):
		_fatal_message = "推理环境尚未安装，请先运行 tools/setup.ps1"
		return
	var arguments := PackedStringArray(["-u", ProjectSettings.globalize_path("res://bridge/server.py")])
	if flat_mode:
		arguments.append("--flat")
	backend_pid = OS.create_process(python, arguments, false)
	if backend_pid < 0:
		_fatal_message = "无法启动本地动作服务，详见 logs/bridge.log"


func _update_hud() -> void:
	var fps := Engine.get_frames_per_second()
	fps_label.text = "%d" % fps
	inference_label.text = "%.1f ms" % bridge.inference_ms
	response_label.text = "%.0f ms" % bridge.response_ms
	if draw_target_skeletons:
		target_label.text = "%d 帧 · 生成 #%d\n1 青 · 2 紫 · 3 橙 · 4 粉" % [bridge.target_pose_count, bridge.target_generation] if bridge.target_pose_count > 0 else "等待首次生成目标"
	else:
		target_label.text = "目标骨架已隐藏"
	if not _fatal_message.is_empty():
		status_label.text = "●  " + _fatal_message
		status_label.modulate = Color("ffba80")
	elif bridge.is_live():
		status_label.text = "●  LIVE · 本地生成"
		status_label.modulate = ACCENT
	else:
		status_label.text = "●  模型预热中 · 首次编译需要数分钟"
		status_label.modulate = Color("ffcf88")
		var path := "res://logs/bridge_status.json"
		if FileAccess.file_exists(path):
			var state: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if state is Dictionary and state.get("state") == "error":
				status_label.text = "●  推理失败 · 详见 logs/bridge.log"
				details_label.text = str(state.get("message", "" )).left(150)
	details_label.text = "%s\n生成 %d 次    已运行 %02d:%02d\n完整生成 %.1f ms · 骨架 %d 关节" % [
		"自动验证" if _automated else "实时姿态 → 神经生成 → 根位移", bridge.generation_count,
		int(_live_seconds) / 60, int(_live_seconds) % 60, bridge.generation_ms, joint_map.size()]
	if _metrics_file:
		_metrics_file.store_csv_line(PackedStringArray([str(_seconds), str(fps), str(bridge.inference_ms),
			str(bridge.generation_ms), str(bridge.response_ms), str(bridge.generation_count),
			str(root_position.x), str(root_position.z), str(bridge.is_live())]))
		_metrics_file.flush()


func _capture(path: String = "res://logs/demo.png") -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(path))


func _interaction_test_control(delta: float) -> Array:
	var snapshot := bridge.scene_status
	if not bridge.is_live() or int(snapshot.get("selected", 0)) != _test_station:
		return [Vector3.ZERO, 0.0]
	_test_elapsed += delta
	if _test_phase == 0:
		_test_completed_base = int(snapshot.get("completed", 0))
		_test_phase = 1
	var direction := Vector3.FORWARD
	for entry: Dictionary in snapshot.get("entries", []):
		if int(entry["id"]) == _test_station:
			direction = GymWorld.vector(entry["facing"])
	if snapshot.get("interacting", false):
		_test_saw_action = true
		if snapshot.get("seated", false):
			_test_hold += delta
			if _test_hold >= 1.0 and not _test_stand:
				bridge.interact()
				_test_stand = true
		return [direction, 0.0]
	if _test_saw_action:
		return [direction, 0.0]
	return [direction, WALK_SPEED]


func _update_interaction_test() -> void:
	var snapshot := bridge.scene_status
	if snapshot.get("interacting", false) and skeleton != null:
		var score := root_position.y
		if _test_station == 10:
			score = -root_position.y if snapshot.get("seated", false) else -10.0
		elif _test_station == 12:
			score = -skeleton.get_bone_global_pose(skeleton.find_bone("Head")).origin.y
		if score > _test_best_capture + 0.03:
			_test_best_capture = score
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://logs/gym"))
			_capture.call_deferred("res://logs/gym/live-%d.png" % _test_station)
	if _test_saw_action and int(snapshot.get("completed", 0)) > _test_completed_base:
		if _test_finish_time < 0:
			_test_finish_time = _test_elapsed
		if _test_elapsed - _test_finish_time > 0.6:
			_finish_interaction_test(true)
	if _test_elapsed > 35 or (_seconds > 120 and _test_phase == 0):
		_finish_interaction_test(false)


func _finish_interaction_test(completed: bool) -> void:
	var passed := completed and _test_saw_action and (_test_station != 10 or _test_stand)
	var report := {"station": _test_station, "passed": passed, "seconds": _test_elapsed,
		"layout_revision": bridge.scene_status.get("layout_revision", ""),
		"saw_interaction": _test_saw_action, "stand_requested": _test_stand,
		"received_poses": bridge.received_frames, "generations": bridge.generation_count,
		"final_root": [root_position.x, root_position.y, root_position.z]}
	var path := "res://logs/gym/ui-%d.json" % _test_station
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://logs/gym"))
	var output := FileAccess.open(path, FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	print("GYM_UI_RESULT ", JSON.stringify(report))
	bridge.close(backend_pid > 0)
	get_tree().quit(0 if passed else 1)


func _finish_soak() -> void:
	_frame_times.sort()
	var responses := bridge.response_samples.duplicate()
	responses.sort()
	var report := {"live_seconds": _live_seconds, "wall_seconds": _seconds,
		"debug_targets_enabled": draw_target_skeletons, "debug_target_frames": bridge.target_pose_count,
		"debug_target_packets": bridge.received_target_packets,
		"debug_draw_bones": target_debug_draw.bone_count if target_debug_draw != null else 0,
		"connection_gaps_over_500ms": _connection_gaps,
		"rendered_frames": _frame_times.size(), "received_poses": bridge.received_frames,
		"generation_count": bridge.generation_count, "root": [root_position.x, root_position.y, root_position.z],
		"average_fps": _frame_times.size() / _live_seconds,
		"p95_frame_ms": _frame_times[int(_frame_times.size() * 0.95)] * 1000 if not _frame_times.is_empty() else 0,
		"command_samples": responses.size(),
		"p95_command_to_pose_ms": responses[int(responses.size() * 0.95)] if not responses.is_empty() else 0}
	var output := FileAccess.open("res://logs/soak.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	print("SOAK_RESULT ", JSON.stringify(report))
	_quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit()


func _quit() -> void:
	bridge.close(backend_pid > 0)
	get_tree().quit()


func _exit_tree() -> void:
	if _metrics_file:
		_metrics_file.close()
	if backend_pid > 0 and OS.is_process_running(backend_pid):
		OS.kill(backend_pid)


func _bind_world() -> void:
	camera = $CameraRig/FollowCamera
	overview_camera = $CameraRig/OverviewCamera
	gym_world = $Gym
	gym_world.visible = not flat_mode
	if not flat_mode:
		var layout: Dictionary = gym_world.scene_layout($Player.global_transform)
		if layout.has("error"):
			_fatal_message = layout["error"]
		else:
			bridge.set_scene_layout(layout)
		root_position = $Player.global_position + Vector3.UP
		camera_target = $Player.global_position + Vector3.UP * 0.95


func _bind_hud() -> void:
	var hud := $HUD
	status_label = hud.status_label
	fps_label = hud.fps_label
	inference_label = hud.inference_label
	response_label = hud.response_label
	motion_label = hud.motion_label
	details_label = hud.details_label
	target_toggle = hud.target_toggle
	target_label = hud.target_label
	scene_hint = hud.scene_hint
	auto_toggle = hud.auto_toggle
	trigger_toggle = hud.trigger_toggle
	hud.station_requested.connect(_go_to_station)
	target_toggle.toggled.connect(_set_debug_targets)
	auto_toggle.toggled.connect(func(value: bool) -> void: bridge.auto_interact = value)
	trigger_toggle.toggled.connect(_set_trigger_debug)
	bridge.auto_interact = auto_toggle.button_pressed
	_set_trigger_debug(trigger_toggle.button_pressed)
	hud.configure(flat_mode, gym_world.enabled_stations())
