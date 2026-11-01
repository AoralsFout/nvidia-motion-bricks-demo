extends Node3D
## Official SOMA Gym, with an optional flat-ground mode for gait comparisons.

const Bridge = preload("res://scripts/motion_bridge.gd")
const TargetSkeletonDebug = preload("res://scripts/target_skeleton_debug.gd")
const GymWorld = preload("res://scripts/gym_world.gd")
const ACCENT := Color("b6f260")
const MUTED := Color("8c999a")
const WALK_SPEED := 2.3
const RUN_SPEED := 4.5
@export var draw_target_skeletons: bool = false
var bridge := Bridge.new()
var skeleton: Skeleton3D
var camera: Camera3D
var joint_map := PackedInt32Array()
var previous_pose := PackedFloat32Array()
var current_pose := PackedFloat32Array()
var interpolation_time: float = 0.0
var root_position := Vector3.ZERO
var camera_target := Vector3(0, 1, 0)
var camera_yaw: float = 0.0
var camera_pitch: float = 0.28
var camera_distance: float = 5.5
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
var flat_mode: bool = false
var gym_world: Node3D
var gym_metadata: Dictionary = {}
var scene_hint: Label
var auto_toggle: CheckButton
var trigger_toggle: CheckButton
var overview: bool = false
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
	_make_world()
	_make_hud()
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
	var scene := load("res://assets/soma/soma.glb") as PackedScene
	var character := scene.instantiate()
	character.name = "OfficialSOMA"
	add_child(character)
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
	target_debug_draw = TargetSkeletonDebug.new()
	target_debug_draw.name = "TargetSkeletonDebug"
	add_child(target_debug_draw)
	target_debug_draw.configure(rig["parents"])
	if not flat_mode and not gym_metadata.is_empty():
		var start := GymWorld.vector(gym_metadata["start"]["position"])
		skeleton.set_bone_pose_position(joint_map[0], skeleton.get_bone_pose_position(joint_map[0]) + start)
		root_position = skeleton.get_bone_pose_position(joint_map[0])
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
		skeleton.set_bone_pose_position(bone, position)
		skeleton.set_bone_pose_rotation(bone, qa.slerp(qb, weight))
		if joint == 0:
			root_position = position


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
	var forward := -camera.global_basis.z
	forward.y = 0
	forward = forward.normalized()
	var right := camera.global_basis.x
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
	if overview and not flat_mode:
		camera.position = Vector3(-12, 17, 12)
		camera.look_at(Vector3(4, 0.5, -4))
		return
	var target := Vector3(root_position.x, 0.95, root_position.z)
	camera_target = camera_target.lerp(target, 1.0 - exp(-8.0 * delta))
	var offset := Vector3(sin(camera_yaw) * cos(camera_pitch), sin(camera_pitch), cos(camera_yaw) * cos(camera_pitch))
	# Shift position and aim together so the obstacle stays visible and W keeps
	# the authored approach direction. Flat gait comparisons retain their view.
	var shoulder := Vector3.ZERO if flat_mode else Vector3(cos(camera_yaw), 0, -sin(camera_yaw)) * 0.8
	camera.position = camera_target + offset * camera_distance + shoulder
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


func _make_world() -> void:
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("182225")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("b5ced6")
	settings.ambient_light_energy = 0.25
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = settings
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -30, 0)
	sun.light_color = Color("fff2db")
	sun.light_energy = 0.5
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, 145, 0)
	fill.light_color = Color("b3d6df")
	fill.light_energy = 0.15
	add_child(fill)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	floor_mesh.mesh = plane
	floor_mesh.position.y = -0.005
	var material := ShaderMaterial.new()
	material.shader = preload("res://shaders/grid_floor.gdshader")
	floor_mesh.material_override = material
	add_child(floor_mesh)
	camera = Camera3D.new()
	camera.fov = 43
	camera.far = 250
	add_child(camera)
	camera.current = true
	if not flat_mode:
		if not FileAccess.file_exists("res://assets/gym/gym.json"):
			_fatal_message = "官方场景尚未准备，请先运行 tools/setup.ps1"
			return
		gym_metadata = JSON.parse_string(FileAccess.get_file_as_string("res://assets/gym/gym.json"))
		gym_world = GymWorld.new()
		gym_world.name = "OfficialSOMAGym"
		add_child(gym_world)
		gym_world.configure(gym_metadata)
		var start := GymWorld.vector(gym_metadata["start"]["position"])
		root_position = start + Vector3.UP
		camera_target = start + Vector3.UP * 0.95
		camera_yaw = -PI / 2


func _label(text: String, size: int, color := Color.WHITE) -> Label:
	var result := Label.new()
	result.text = text
	result.add_theme_font_size_override("font_size", size)
	result.add_theme_color_override("font_color", color)
	return result


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.045, 0.05, 0.88)
	style.border_color = Color("344348")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return panel


func _make_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var heading := VBoxContainer.new()
	heading.position = Vector2(34, 26)
	heading.add_theme_constant_override("separation", 5)
	root.add_child(heading)
	heading.add_child(_label("NVIDIA RESEARCH  /  GODOT STUDY 01", 12, ACCENT))
	heading.add_child(_label("MotionBricks", 38))
	heading.add_child(_label("让目标成为动作", 16, MUTED))
	status_label = _label("●  正在连接本地模型", 14, ACCENT)
	heading.add_child(status_label)
	if not flat_mode:
		scene_hint = _label("正在加载官方 SOMA Gym", 16, ACCENT)
		scene_hint.position = Vector2(390, 44)
		scene_hint.custom_minimum_size = Vector2(570, 0)
		scene_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		root.add_child(scene_hint)
		var station_panel := _panel()
		station_panel.position = Vector2(32, 184)
		station_panel.custom_minimum_size = Vector2(248, 0)
		root.add_child(station_panel)
		var stations := VBoxContainer.new()
		stations.add_theme_constant_override("separation", 10)
		station_panel.add_child(stations)
		stations.add_child(_label("SOMA GYM / 官方场景", 14, ACCENT))
		stations.add_child(_label("前往入口，再按 W 接近", 12, MUTED))
		for item: Dictionary in gym_metadata.get("stations", []):
			var button := Button.new()
			button.text = "%d  %s" % [int(item["number"]), item["name"]]
			button.custom_minimum_size.y = 35
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(_go_to_station.bind(int(item["id"])))
			stations.add_child(button)
	var telemetry := _panel()
	telemetry.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	telemetry.position = Vector2(-282, 30)
	telemetry.custom_minimum_size = Vector2(250, 0)
	root.add_child(telemetry)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	telemetry.add_child(column)
	column.add_child(_label("LOCAL INFERENCE", 12, ACCENT))
	var metrics := HBoxContainer.new()
	metrics.add_theme_constant_override("separation", 28)
	column.add_child(metrics)
	var fps_column := VBoxContainer.new()
	metrics.add_child(fps_column)
	fps_label = _label("—", 30)
	fps_column.add_child(fps_label)
	fps_column.add_child(_label("渲染 FPS", 12, MUTED))
	var infer_column := VBoxContainer.new()
	metrics.add_child(infer_column)
	inference_label = _label("—", 26)
	infer_column.add_child(inference_label)
	infer_column.add_child(_label("GPU 推理", 12, MUTED))
	response_label = _label("—", 18)
	column.add_child(_label("指令 → 首帧姿态", 12, MUTED))
	column.add_child(response_label)
	column.add_child(HSeparator.new())
	target_toggle = CheckButton.new()
	target_toggle.name = "TargetSkeletonToggle"
	target_toggle.text = "目标骨架  [F2]"
	target_toggle.tooltip_text = "显示实际送入 MotionBricks 的 1–4 帧目标姿态"
	target_toggle.focus_mode = Control.FOCUS_NONE
	target_toggle.toggled.connect(_set_debug_targets)
	column.add_child(target_toggle)
	target_label = _label("目标骨架已隐藏", 12, MUTED)
	column.add_child(target_label)
	if not flat_mode:
		auto_toggle = CheckButton.new()
		auto_toggle.text = "自动交互"
		auto_toggle.button_pressed = true
		auto_toggle.focus_mode = Control.FOCUS_NONE
		auto_toggle.toggled.connect(func(value: bool) -> void: bridge.auto_interact = value)
		column.add_child(auto_toggle)
		trigger_toggle = CheckButton.new()
		trigger_toggle.text = "触发区域  [F3]"
		trigger_toggle.button_pressed = true
		trigger_toggle.focus_mode = Control.FOCUS_NONE
		trigger_toggle.toggled.connect(_set_trigger_debug)
		column.add_child(trigger_toggle)
	var motion_panel := _panel()
	motion_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	motion_panel.position = Vector2(32, -207)
	motion_panel.custom_minimum_size = Vector2(330, 0)
	root.add_child(motion_panel)
	var state := VBoxContainer.new()
	state.add_theme_constant_override("separation", 9)
	motion_panel.add_child(state)
	motion_label = _label("待机 / IDLE", 21, ACCENT)
	state.add_child(motion_label)
	details_label = _label("实时姿态 → 神经生成 → 根位移", 13, MUTED)
	state.add_child(details_label)
	var controls_text := "W A S D  移动     SHIFT  跑步     右键拖动  环视     滚轮  缩放     R  重置     ESC  退出"
	if not flat_mode:
		controls_text += "\n空格  跳跃    1–4  挑战入口    E / I  交互 / 起身    F2  目标骨架    F3  触发区    M  总览"
	var controls := _label(controls_text, 13, Color("d0dad9"))
	controls.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	controls.position = Vector2(-600, -58)
	controls.custom_minimum_size.x = 1200
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(controls)
