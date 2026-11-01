extends SceneTree
## Render real captured poses from the side, without starting inference or controls.

func _initialize() -> void:
	_render.call_deferred()


func _render() -> void:
	var label := "baseline"
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--label="):
			label = argument.trim_prefix("--label=")
	var scene := load("res://scenes/main.tscn") as PackedScene
	var actor = scene.instantiate()
	actor._preview = true
	actor.flat_mode = true
	actor.set_process(false)
	root.add_child(actor)
	actor.set_process(false)
	for child: Node in actor.get_children():
		if child is CanvasLayer:
			child.visible = false
	var pose_file := FileAccess.open("res://logs/gait/%s.poses.bin" % label, FileAccess.READ)
	var values := pose_file.get_buffer(pose_file.get_length()).to_float32_array()
	var stride: int = actor.joint_map.size() * 7
	var sheet := Image.create(1152, 480, false, Image.FORMAT_RGB8)
	for index: int in range(6):
		var frame := 240 + index * 8
		actor.current_pose = values.slice(frame * stride, (frame + 1) * stride)
		actor.previous_pose = actor.current_pose
		actor._apply_pose(1.0)
		var position: Vector3 = actor.root_position
		actor.camera.position = Vector3(position.x + 4.0, 1.1, position.z)
		actor.camera.look_at(Vector3(position.x, 0.95, position.z))
		await RenderingServer.frame_post_draw
		var capture := root.get_texture().get_image()
		capture.convert(Image.FORMAT_RGB8)
		capture.resize(384, 240, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(capture, Rect2i(0, 0, 384, 240), Vector2i((index % 3) * 384, (index / 3) * 240))
	sheet.save_png(ProjectSettings.globalize_path("res://logs/gait/%s.png" % label))
	print("GAIT_PREVIEW ", label)
	actor.bridge.close(false)
	quit()
