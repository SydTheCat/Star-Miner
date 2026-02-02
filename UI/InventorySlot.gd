extends Panel
class_name InventorySlot

# A draggable inventory slot for the inventory UI.

const BlockTypes = preload("res://Data/BlockTypes.gd")

var block_id: int = 0
var block_count: int = 0


func _get_drag_data(_at_position: Vector2) -> Variant:
	if block_id <= 0 or block_count <= 0:
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
		"source": "inventory"
	}


func _get_block_color(id: int) -> Color:
	match id:
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
