@tool
extends Node3D
## Move/rotate this whole station to keep its visual and authored action together.

## Official interaction type. Keep each ID unique among the four stations.
@export_enum("Small jump:2", "High vault:5", "Sit / stand:10", "Avoidance:12") var station_id: int = 2
## Disables this interaction and its shortcut; the visual geometry stays editable.
@export var interaction_enabled: bool = true


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_parent() != null:
		for sibling: Node in get_parent().get_children():
			if sibling != self and sibling.get_script() == get_script() and sibling.station_id == station_id:
				warnings.append("交互站点 ID 重复；当前每种官方交互只支持一个站点。")
				break
	if not scale.is_equal_approx(Vector3.ONE):
		warnings.append("交互目标使用米制刚体变换；请保持站点缩放为 (1, 1, 1)。")
	if absf(rotation.x) > 0.001 or absf(rotation.z) > 0.001:
		warnings.append("当前交互基于水平地面，请只绕 Y 轴旋转整个站点。")
	if absf(position.y) > 0.001:
		warnings.append("当前地面位于 Y=0，请保持站点根节点高度为 0；物体高度由子节点定义。")
	return warnings
