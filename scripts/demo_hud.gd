extends CanvasLayer
## Layout, text and styles live in hud.tscn; this script only exposes controls.

signal station_requested(station_id: int)

@onready var status_label: Label = %StatusLabel
@onready var fps_label: Label = %FPSValue
@onready var inference_label: Label = %InferenceValue
@onready var response_label: Label = %ResponseValue
@onready var motion_label: Label = %MotionLabel
@onready var details_label: Label = %DetailsLabel
@onready var target_toggle: CheckButton = %TargetSkeletonToggle
@onready var target_label: Label = %TargetLabel
@onready var scene_hint: Label = %SceneHint
@onready var auto_toggle: CheckButton = %AutoInteractionToggle
@onready var trigger_toggle: CheckButton = %TriggerRegionToggle


func _ready() -> void:
	for button: Button in get_tree().get_nodes_in_group("station_buttons"):
		if is_ancestor_of(button):
			button.pressed.connect(func() -> void: station_requested.emit(int(button.get_meta("station_id"))))


func configure(flat_mode: bool, station_enabled: Dictionary) -> void:
	%StationPanel.visible = not flat_mode
	scene_hint.visible = not flat_mode
	auto_toggle.visible = not flat_mode
	trigger_toggle.visible = not flat_mode
	if flat_mode:
		%Controls.text = str(%Controls.text).split("\n")[0]
	for button: Button in get_tree().get_nodes_in_group("station_buttons"):
		if is_ancestor_of(button):
			button.disabled = not station_enabled.get(int(button.get_meta("station_id")), false)
