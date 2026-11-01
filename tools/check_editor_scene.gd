extends SceneTree
## Verify saved scene edits, static ownership and world-to-skeleton pose binding.

func _initialize() -> void:
	call_deferred("_check")


func _count(node: Node) -> int:
	var result := 1
	for child: Node in node.get_children():
		result += _count(child)
	return result


func _write_json(path: String, value: Variant) -> void:
	var output := FileAccess.open(path, FileAccess.WRITE)
	output.store_string(JSON.stringify(value, "\t"))


func _check() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://logs/editor-scene"))
	var packed := load("res://scenes/main.tscn") as PackedScene
	var actor = packed.instantiate()
	var static_count := _count(actor)
	for path: String in ["World/Environment", "World/Sun", "World/GridFloor", "Gym/SmallJump/Geometry", "Gym/HighVault/Geometry", "Gym/SitStand/Geometry", "Gym/Avoidance/Geometry", "Player/Model", "CameraRig/FollowCamera", "CameraRig/OverviewCamera", "HUD/Layout/Heading/Title", "Debug/TargetSkeletonDebug/Bones"]:
		assert(actor.has_node(path), "Missing editable scene node: "+path)
	actor._preview = true
	root.add_child(actor)
	actor.set_process(false)
	assert(_count(actor) == static_count, "Ready must bind existing nodes instead of rebuilding the scene")
	assert(actor.skeleton.get_bone_count() == 77)
	assert(actor._fatal_message.is_empty(), actor._fatal_message)
	_write_json("res://logs/editor-scene/default-layout.json", actor.bridge.scene_layout)
	actor.bridge.close(false)
	actor.free()
	# Edit an instance as the editor does, then save and reload its property overrides.
	var edited = packed.instantiate()
	var station := edited.get_node("Gym/SmallJump") as Node3D
	station.position += Vector3(5, 0, -3)
	station.rotation.y += 0.45
	edited.get_node("Gym/Avoidance").interaction_enabled = false
	edited.get_node("Player").position = Vector3(-14, 0, -8)
	edited.get_node("Player").rotation.y = 0.35
	edited.get_node("HUD/Layout/Heading/Title").text = "Editable scene check"
	var changed := PackedScene.new()
	assert(changed.pack(edited) == OK)
	assert(ResourceSaver.save(changed, "res://logs/editor-scene/edited.tscn") == OK)
	edited.free()
	var restored = load("res://logs/editor-scene/edited.tscn").instantiate()
	assert(restored.get_node("Gym/SmallJump").position.is_equal_approx(Vector3(9, 0, -3)))
	assert(restored.get_node("Player").position.is_equal_approx(Vector3(-14, 0, -8)))
	assert(restored.get_node("HUD/Layout/Heading/Title").text == "Editable scene check")
	restored._preview = true
	root.add_child(restored)
	restored.set_process(false)
	assert(restored._fatal_message.is_empty(), restored._fatal_message)
	assert(restored.get_node("HUD/Layout/StationPanel/StationButtons/Avoidance").disabled)
	_write_json("res://logs/editor-scene/edited-layout.json", restored.bridge.scene_layout)
	# The visible model may have a translated/rotated scene parent. Incoming roots
	# must still land at their exact world coordinates, with no doubled spawn offset.
	var rig: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/soma/rig.json"))
	var pose := PackedFloat32Array()
	for joint: Array in rig["rest"]:
		pose.append_array(PackedFloat32Array(joint))
	pose[0] = -11.0
	pose[1] = 1.012
	pose[2] = -5.0
	restored.current_pose = pose
	restored.previous_pose = pose
	restored._apply_pose(1.0)
	var actual: Transform3D = restored.skeleton.global_transform * restored.skeleton.get_bone_global_pose(restored.joint_map[0])
	var expected := Transform3D(Basis(Quaternion(pose[3], pose[4], pose[5], pose[6])), Vector3(-11, 1.012, -5))
	assert(actual.is_equal_approx(expected), "Model parent transform was applied twice")
	assert(restored.root_position.is_equal_approx(expected.origin))
	_write_json("res://logs/editor-scene/graph-check.json", {"passed": true, "scene_nodes": static_count,
		"saved_edits_survived": true, "world_pose_binding": true, "disabled_station": true})
	restored.bridge.close(false)
	restored.free()
	print("EDITOR_SCENE_GRAPH_PASS nodes=", static_count)
	quit()
