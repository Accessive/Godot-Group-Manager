@tool
extends EditorPlugin

var _dock_ui: Control

# Saved location key — persisted in EditorSettings so it survives restarts.
const SETTING_KEY := "group_manager/dock_location"

# Maps option index → location name used in _apply_location()
const LOCATIONS := ["Bottom Panel", "Left (Upper)", "Left (Lower)", "Right (Upper)", "Right (Lower)"]
const DOCK_SLOTS := [
	-1,                    # Bottom Panel (special case)
	DOCK_SLOT_LEFT_UL,
	DOCK_SLOT_LEFT_BL,
	DOCK_SLOT_RIGHT_UL,
	DOCK_SLOT_RIGHT_BL,
]

var _current_location_idx: int = 0  # default: Bottom Panel


func _enter_tree() -> void:
	_dock_ui = preload("res://addons/group_manager/group_manager_dock.gd").new()
	_dock_ui.editor_plugin = self

	# Restore saved location, default to Bottom Panel.
	if EditorInterface.get_editor_settings().has_setting(SETTING_KEY):
		_current_location_idx = EditorInterface.get_editor_settings().get_setting(SETTING_KEY)
	_current_location_idx = clamp(_current_location_idx, 0, LOCATIONS.size() - 1)

	_apply_location(_current_location_idx)

	scene_changed.connect(_on_scene_changed)
	get_undo_redo().history_changed.connect(_on_history_changed)

	# Tell the dock what locations are available so it can populate its dropdown.
	_dock_ui.setup_location_menu(LOCATIONS, _current_location_idx, _on_location_selected)


func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if get_undo_redo().history_changed.is_connected(_on_history_changed):
		get_undo_redo().history_changed.disconnect(_on_history_changed)

	_remove_current_location()
	_dock_ui.queue_free()


func _apply_location(idx: int) -> void:
	if idx == 0:
		add_control_to_bottom_panel(_dock_ui, "Groups")
	else:
		add_control_to_dock(DOCK_SLOTS[idx], _dock_ui)


func _remove_current_location() -> void:
	if _current_location_idx == 0:
		remove_control_from_bottom_panel(_dock_ui)
	else:
		remove_control_from_docks(_dock_ui)


func _on_location_selected(idx: int) -> void:
	if idx == _current_location_idx:
		return
	_remove_current_location()
	_current_location_idx = idx
	_apply_location(idx)
	# Persist preference.
	EditorInterface.get_editor_settings().set_setting(SETTING_KEY, idx)


func _on_scene_changed(_scene_root: Node) -> void:
	if is_instance_valid(_dock_ui):
		_dock_ui.refresh()


func _on_history_changed() -> void:
	if is_instance_valid(_dock_ui):
		_dock_ui.refresh()
