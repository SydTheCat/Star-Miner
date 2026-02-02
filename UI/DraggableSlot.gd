extends Panel
class_name DraggableSlot

# A draggable inventory slot that supports drag and drop.

const BlockTypes = preload("res://Data/BlockTypes.gd")

signal slot_dropped(from_slot: DraggableSlot, to_slot: DraggableSlot)

var block_id: int = BlockTypes.BLOCK_AIR
var block_count: int = 0
var slot_index: int = -1

var icon: ColorRect
var count_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(50, 50)
	
	# Create icon.
	icon = ColorRect.new()
	icon.name = "Icon"
	icon.set_anchors_preset(Control.PRESET_CENTER)
	icon.position = Vector2(10, 10)
	icon.size = Vector2(30, 30)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(icon)
	
	# Create count label.
	count_label = Label.new()
	count_label.name = "CountLabel"
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.add_theme_font_size_override("font_size", 11)
	count_label.add_theme_color_override("font_color", Color.WHITE)
	count_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	count_label.add_theme_constant_override("shadow_offset_x", 1)
	count_label.add_theme_constant_override("shadow_offset_y", 1)
	count_label.position = Vector2(25, 35)
	count_label.size = Vector2(22, 14)
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(count_label)
	
	_update_display()


func set_block(id: int, count: int) -> void:
	block_id = id
	block_count = count
	_update_display()


func _update_display() -> void:
	if icon:
		icon.color = _get_block_color(block_id)
		icon.visible = block_id != BlockTypes.BLOCK_AIR
	
	if count_label:
		if block_id != BlockTypes.BLOCK_AIR and block_count > 0:
			count_label.text = str(block_count)
		else:
			count_label.text = ""


func _get_drag_data(_at_position: Vector2) -> Variant:
	if block_id == BlockTypes.BLOCK_AIR or block_count <= 0:
		return null
	
	# Create drag preview.
	var preview := ColorRect.new()
	preview.size = Vector2(40, 40)
	preview.color = _get_block_color(block_id)
	preview.modulate.a = 0.8
	set_drag_preview(preview)
	
	return {
		"type": "inventory_item",
		"block_id": block_id,
		"count": block_count,
		"source_slot": self
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is Dictionary and data.get("type") == "inventory_item":
		return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if data is Dictionary and data.get("type") == "inventory_item":
		var source_slot: DraggableSlot = data.get("source_slot")
		if source_slot and source_slot != self:
			slot_dropped.emit(source_slot, self)


func _get_block_color(id: int) -> Color:
	match id:
		BlockTypes.BLOCK_AIR:
			return Color(0.1, 0.1, 0.1, 0.3)
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
