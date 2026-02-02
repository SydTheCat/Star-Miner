extends Panel
class_name HotbarSlot

# A hotbar slot that can receive drops and be dragged from.

const BlockTypes = preload("res://Data/BlockTypes.gd")

var hotbar: Control
var slot_index: int = 0


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is Dictionary and data.get("type") == "inventory_item":
		return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if hotbar and data is Dictionary and data.get("type") == "inventory_item":
		hotbar.drop_data_on_slot(slot_index, data)


func _get_drag_data(_at_position: Vector2) -> Variant:
	if hotbar == null:
		return null
	
	var block_id: int = hotbar.slots[slot_index]
	var count: int = hotbar.inventory.get(block_id, 0)
	
	if block_id == BlockTypes.BLOCK_AIR or count <= 0:
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
		"count": count,
		"source": "hotbar",
		"source_slot_index": slot_index
	}


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
