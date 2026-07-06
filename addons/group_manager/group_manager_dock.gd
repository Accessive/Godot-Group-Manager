## Group Manager dock — lists every group in the current scene and lets you
## manage node membership. All mutations go through EditorUndoRedoManager so
## Ctrl+Z works correctly.
##
## Empty group persistence: Godot doesn't store groups that have no members.
## We work around this by saving a .gm_groups file next to each .tscn so
## empty (or intentionally pre-declared) groups survive across sessions.

@tool
extends VBoxContainer

## Set by plugin.gd immediately after instantiation.
var editor_plugin: EditorPlugin

# ── Internal state ─────────────────────────────────────────────────────────────
var _group_list: VBoxContainer
var _group_search: LineEdit
var _status_label: Label
var _location_btn: OptionButton
var _selected_group: String = ""
var _node_search_text: Dictionary = {}   # { group_name: String }

# All groups explicitly created via this dock — persisted to .gm_groups file.
# We ALWAYS keep every created group here so removing the last node member
# never silently deletes it.
var _persisted_groups: Dictionary = {}   # { group_name: true }

const _BADGE_FG   := Color(0.55, 0.80, 1.0, 1.0)
const _EMPTY_FG   := Color(0.65, 0.65, 0.65, 1.0)
const _GLOBAL_FG  := Color(0.60, 0.90, 0.65, 1.0)   # green tint for global badge
const _MATCH_FG   := Color(0.95, 0.75, 0.30, 1.0)
const _CONFIG_EXT := ".gm_groups"


# ── Build the dock UI ──────────────────────────────────────────────────────────
func _ready() -> void:
	name = "GroupManagerDock"
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 4)
	add_child(toolbar)

	var refresh_btn := Button.new()
	refresh_btn.text = "↺"
	refresh_btn.tooltip_text = "Refresh group list"
	refresh_btn.flat = true
	refresh_btn.pressed.connect(refresh)
	toolbar.add_child(refresh_btn)

	var add_btn := Button.new()
	add_btn.text = "+ Group"
	add_btn.tooltip_text = "Create a new group"
	add_btn.pressed.connect(_on_add_group_pressed)
	toolbar.add_child(add_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	_group_search = LineEdit.new()
	_group_search.placeholder_text = "Filter groups…"
	_group_search.custom_minimum_size = Vector2(120, 0)
	_group_search.clear_button_enabled = true
	_group_search.text_changed.connect(_on_group_search_changed)
	toolbar.add_child(_group_search)

	_location_btn = OptionButton.new()
	_location_btn.tooltip_text = "Dock location"
	_location_btn.flat = true
	toolbar.add_child(_location_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_group_list = VBoxContainer.new()
	_group_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_group_list)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_status_label)

	_load_persisted_groups()
	refresh()


func setup_location_menu(locations: Array, current_idx: int, callback: Callable) -> void:
	if not is_instance_valid(_location_btn):
		return
	_location_btn.clear()
	for loc in locations:
		_location_btn.add_item(loc)
	_location_btn.selected = current_idx
	_location_btn.item_selected.connect(callback)


# ── Fuzzy match ────────────────────────────────────────────────────────────────
func _fuzzy_match(text: String, query: String) -> bool:
	if query.is_empty():
		return true
	var t := text.to_lower()
	var q := query.to_lower()
	var ti := 0
	for qi in range(q.length()):
		var ch := q[qi]
		var found := false
		while ti < t.length():
			if t[ti] == ch:
				ti += 1
				found = true
				break
			ti += 1
		if not found:
			return false
	return true


func _fuzzy_match_indices(text: String, query: String) -> Array:
	var indices: Array = []
	if query.is_empty():
		return indices
	var t := text.to_lower()
	var q := query.to_lower()
	var ti := 0
	for qi in range(q.length()):
		var ch := q[qi]
		while ti < t.length():
			if t[ti] == ch:
				indices.append(ti)
				ti += 1
				break
			ti += 1
	return indices


func _make_fuzzy_label(text: String, query: String) -> RichTextLabel:
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.scroll_active = false
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("normal_font_size", 14)

	if query.is_empty():
		lbl.text = text
		return lbl

	var indices := _fuzzy_match_indices(text, query)
	var idx_set: Dictionary = {}
	for i in indices:
		idx_set[i] = true

	var bb := ""
	for i in range(text.length()):
		var ch := text[i]
		ch = ch.replace("[", "[lb]")
		if idx_set.has(i):
			bb += "[color=#%s]%s[/color]" % [_MATCH_FG.to_html(false), ch]
		else:
			bb += ch
	lbl.parse_bbcode(bb)
	return lbl


# ── Global group detection ─────────────────────────────────────────────────────
## Returns a Set (Dictionary keyed by name) of groups registered globally in
## Project Settings > Globals > Groups.
func _get_global_group_names() -> Dictionary:
	var result: Dictionary = {}

	# Source A: live in-memory ProjectSettings. Global groups are stored as
	# "global_group/<name>" property keys (Godot 4.7:
	# core/config/project_settings.cpp _set handler). get_property_list() still
	# lists these hidden-prefix keys, so this reflects groups created this
	# session even before project.godot has been saved to disk.
	for prop in ProjectSettings.get_property_list():
		var pname: String = prop["name"]
		if pname.begins_with("global_group/"):
			result[pname.substr("global_group/".length())] = true

	# Source B: parse project.godot from disk under the [global_group] section
	# as a fallback. Note: NOT "global_groups" (plural) — that plural form was a
	# bug in earlier plugin builds and is not a real Godot key.
	var cfg := ConfigFile.new()
	var project_path := ProjectSettings.globalize_path("res://project.godot")
	if cfg.load(project_path) == OK and cfg.has_section("global_group"):
		for key in cfg.get_section_keys("global_group"):
			result[key] = true

	return result


# ── Persistence ────────────────────────────────────────────────────────────────
func _config_path() -> String:
	var scene_path := EditorInterface.get_edited_scene_root().scene_file_path \
		if EditorInterface.get_edited_scene_root() != null else ""
	if scene_path.is_empty():
		return ""
	return scene_path.get_basename() + _CONFIG_EXT


func _load_persisted_groups() -> void:
	_persisted_groups.clear()
	var path := _config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	for g in cfg.get_section_keys("groups"):
		_persisted_groups[g] = true


func _save_persisted_groups() -> void:
	var path := _config_path()
	if path.is_empty():
		return
	# Save ALL persisted groups — including those with live members — so that
	# unchecking the last node never silently deletes the group.
	var cfg := ConfigFile.new()
	for g in _persisted_groups.keys():
		cfg.set_value("groups", g, true)
	if cfg.get_section_keys("groups").is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	else:
		cfg.save(path)


# ── Group data ─────────────────────────────────────────────────────────────────
func _get_live_groups() -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return {}
	var result: Dictionary = {}
	_walk_node(scene_root, result)
	return result


func _walk_node(node: Node, groups_dict: Dictionary) -> void:
	for g in node.get_groups():
		if g.begins_with("_"):
			continue
		if not groups_dict.has(g):
			groups_dict[g] = []
		groups_dict[g].append(node)
	for child in node.get_children():
		_walk_node(child, groups_dict)


func _get_all_groups() -> Dictionary:
	var result := _get_live_groups()
	# Merge persisted empties.
	for g in _persisted_groups.keys():
		if not result.has(g):
			result[g] = []
	return result


# ── Public refresh ─────────────────────────────────────────────────────────────
func refresh() -> void:
	_load_persisted_groups()
	_rebuild_list(_group_search.text if is_instance_valid(_group_search) else "")


# ── Rebuild the group list ─────────────────────────────────────────────────────
func _rebuild_list(filter: String) -> void:
	for child in _group_list.get_children():
		child.queue_free()

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		var lbl := Label.new()
		lbl.text = "No scene open."
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_group_list.add_child(lbl)
		_status_label.text = ""
		return

	var groups := _get_all_groups()
	var global_names := _get_global_group_names()

	# Global groups with no members in the current scene won't appear in
	# _get_all_groups() (which only knows about live node groups + persisted
	# scene groups). Seed them in with empty member lists so they still show.
	for gname in global_names.keys():
		if not groups.has(gname):
			groups[gname] = []

	# Split into global and scene groups, each sorted alphabetically.
	var global_groups: Array = []
	var scene_groups: Array = []
	for g in groups.keys():
		if not _fuzzy_match(g, filter):
			continue
		if global_names.has(g):
			global_groups.append(g)
		else:
			scene_groups.append(g)
	global_groups.sort()
	scene_groups.sort()

	# ── Global groups section ──
	if not global_groups.is_empty():
		var section_lbl := Label.new()
		section_lbl.text = "Global Groups"
		section_lbl.add_theme_font_size_override("font_size", 11)
		section_lbl.add_theme_color_override("font_color", _GLOBAL_FG)
		_group_list.add_child(section_lbl)
		for g in global_groups:
			_group_list.add_child(_build_group_row(g, groups[g], scene_root, filter, true))

	# ── Scene groups section ──
	if not scene_groups.is_empty():
		var section_lbl := Label.new()
		section_lbl.text = "Scene Groups"
		section_lbl.add_theme_font_size_override("font_size", 11)
		section_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_group_list.add_child(section_lbl)
		for g in scene_groups:
			_group_list.add_child(_build_group_row(g, groups[g], scene_root, filter, false))

	if global_groups.is_empty() and scene_groups.is_empty():
		var lbl := Label.new()
		lbl.text = "No groups found." if filter.is_empty() else "No matches."
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_group_list.add_child(lbl)

	var total := groups.size()
	_status_label.text = "%d group%s  ·  %d global  ·  %d scene" % [
		total, "s" if total != 1 else "",
		global_groups.size(),
		scene_groups.size(),
	]


# ── Build one collapsible group row ───────────────────────────────────────────
func _build_group_row(
	group_name: String,
	members: Array,
	scene_root: Node,
	group_filter: String,
	is_global: bool
) -> Control:
	var is_empty := members.is_empty()
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 0)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	container.add_child(header)

	var toggle := Button.new()
	toggle.flat = true
	toggle.add_theme_font_size_override("font_size", 10)
	toggle.custom_minimum_size = Vector2(20, 0)
	header.add_child(toggle)

	var name_lbl := _make_fuzzy_label(group_name, group_filter)
	if is_empty:
		name_lbl.add_theme_color_override("default_color", _EMPTY_FG)
	header.add_child(name_lbl)

	# Global badge.
	if is_global:
		var global_badge := Label.new()
		global_badge.text = "global"
		global_badge.add_theme_font_size_override("font_size", 10)
		global_badge.add_theme_color_override("font_color", _GLOBAL_FG)
		global_badge.tooltip_text = "Registered in Project Settings > Globals > Groups"
		header.add_child(global_badge)

	# Member count / empty badge.
	var badge := Label.new()
	badge.add_theme_font_size_override("font_size", 11)
	if is_empty:
		badge.text = "empty"
		badge.add_theme_color_override("font_color", _EMPTY_FG)
		badge.tooltip_text = "No nodes assigned yet"
	else:
		badge.text = str(members.size())
		badge.add_theme_color_override("font_color", _BADGE_FG)
		badge.tooltip_text = "%d node%s in this group" % [members.size(), "s" if members.size() != 1 else ""]
	header.add_child(badge)

	var rename_btn := Button.new()
	rename_btn.text = "✎"
	rename_btn.flat = true
	rename_btn.tooltip_text = "Rename group"
	rename_btn.pressed.connect(_on_rename_group.bind(group_name, members, is_global))
	header.add_child(rename_btn)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.flat = true
	del_btn.tooltip_text = "Delete group"
	del_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	del_btn.pressed.connect(_on_delete_group.bind(group_name, members, is_global))
	header.add_child(del_btn)

	# Node search bar (shown when expanded).
	var node_search := LineEdit.new()
	node_search.placeholder_text = "Search nodes…"
	node_search.clear_button_enabled = true
	node_search.visible = false
	node_search.text = _node_search_text.get(group_name, "")
	container.add_child(node_search)

	var members_panel := VBoxContainer.new()
	members_panel.add_theme_constant_override("separation", 1)
	members_panel.visible = (group_name == _selected_group)
	container.add_child(members_panel)

	node_search.visible = members_panel.visible
	toggle.text = "▼" if members_panel.visible else "▶"
	_populate_node_rows(members_panel, group_name, scene_root, members, node_search.text)

	node_search.text_changed.connect(func(new_text: String):
		_node_search_text[group_name] = new_text
		for child in members_panel.get_children():
			child.queue_free()
		_populate_node_rows(members_panel, group_name, scene_root, members, new_text)
	)

	toggle.pressed.connect(func():
		members_panel.visible = not members_panel.visible
		node_search.visible = members_panel.visible
		toggle.text = "▼" if members_panel.visible else "▶"
		_selected_group = group_name if members_panel.visible else ""
		if members_panel.visible:
			node_search.grab_focus()
	)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(1, 1, 1, 0.06))
	container.add_child(sep)

	return container


# ── Node checkbox rows ─────────────────────────────────────────────────────────
func _populate_node_rows(
	panel: VBoxContainer,
	group_name: String,
	scene_root: Node,
	members: Array,
	node_filter: String
) -> void:
	var all_nodes: Array[Node] = []
	_collect_all_nodes(scene_root, all_nodes)

	var _sort_fn := func(a: Node, b: Node) -> bool:
		var a_in: bool = a in members
		var b_in: bool = b in members
		if a_in != b_in:
			return a_in
		return a.name.naturalnocasecmp_to(b.name) < 0
	all_nodes.sort_custom(_sort_fn)

	var shown := 0
	for node in all_nodes:
		if not _fuzzy_match(node.name, node_filter):
			continue
		shown += 1

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var indent := Label.new()
		indent.text = "   "
		row.add_child(indent)

		var check := CheckBox.new()
		check.button_pressed = node in members
		check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		row.add_child(check)

		var icon := _get_node_icon(node)
		if icon:
			var icon_rect := TextureRect.new()
			icon_rect.texture = icon
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.custom_minimum_size = Vector2(16, 16)
			row.add_child(icon_rect)

		var node_lbl := _make_fuzzy_label(node.name, node_filter)
		node_lbl.tooltip_text = scene_root.get_path_to(node)
		if not (node in members):
			node_lbl.add_theme_color_override("default_color", Color(0.65, 0.65, 0.65))
		row.add_child(node_lbl)

		panel.add_child(row)
		check.toggled.connect(_on_membership_toggled.bind(node, group_name))

	if shown == 0 and not node_filter.is_empty():
		var lbl := Label.new()
		lbl.text = "   No nodes match '%s'" % node_filter
		lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		panel.add_child(lbl)


func _collect_all_nodes(node: Node, out: Array) -> void:
	out.append(node)
	for child in node.get_children():
		_collect_all_nodes(child, out)


func _get_node_icon(node: Node) -> Texture2D:
	# get_editor_theme() was added in 4.3 — guard it for 4.2 compatibility.
	if not EditorInterface.has_method("get_editor_theme"):
		return null
	var theme := EditorInterface.get_editor_theme()
	if theme == null:
		return null
	var class_name_str := node.get_class()
	while class_name_str != "":
		if theme.has_icon(class_name_str, "EditorIcons"):
			return theme.get_icon(class_name_str, "EditorIcons")
		class_name_str = ClassDB.get_parent_class(class_name_str)
	return null


# ── Callbacks ──────────────────────────────────────────────────────────────────

func _on_group_search_changed(text: String) -> void:
	_rebuild_list(text)


func _on_add_group_pressed() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "New Group"
	dialog.get_ok_button().text = "Create"

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)

	# Name field.
	var name_lbl := Label.new()
	name_lbl.text = "Group name (snake_case recommended):"
	vbox.add_child(name_lbl)

	var field := LineEdit.new()
	field.placeholder_text = "my_group"
	field.custom_minimum_size = Vector2(260, 0)
	vbox.add_child(field)

	# Scope selector.
	var scope_lbl := Label.new()
	scope_lbl.text = "Scope:"
	vbox.add_child(scope_lbl)

	var scope_box := HBoxContainer.new()
	scope_box.add_theme_constant_override("separation", 8)
	vbox.add_child(scope_box)

	var btn_scene := Button.new()
	btn_scene.text = "Scene"
	btn_scene.tooltip_text = "Exists only in this scene. Saved to the .gm_groups file."
	btn_scene.toggle_mode = true
	btn_scene.button_pressed = true
	scope_box.add_child(btn_scene)

	var btn_global := Button.new()
	btn_global.text = "Global"
	btn_global.tooltip_text = "Registered project-wide in Project Settings > Globals > Groups."
	btn_global.toggle_mode = true
	btn_global.button_pressed = false
	scope_box.add_child(btn_global)

	# Keep the two buttons mutually exclusive.
	btn_scene.toggled.connect(func(on: bool):
		if on:
			btn_global.button_pressed = false
		elif not btn_global.button_pressed:
			btn_scene.button_pressed = true
	)
	btn_global.toggled.connect(func(on: bool):
		if on:
			btn_scene.button_pressed = false
		elif not btn_scene.button_pressed:
			btn_global.button_pressed = true
	)

	# Description field (only shown for global groups).
	var desc_lbl := Label.new()
	desc_lbl.text = "Description (optional):"
	desc_lbl.visible = false
	vbox.add_child(desc_lbl)

	var desc_field := LineEdit.new()
	desc_field.placeholder_text = "What this group is used for…"
	desc_field.custom_minimum_size = Vector2(260, 0)
	desc_field.visible = false
	vbox.add_child(desc_field)

	btn_global.toggled.connect(func(on: bool):
		desc_lbl.visible = on
		desc_field.visible = on
	)

	dialog.add_child(vbox)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	field.grab_focus()

	dialog.confirmed.connect(func():
		var new_name := field.text.strip_edges()
		if new_name.is_empty():
			return
		if btn_global.button_pressed:
			# Godot stores global groups under "global_group/<name>" (singular, no s).
			# The value is a plain String containing the description.
			var key := "global_group/" + new_name
			ProjectSettings.set_setting(key, desc_field.text.strip_edges())
			ProjectSettings.save()
		else:
			_persisted_groups[new_name] = true
			_save_persisted_groups()
		_selected_group = new_name
		refresh()
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())


func _on_rename_group(old_name: String, members: Array, is_global: bool) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Rename Group"
	dialog.get_ok_button().text = "Rename"

	var vbox := VBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "New name for '" + old_name + "':"
	vbox.add_child(lbl)

	var field := LineEdit.new()
	field.text = old_name
	field.custom_minimum_size = Vector2(240, 0)
	field.select_all()
	vbox.add_child(field)

	dialog.add_child(vbox)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
	field.grab_focus()

	dialog.confirmed.connect(func():
		var new_name := field.text.strip_edges()
		if new_name.is_empty() or new_name == old_name:
			dialog.queue_free()
			return

		if is_global:
			# Move the ProjectSettings key: preserve the description, clear the old
			# key (null triggers remove_global_group per Godot 4.7 source), set new.
			var desc: String = ProjectSettings.get_setting("global_group/" + old_name, "")
			ProjectSettings.set_setting("global_group/" + old_name, null)
			ProjectSettings.set_setting("global_group/" + new_name, desc)
			ProjectSettings.save()
		else:
			if _persisted_groups.has(old_name):
				_persisted_groups.erase(old_name)
			_persisted_groups[new_name] = true
			_save_persisted_groups()

		# Re-tag any live node members regardless of scope.
		if not members.is_empty():
			var ur := editor_plugin.get_undo_redo()
			ur.create_action("Rename group: " + old_name + " → " + new_name)
			for node in members:
				ur.add_do_method(node, "add_to_group", new_name, true)
				ur.add_do_method(node, "remove_from_group", old_name)
				ur.add_undo_method(node, "add_to_group", old_name, true)
				ur.add_undo_method(node, "remove_from_group", new_name)
			ur.commit_action()

		_selected_group = new_name
		refresh()
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())


func _on_delete_group(group_name: String, members: Array, is_global: bool) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete Group"
	if is_global:
		dialog.dialog_text = "Delete GLOBAL group '%s' from Project Settings?%s" % [
			group_name,
			"" if members.is_empty() else "\nIt will also be removed from %d node%s in this scene." % [
				members.size(), "s" if members.size() != 1 else ""
			]
		]
	elif members.is_empty():
		dialog.dialog_text = "Delete empty group '%s'?" % group_name
	else:
		dialog.dialog_text = "Delete group '%s' and remove it from %d node%s?" % [
			group_name, members.size(), "s" if members.size() != 1 else ""
		]
	dialog.get_ok_button().text = "Delete"
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

	dialog.confirmed.connect(func():
		_persisted_groups.erase(group_name)
		_node_search_text.erase(group_name)
		_save_persisted_groups()

		# For global groups, clear the ProjectSettings key. Per Godot 4.7 source
		# (core/config/project_settings.cpp _set), setting a "global_group/<name>"
		# key to null triggers the internal remove_global_group() call.
		if is_global:
			ProjectSettings.set_setting("global_group/" + group_name, null)
			ProjectSettings.save()

		if not members.is_empty():
			var ur := editor_plugin.get_undo_redo()
			ur.create_action("Delete group: " + group_name)
			for node in members:
				ur.add_do_method(node, "remove_from_group", group_name)
				ur.add_undo_method(node, "add_to_group", group_name, true)
			ur.commit_action()

		if _selected_group == group_name:
			_selected_group = ""
		refresh()
		dialog.queue_free()
	)
	dialog.canceled.connect(func(): dialog.queue_free())


func _on_membership_toggled(toggled_on: bool, node: Node, group_name: String) -> void:
	if not is_instance_valid(node):
		return
	var already_member := node.is_in_group(group_name)
	if toggled_on == already_member:
		return

	var ur := editor_plugin.get_undo_redo()
	if toggled_on:
		ur.create_action("Add '%s' to group '%s'" % [node.name, group_name])
		ur.add_do_method(node, "add_to_group", group_name, true)
		ur.add_undo_method(node, "remove_from_group", group_name)
	else:
		ur.create_action("Remove '%s' from group '%s'" % [node.name, group_name])
		ur.add_do_method(node, "remove_from_group", group_name)
		ur.add_undo_method(node, "add_to_group", group_name, true)
	ur.commit_action()

	# Always re-persist so the group survives losing all its members.
	_persisted_groups[group_name] = true
	_save_persisted_groups()
	refresh()
