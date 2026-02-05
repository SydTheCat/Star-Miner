extends Control

# Toolbar - holds weapons and tools only.
# Blocks go in the inventory (Tab), not here.

const SLOT_COUNT := 5

var selected_slot: int = -1  # -1 = no selection.
# Each slot holds a tool/weapon name (String). Empty string = empty slot.
var slots: Array[String] = []
var slot_nodes: Array[Panel] = []

@onready var slot_container: HBoxContainer = $SlotContainer

signal slot_selected(slot_index: int, tool_name: String)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if slot_container:
		slot_container.mouse_filter = Control.MOUSE_FILTER_PASS
	
	# Initialize empty slots.
	slots.resize(SLOT_COUNT)
	for i in SLOT_COUNT:
		slots[i] = ""
	
	_create_slot_ui()
	_update_selection()


func _create_slot_ui() -> void:
	slot_nodes.clear()
	for i in SLOT_COUNT:
		var slot := Panel.new()
		slot.name = "Slot%d" % i
		slot.custom_minimum_size = Vector2(50, 50)
		slot.set_meta("slot_index", i)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		
		# Style the slot.
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.2, 0.2, 0.2, 0.8)
		style.border_width_left = 2
		style.border_width_right = 2
		style.border_width_top = 2
		style.border_width_bottom = 2
		style.border_color = Color(0.4, 0.4, 0.4)
		style.corner_radius_top_left = 4
		style.corner_radius_top_right = 4
		style.corner_radius_bottom_left = 4
		style.corner_radius_bottom_right = 4
		slot.add_theme_stylebox_override("panel", style)
		
		# Hotkey label (top-left corner).
		var hotkey_label := Label.new()
		hotkey_label.name = "HotkeyLabel"
		hotkey_label.text = str(i + 1)
		hotkey_label.add_theme_font_size_override("font_size", 10)
		hotkey_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		hotkey_label.position = Vector2(3, 1)
		hotkey_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(hotkey_label)
		
		# Tool/weapon icon placeholder.
		var icon := TextureRect.new()
		icon.name = "ToolIcon"
		icon.position = Vector2(10, 10)
		icon.size = Vector2(30, 30)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon)
		
		# Tool name label (bottom).
		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.text = ""
		name_label.add_theme_font_size_override("font_size", 8)
		name_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.position = Vector2(0, 37)
		name_label.size = Vector2(50, 12)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(name_label)
		
		slot_container.add_child(slot)
		slot_nodes.append(slot)


func _input(event: InputEvent) -> void:
	# Number keys 1-5 for slot selection.
	if event is InputEventKey and event.pressed:
		var key: int = (event as InputEventKey).keycode
		if key >= KEY_1 and key <= KEY_5:
			select_slot(key - KEY_1)
	
	# Mouse wheel for slot cycling.
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			select_slot((selected_slot - 1 + SLOT_COUNT) % SLOT_COUNT)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			select_slot((selected_slot + 1) % SLOT_COUNT)


func select_slot(index: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	selected_slot = index
	_update_selection()
	slot_selected.emit(selected_slot, slots[selected_slot])


func _update_selection() -> void:
	for i in slot_container.get_child_count():
		var slot: Panel = slot_container.get_child(i)
		var style: StyleBoxFlat = slot.get_theme_stylebox("panel").duplicate()
		if i == selected_slot:
			style.border_color = Color(1.0, 1.0, 0.0)
			style.border_width_left = 3
			style.border_width_right = 3
			style.border_width_top = 3
			style.border_width_bottom = 3
		else:
			style.border_color = Color(0.4, 0.4, 0.4)
			style.border_width_left = 2
			style.border_width_right = 2
			style.border_width_top = 2
			style.border_width_bottom = 2
		slot.add_theme_stylebox_override("panel", style)


func get_selected_tool() -> String:
	if selected_slot < 0 or selected_slot >= SLOT_COUNT:
		return ""
	return slots[selected_slot]


func set_slot_tool(index: int, tool_name: String) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	slots[index] = tool_name
	_update_slot_display(index)


func _update_slot_display(index: int) -> void:
	if index < 0 or index >= slot_nodes.size():
		return
	var slot: Panel = slot_nodes[index]
	var name_label: Label = slot.get_node_or_null("NameLabel")
	if name_label:
		name_label.text = slots[index] if slots[index] != "" else ""
	var tool_icon: TextureRect = slot.get_node_or_null("ToolIcon")
	if tool_icon:
		var icon_path: String = _get_tool_icon_path(slots[index])
		if icon_path != "":
			tool_icon.texture = load(icon_path)
			tool_icon.visible = true
		else:
			tool_icon.texture = null
			tool_icon.visible = false


static func _get_tool_icon_path(tool_name: String) -> String:
	match tool_name:
		"Multitool":
			return "res://Assets/Icons/multitool.png"
		_:
			return ""
