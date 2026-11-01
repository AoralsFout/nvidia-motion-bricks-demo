extends Node3D
## Four actual conditioning poses. Coordinates are source-local, root in Y-up world.

const COLORS := [Color("59dcff"), Color("b999ff"), Color("ffbe72"), Color("ff83b7")]
@export var target_colors: Array[Color] = [Color("59dcff"), Color("b999ff"), Color("ffbe72"), Color("ff83b7")]
var bone_count: int = 0
var pose_count: int = 0
var _parents := PackedInt32Array()
var _bones: MultiMeshInstance3D
var _joints: MultiMeshInstance3D


func configure(parents: Array) -> void:
	_parents = PackedInt32Array(parents)
	_bones = $Bones
	_joints = $Joints
	_bones.multimesh = _bones.multimesh.duplicate()
	_joints.multimesh = _joints.multimesh.duplicate()


func show_targets(poses: PackedFloat32Array, count: int) -> void:
	pose_count = count
	bone_count = 0
	var joint_count := _parents.size()
	if poses.size() != count * joint_count * 7:
		clear()
		return
	var segments: Array[Transform3D] = []
	var colors: Array[Color] = []
	_joints.multimesh.instance_count = count * joint_count
	for frame: int in range(count):
		var pose_color: Color = target_colors[frame] if frame < target_colors.size() else COLORS[frame]
		var world: Array[Transform3D] = []
		world.resize(joint_count)
		for joint: int in range(joint_count):
			var offset := (frame * joint_count + joint) * 7
			var position := Vector3(poses[offset], poses[offset + 1], poses[offset + 2])
			var rotation := Quaternion(poses[offset + 3], poses[offset + 4], poses[offset + 5], poses[offset + 6]).normalized()
			var local := Transform3D(Basis(rotation), position)
			var parent := _parents[joint]
			world[joint] = world[parent] * local if parent >= 0 else local
			var endpoint := world[joint].origin
			var instance_index := frame * joint_count + joint
			_joints.multimesh.set_instance_transform(instance_index, Transform3D(Basis.IDENTITY, endpoint))
			_joints.multimesh.set_instance_color(instance_index, pose_color)
			if parent < 0:
				continue
			var start := world[parent].origin
			var distance := start.distance_to(endpoint)
			if distance < 0.003:
				continue
			var y := (endpoint - start) / distance
			var helper := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.98 else Vector3.UP
			var x := helper.cross(y).normalized()
			var z := x.cross(y).normalized()
			segments.append(Transform3D(Basis(x, y * distance, z), (start + endpoint) * 0.5))
			colors.append(pose_color)
	bone_count = segments.size()
	_bones.multimesh.instance_count = bone_count
	for index: int in range(bone_count):
		_bones.multimesh.set_instance_transform(index, segments[index])
		_bones.multimesh.set_instance_color(index, colors[index])


func clear() -> void:
	bone_count = 0
	pose_count = 0
	if _bones != null:
		_bones.multimesh.instance_count = 0
		_joints.multimesh.instance_count = 0
