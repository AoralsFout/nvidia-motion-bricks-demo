extends SceneTree
## Exercise the actual space-key handler, UDP event, model and rendered rig.

var actor: Node3D
var elapsed := 0.0
var started := false
var duplicate_sent := false
var finish_at := -1.0
var best_height := 0.0
var baseline_started := 0
var baseline_completed := 0
var initial_root := Vector3.ZERO
var capture_height := 0.0
var repeated_after_landing := false


func _initialize() -> void:
	call_deferred("_start")


func _start() -> void:
	actor = load("res://scenes/main.tscn").instantiate()
	root.add_child(actor)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://logs/jump"))
	actor.camera_yaw = 0.0 # Side view of the official +X start heading.
	while elapsed < 120.0:
		await process_frame
		var dt := float(root.get_process_delta_time())
		elapsed += dt
		var snapshot: Dictionary = actor.bridge.scene_status
		if not started and actor.bridge.is_live() and not snapshot.is_empty():
			baseline_started = int(snapshot.get("jump_started", 0))
			baseline_completed = int(snapshot.get("jump_completed", 0))
			initial_root = actor.root_position
			_space()
			started = true
		if not started:
			continue
		if snapshot.get("jumping", false):
			best_height = maxf(best_height, actor.root_position.y)
			if actor.root_position.y > capture_height + 0.04:
				capture_height = actor.root_position.y
				actor._capture.call_deferred("res://logs/jump/live.png")
			if not duplicate_sent:
				_space()
				duplicate_sent = true
		var expected := 2 if repeated_after_landing else 1
		if int(snapshot.get("jump_completed", 0)) >= baseline_completed + expected:
			if finish_at < 0:
				finish_at = elapsed
			if elapsed - finish_at >= 0.8:
				if not repeated_after_landing:
					repeated_after_landing = true
					finish_at = -1.0
					_space()
					continue
				var passed := int(snapshot.get("jump_started", 0)) == baseline_started + 2 and best_height > initial_root.y + 0.2 and absf(actor.root_position.y - initial_root.y) < 0.15
				_finish(passed)
				return
	_finish(false)


func _space() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_SPACE
	event.physical_keycode = KEY_SPACE
	event.pressed = true
	Input.parse_input_event(event)
	var release := event.duplicate() as InputEventKey
	release.pressed = false
	Input.parse_input_event(release)


func _finish(passed: bool) -> void:
	var report := {"passed": passed, "received_poses": actor.bridge.received_frames,
		"peak_root_height": best_height, "initial_root_height": initial_root.y,
		"final_root_height": actor.root_position.y, "duplicate_press_sent": duplicate_sent,
		"repeated_after_landing": repeated_after_landing,
		"jump_started": actor.bridge.scene_status.get("jump_started", 0),
		"jump_completed": actor.bridge.scene_status.get("jump_completed", 0)}
	var output := FileAccess.open("res://logs/jump/ui.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	print("JUMP_UI_RESULT ", JSON.stringify(report))
	actor.bridge.close(actor.backend_pid > 0)
	quit(0 if passed else 1)
