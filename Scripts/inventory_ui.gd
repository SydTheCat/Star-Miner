extends Control

# Inventory UI - displays player inventory in a grid layout.
# Toggle with Tab key.

const BlockTypes = preload("res://Data/BlockTypes.gd")
const InventorySlotScript = preload("res://UI/InventorySlot.gd")

signal inventory_opened
signal inventory_closed
signal item_selected_for_hotbar(block_id: int)

var is_open: bool = false
var player: Node = null

# Selected item for assignment to hotbar.
var selected_block_id: int = 0
var selected_slot: Control = null

@onready var panel: Panel = $Panel
@onready var title_label: Label = $Panel/VBoxContainer/TitleBar/TitleLabel
@onready var close_button: Button = $Panel/VBoxContainer/TitleBar/CloseButton
@onready var category_list: ItemList = $Panel/VBoxContainer/ContentArea/CategoryPanel/CategoryList
@onready var item_grid: GridContainer = $Panel/VBoxContainer/ContentArea/ItemPanel/ScrollContainer/ItemGrid
@onready var item_info_panel: Panel = $Panel/VBoxContainer/ContentArea/InfoPanel
@onready var item_name_label: Label = $Panel/VBoxContainer/ContentArea/InfoPanel/VBoxContainer/ItemNameLabel
@onready var item_count_label: Label = $Panel/VBoxContainer/ContentArea/InfoPanel/VBoxContainer/ItemCountLabel
@onready var selection_label: Label = null  # Will create dynamically


func _ready() -> void:
	visible = false
	close_button.pressed.connect(_on_close_pressed)
	category_list.item_selected.connect(_on_category_selected)
	
	# Create selection indicator label.
	selection_label = Label.new()
	selection_label.text = "Click an item, then press 1-0 to assign to hotbar"
	selection_label.add_theme_font_size_override("font_size", 12)
	selection_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))
	$Panel/VBoxContainer.add_child(selection_label)
	
	# Add categories.
	category_list.add_item("All Blocks")
	category_list.add_item("Natural")
	category_list.add_item("Building")
	category_list.select(0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inventory"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	
	# Handle hotbar assignment when inventory is open and item selected.
	if is_open and selected_block_id > 0 and event is InputEventKey and event.pressed:
		var key: int = (event as InputEventKey).keycode
		var slot_index := -1
		if key >= KEY_1 and key <= KEY_9:
			slot_index = key - KEY_1
		elif key == KEY_0:
			slot_index = 9
		
		if slot_index >= 0:
			item_selected_for_hotbar.emit(selected_block_id)
			_assign_to_hotbar(slot_index)
			get_viewport().set_input_as_handled()


func _assign_to_hotbar(slot_index: int) -> void:
	if selected_block_id <= 0:
		return
	
	# Find the hotbar and assign.
	var hotbar := get_tree().current_scene.get_node_or_null("Hotbar")
	if hotbar:
		hotbar.set_slot_block(slot_index, selected_block_id)
		print("Assigned ", BlockTypes.get_block_name(selected_block_id), " to hotbar slot ", slot_index + 1)
		_update_selection_label()
		# Deselect after assignment.
		_clear_selection()


func set_player(p: Node) -> void:
	player = p


func toggle() -> void:
	if is_open:
		close()
	else:
		open()


func open() -> void:
	if is_open:
		return
	is_open = true
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	refresh_inventory()
	inventory_opened.emit()


func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	_clear_selection()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	inventory_closed.emit()


func refresh_inventory() -> void:
	# Clear existing items.
	for child in item_grid.get_children():
		child.queue_free()
	
	if player == null:
		return
	
	# Get inventory from player.
	var inventory: Dictionary = player.inventory
	
	# Add item slots for each block type in inventory.
	for block_id in inventory.keys():
		var count: int = inventory[block_id]
		if count > 0:
			_add_item_slot(block_id, count)
	
	# Add empty slots to fill the grid.
	var min_slots := 24
	var current_slots := item_grid.get_child_count()
	for i in range(current_slots, min_slots):
		_add_empty_slot()


func _add_item_slot(block_id: int, count: int) -> void:
	var slot := _create_draggable_slot(block_id, count)
	
	# Add block icon.
	var icon := ColorRect.new()
	icon.custom_minimum_size = Vector2(48, 48)
	icon.color = _get_block_color(block_id)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)
	
	# Add count label.
	var count_label := Label.new()
	count_label.text = str(count)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.add_theme_font_size_override("font_size", 12)
	count_label.add_theme_color_override("font_color", Color.WHITE)
	count_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	count_label.add_theme_constant_override("shadow_offset_x", 1)
	count_label.add_theme_constant_override("shadow_offset_y", 1)
	count_label.anchors_preset = Control.PRESET_FULL_RECT
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count_label)
	
	# Store block info for hover.
	slot.set_meta("block_id", block_id)
	slot.set_meta("count", count)
	slot.mouse_entered.connect(_on_slot_hover.bind(slot))
	
	item_grid.add_child(slot)


func _create_draggable_slot(block_id: int, count: int) -> Control:
	var slot := Button.new()
	slot.custom_minimum_size = Vector2(64, 64)
	slot.flat = true
	slot.set_meta("block_id", block_id)
	slot.set_meta("block_count", count)
	
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.18, 0.22, 0.9)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.3, 0.35, 0.4, 1.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	slot.add_theme_stylebox_override("normal", style)
	slot.add_theme_stylebox_override("hover", style)
	slot.add_theme_stylebox_override("pressed", style)
	slot.add_theme_stylebox_override("focus", style)
	
	# Connect button down for drag start.
	slot.button_down.connect(_on_inventory_slot_pressed.bind(slot))
	
	return slot


func _on_inventory_slot_pressed(slot: Button) -> void:
	var block_id: int = slot.get_meta("block_id", 0)
	var count: int = slot.get_meta("block_count", 0)
	
	if block_id <= 0 or count <= 0:
		return
	
	# Select this item.
	_select_item(slot, block_id, count)


func _select_item(slot: Control, block_id: int, count: int) -> void:
	# Clear previous selection visual.
	if selected_slot:
		selected_slot.modulate = Color.WHITE
	
	# Set new selection.
	selected_block_id = block_id
	selected_slot = slot
	slot.modulate = Color(1.2, 1.2, 0.8)  # Highlight selected.
	
	_update_selection_label()
	print("Selected: ", BlockTypes.get_block_name(block_id), " x", count)


func _clear_selection() -> void:
	if selected_slot:
		selected_slot.modulate = Color.WHITE
	selected_slot = null
	selected_block_id = 0
	_update_selection_label()


func _update_selection_label() -> void:
	if selection_label == null:
		return
	
	if selected_block_id > 0:
		var name := BlockTypes.get_block_name(selected_block_id)
		selection_label.text = "Selected: %s - Press 1-0 to assign to hotbar" % name
		selection_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	else:
		selection_label.text = "Click an item, then press 1-0 to assign to hotbar"
		selection_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))


func _add_empty_slot() -> void:
	var slot := _create_slot_panel()
	slot.modulate = Color(1, 1, 1, 0.3)
	item_grid.add_child(slot)


func _create_slot_panel() -> Panel:
	var slot := Panel.new()
	slot.custom_minimum_size = Vector2(64, 64)
	
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.18, 0.22, 0.9)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.3, 0.35, 0.4, 1.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	slot.add_theme_stylebox_override("panel", style)
	
	return slot


func _get_block_color(block_id: int) -> Color:
	match block_id:
		BlockTypes.BLOCK_GRASS:
			return Color(0.3, 0.6, 0.2)
		BlockTypes.BLOCK_DIRT:
			return Color(0.5, 0.35, 0.2)
		BlockTypes.BLOCK_STONE:
			return Color(0.5, 0.5, 0.5)
		BlockTypes.BLOCK_WATER:
			return Color(0.2, 0.5, 0.9)
		BlockTypes.BLOCK_WOOD:
			return Color(0.4, 0.26, 0.13)
		BlockTypes.BLOCK_LEAVES:
			return Color(0.3, 0.7, 0.2)
		_:
			return Color(1.0, 0.0, 1.0)


func _on_slot_hover(slot: Panel) -> void:
	if not slot.has_meta("block_id"):
		item_name_label.text = "Empty"
		item_count_label.text = ""
		return
	
	var block_id: int = slot.get_meta("block_id")
	var count: int = slot.get_meta("count")
	item_name_label.text = BlockTypes.get_block_name(block_id)
	item_count_label.text = "Count: %d" % count


func _on_close_pressed() -> void:
	close()


func _on_category_selected(index: int) -> void:
	# For now, just refresh - categories can filter later.
	refresh_inventory()
