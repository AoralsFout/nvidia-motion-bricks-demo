extends Node3D
## Static station nodes are edited in gym.tscn; only model debug data is dynamic.

const TITLES := {2: "低箱跨越", 5: "高墙跨越", 10: "坐下 / 站起", 12: "低杆躲避"}
@export var inactive_color := Color(0.95, 0.25, 0.65, 0.8)
@export var nearby_color := Color(0.6, 1.0, 0.3, 0.95)
@export var active_color := Color(1.0, 0.7, 0.2, 0.95)
var trigger_visible: bool = true
var _wire: ImmediateMesh
var _last_entries: String = ""
@onready var _wire_instance: MeshInstance3D = $TriggerRegions
@onready var _arrows: MeshInstance3D = $EntryArrows


func _ready() -> void:
	_wire = _wire_instance.mesh.duplicate()
	_wire_instance.mesh = _wire
	_arrows.mesh = _arrows.mesh.duplicate()


func show_station_labels(enabled: bool) -> void:
	for child: Node in get_children():
		if child.has_node("Label"):
			child.get_node("Label").visible = enabled


func enabled_stations() -> Dictionary:
	var result := {}
	for child: Node in get_children():
		if child.get_script() == preload("res://scripts/interaction_station.gd"):
			result[child.station_id] = child.interaction_enabled
	return result


static func _placement(transform: Transform3D) -> Dictionary:
	var q := transform.basis.orthonormalized().get_rotation_quaternion()
	return {"position": [transform.origin.x, transform.origin.y, transform.origin.z],
		"rotation": [q.x, q.y, q.z, q.w]}


static func _placement_error(transform: Transform3D) -> bool:
	return not transform.basis.get_scale().is_equal_approx(Vector3.ONE) or absf(transform.origin.y) > 0.01 or transform.basis.y.dot(Vector3.UP) < 0.999


func scene_layout(start: Transform3D) -> Dictionary:
	if _placement_error(start):
		return {"error": "Player 起点请保持单位缩放、Y=0，并只绕 Y 轴旋转"}
	var result := {"start": _placement(start), "stations": []}
	var seen := {}
	for child: Node in get_children():
		if child.get_script() != preload("res://scripts/interaction_station.gd"):
			continue
		var id: int = child.station_id
		if seen.has(id) or not TITLES.has(id):
			return {"error": "场景中交互站点 ID 无效或重复：%d" % id}
		seen[id] = true
		if _placement_error(child.global_transform):
			return {"error": "%s 请保持单位缩放、Y=0，并只绕 Y 轴旋转" % child.name}
		var station := _placement(child.global_transform)
		station["id"] = id
		station["enabled"] = child.interaction_enabled
		result["stations"].append(station)
	result["revision"] = JSON.stringify(result).sha256_text()
	return result


static func vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])


static func transform_from(item: Dictionary) -> Transform3D:
	var q: Array = item["rotation"]
	return Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized()), vector(item["position"]))


func update_status(status: Dictionary) -> void:
	_wire_instance.visible = trigger_visible
	if status.has("entries"):
		var signature := JSON.stringify(status["entries"])
		if signature != _last_entries:
			_last_entries = signature
			_make_entries(status["entries"])
	if not trigger_visible or not status.has("boxes"):
		return

	_wire.clear_surfaces()
	if status["boxes"].is_empty():
		return
	_wire.surface_begin(Mesh.PRIMITIVE_LINES)
	for item: Dictionary in status["boxes"]:
		var half_size := vector(item["size"]) * 0.5
		var placement := transform_from(item)
		var vertices: Array[Vector3] = []
		for x: int in [-1, 1]:
			for y: int in [-1, 1]:
				for z: int in [-1, 1]:
					vertices.append(placement * (half_size * Vector3(x, y, z)))
		var color := inactive_color
		if int(status.get("active", 0)) == int(item["id"]):
			color = active_color
		elif int(status.get("near", 0)) == int(item["id"]):
			color = nearby_color
		for index: int in range(8):
			for bit: int in [1, 2, 4]:
				var neighbor := index ^ bit
				if index < neighbor:
					_wire.surface_set_color(color)
					_wire.surface_add_vertex(vertices[index])
					_wire.surface_set_color(color)
					_wire.surface_add_vertex(vertices[neighbor])
	_wire.surface_end()


func _make_entries(entries: Array) -> void:
	var mesh := _arrows.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if entries.is_empty():
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for item: Dictionary in entries:
		var start := vector(item["position"])
		start.y = 0.025
		var forward := vector(item["facing"]).normalized()
		var right := forward.cross(Vector3.UP).normalized()
		var tip := start + forward * 1.1
		for segment: Vector3 in [start, tip, tip, tip - forward * 0.25 + right * 0.2,
				tip, tip - forward * 0.25 - right * 0.2]:
			mesh.surface_add_vertex(segment)
	mesh.surface_end()
