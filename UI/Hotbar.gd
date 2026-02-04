extends Control

const BlockTypes = preload("res://Data/BlockTypes.gd")
const BlockTextures = preload("res://Data/BlockTextures.gd")
const HotbarSlotScript = preload("res://UI/HotbarSlot.gd")

var block_textures: Node = null

const SLOT_COUNT := 10

@export_group("Stack Sizes")
@export var default_stack_size: int = 64
@export var dirt_stack_size: int = 100
@export var wood_stack_size: int = 100
@export var leaves_stack_size: int = 100
@export var stone_stack_size: int = 64
@export var grass_stack_size: int = 64

var selected_slot: int = 0
var slots: Array[int] = []  # Block type in each slot
var slot_counts: Array[int] = []  # Count in each slot
var slot_nodes: Array[Panel] = []

@onready var slot_container: HBoxContainer = $SlotContainer

signal slot_selected(slot_index: int, block_id: int)
signal item_dropped_to_hotbar(block_id: int, slot_index: int)


func _ready() -> void:
	# Ensure we can receive drop events.
	mouse_filter = Control.MOUSE_FILTER_STOP
	if slot_container:
		slot_container.mouse_filter = Control.MOUSE_FILTER_PASS
	
	# Initialize slots as empty.
	slots.resize(SLOT_COUNT)
	slot_counts.resize(SLOT_COUNT)
	for i in SLOT_COUNT:
		slots[i] = BlockTypes.BLOCK_AIR
		slot_counts[i] = 0
	
	_create_slot_ui()
	_update_selection()


func _create_slot_ui() -> void:
	slot_nodes.clear()
	# Create slot panels.
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
		
		# Add hotkey label (top-left corner).
		var hotkey_label := Label.new()
		hotkey_label.name = "HotkeyLabel"
		hotkey_label.text = str(i + 1) if i < 9 else "0"
		hotkey_label.add_theme_font_size_override("font_size", 10)
		hotkey_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		hotkey_label.position = Vector2(3, 1)
		hotkey_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(hotkey_label)
		
		# Add block indicator (texture).
		var block_indicator := TextureRect.new()
		block_indicator.name = "BlockTexture"
		block_indicator.position = Vector2(10, 10)
		block_indicator.size = Vector2(30, 30)
		block_indicator.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		block_indicator.stretch_mode = TextureRect.STRETCH_SCALE
		block_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_update_block_texture(block_indicator, slots[i])
		slot.add_child(block_indicator)
		
		# Add count label (bottom-right corner).
		var count_label := Label.new()
		count_label.name = "CountLabel"
		count_label.text = ""
		count_label.add_theme_font_size_override("font_size", 11)
		count_label.add_theme_color_override("font_color", Color(1, 1, 1))
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.position = Vector2(25, 35)
		count_label.size = Vector2(22, 14)
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(count_label)
		
		slot_container.add_child(slot)
		slot_nodes.append(slot)


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	print("Hotbar _can_drop_data called with: ", data)
	if data is Dictionary and data.get("type") == "inventory_item":
		# Check if over a slot.
		for i in slot_nodes.size():
			var slot: Panel = slot_nodes[i]
			var slot_rect := Rect2(slot.global_position, slot.size)
			if slot_rect.has_point(get_global_mouse_position()):
				print("  -> Can drop on slot ", i)
				return true
	return false


func _drop_data(at_position: Vector2, data: Variant) -> void:
	print("Hotbar _drop_data called with: ", data)
	if not (data is Dictionary and data.get("type") == "inventory_item"):
		return
	
	# Find which slot we're dropping on.
	for i in slot_nodes.size():
		var slot: Panel = slot_nodes[i]
		var slot_rect := Rect2(slot.global_position, slot.size)
		if slot_rect.has_point(get_global_mouse_position()):
			print("  -> Dropping on slot ", i)
			drop_data_on_slot(i, data)
			return


func can_drop_data_on_slot(slot_index: int, data: Variant) -> bool:
	if data is Dictionary and data.get("type") == "inventory_item":
		return true
	return false


func drop_data_on_slot(slot_index: int, data: Variant) -> void:
	if not (data is Dictionary and data.get("type") == "inventory_item"):
		return
	
	var block_id: int = data.get("block_id", BlockTypes.BLOCK_AIR)
	var source: String = data.get("source", "")
	var source_slot_index: int = data.get("source_slot_index", -1)
	
	if block_id == BlockTypes.BLOCK_AIR:
		return
	
	# If dragging from inventory UI, add to this slot.
	if source == "inventory":
		# Set this slot to the dragged block.
		slots[slot_index] = block_id
		_update_slot_display(slot_index)
		item_dropped_to_hotbar.emit(block_id, slot_index)
	
	# If dragging from another hotbar slot, swap.
	elif source == "hotbar" and source_slot_index >= 0 and source_slot_index != slot_index:
		var temp_block: int = slots[slot_index]
		slots[slot_index] = slots[source_slot_index]
		slots[source_slot_index] = temp_block
		_update_slot_display(slot_index)
		_update_slot_display(source_slot_index)


func _input(event: InputEvent) -> void:
	# Number keys 1-9 and 0 for slot selection.
	if event is InputEventKey and event.pressed:
		var key: int = (event as InputEventKey).keycode
		if key >= KEY_1 and key <= KEY_9:
			select_slot(key - KEY_1)
		elif key == KEY_0:
			select_slot(9)
	
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
	emit_signal("slot_selected", selected_slot, slots[selected_slot])


func _update_selection() -> void:
	# Update visual selection.
	for i in slot_container.get_child_count():
		var slot: Panel = slot_container.get_child(i)
		var style: StyleBoxFlat = slot.get_theme_stylebox("panel").duplicate()
		if i == selected_slot:
			style.border_color = Color(1.0, 1.0, 0.0)  # Yellow highlight
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


func get_selected_block() -> int:
	return slots[selected_slot]


func set_slot_block(index: int, block_id: int) -> void:
	if index < 0 or index >= SLOT_COUNT:
		return
	slots[index] = block_id
	_update_slot_display(index)


func _update_slot_display(index: int) -> void:
	if index < 0 or index >= slot_container.get_child_count():
		return
	var slot: Panel = slot_container.get_child(index)
	var block_texture: TextureRect = slot.get_node_or_null("BlockTexture")
	var count_label: Label = slot.get_node_or_null("CountLabel")
	
	var block_id: int = slots[index]
	if block_texture:
		_update_block_texture(block_texture, block_id)
	
	if count_label:
		var count: int = slot_counts[index]
		if block_id != BlockTypes.BLOCK_AIR and count > 0:
			count_label.text = str(count)
		else:
			count_label.text = ""


func _ensure_block_textures() -> void:
	if block_textures:
		return
	block_textures = get_tree().root.get_node_or_null("BlockTextures")
	if block_textures == null:
		block_textures = BlockTextures.new()
		block_textures.name = "BlockTextures"
		get_tree().root.add_child(block_textures)


func _update_block_texture(tex_rect: TextureRect, block_id: int) -> void:
	_ensure_block_textures()
	if block_id == BlockTypes.BLOCK_AIR or block_textures == null:
		tex_rect.texture = null
		return
	var tex: AtlasTexture = block_textures.get_block_texture(block_id, "side")
	tex_rect.texture = tex


func get_max_stack(block_id: int) -> int:
	# Return max stack size for a block type.
	match block_id:
		BlockTypes.BLOCK_DIRT:
			return dirt_stack_size
		BlockTypes.BLOCK_WOOD:
			return wood_stack_size
		BlockTypes.BLOCK_LEAVES:
			return leaves_stack_size
		BlockTypes.BLOCK_STONE:
			return stone_stack_size
		BlockTypes.BLOCK_GRASS:
			return grass_stack_size
		_:
			return default_stack_size


func add_block(block_id: int, amount: int = 1) -> void:
	# Add block to inventory, with overflow to new slots.
	if block_id == BlockTypes.BLOCK_AIR:
		return
	
	var max_stack := get_max_stack(block_id)
	var remaining := amount
	
	# First, try to add to existing slots with this block type.
	for i in SLOT_COUNT:
		if slots[i] == block_id and remaining > 0:
			var can_add := max_stack - slot_counts[i]
			if can_add > 0:
				var to_add := mini(remaining, can_add)
				slot_counts[i] += to_add
				remaining -= to_add
				_update_slot_display(i)
	
	# If still have remaining, find empty slots.
	while remaining > 0:
		var empty_slot := -1
		for i in SLOT_COUNT:
			if slots[i] == BlockTypes.BLOCK_AIR:
				empty_slot = i
				break
		
		if empty_slot == -1:
			break  # No more empty slots.
		
		# Add to empty slot.
		slots[empty_slot] = block_id
		var to_add := mini(remaining, max_stack)
		slot_counts[empty_slot] = to_add
		remaining -= to_add
		_update_slot_display(empty_slot)


func remove_block(block_id: int, amount: int = 1) -> bool:
	# Remove block from selected slot. Returns true if successful.
	if block_id == BlockTypes.BLOCK_AIR:
		return false
	
	# Remove from selected slot first.
	if slots[selected_slot] == block_id and slot_counts[selected_slot] >= amount:
		slot_counts[selected_slot] -= amount
		if slot_counts[selected_slot] <= 0:
			slots[selected_slot] = BlockTypes.BLOCK_AIR
			slot_counts[selected_slot] = 0
		_update_slot_display(selected_slot)
		return true
	
	# Otherwise find any slot with this block.
	for i in SLOT_COUNT:
		if slots[i] == block_id and slot_counts[i] >= amount:
			slot_counts[i] -= amount
			if slot_counts[i] <= 0:
				slots[i] = BlockTypes.BLOCK_AIR
				slot_counts[i] = 0
			_update_slot_display(i)
			return true
	
	return false


func get_block_count(block_id: int) -> int:
	var total := 0
	for i in SLOT_COUNT:
		if slots[i] == block_id:
			total += slot_counts[i]
	return total


func can_place_block() -> bool:
	# Check if selected slot has blocks to place.
	var block_id: int = slots[selected_slot]
	if block_id == BlockTypes.BLOCK_AIR:
		return false
	return slot_counts[selected_slot] > 0


func _get_block_color(block_id: int) -> Color:
	match block_id:
		BlockTypes.BLOCK_AIR:
			return Color(0.1, 0.1, 0.1, 0.5)
		BlockTypes.BLOCK_GRASS:
			return Color(0.2, 0.8, 0.2)
		BlockTypes.BLOCK_DIRT:
			return Color(0.5, 0.3, 0.1)
		BlockTypes.BLOCK_STONE:
			return Color(0.5, 0.5, 0.5)
		BlockTypes.BLOCK_WATER:
			return Color(0.2, 0.4, 0.9, 0.7)
		_:
			return Color(1, 0, 1)  # Magenta for unknown
