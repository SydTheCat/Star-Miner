extends RefCounted

# Simple registry for block IDs.
# Using ints is cache-friendly and easy to store in arrays.

const BLOCK_AIR   := 0
const BLOCK_GRASS := 1
const BLOCK_DIRT  := 2
const BLOCK_STONE := 3
const BLOCK_WATER := 4
const BLOCK_WOOD  := 5
const BLOCK_LEAVES := 6

# Refined materials (not placeable blocks, inventory items only).
const ITEM_IRON     := 100
const ITEM_SILICON  := 101
const ITEM_NICKEL   := 102
const ITEM_MINERALS := 103
const ITEM_ORGANIC  := 104
const ITEM_FIBER    := 105
const ITEM_WOOD_PLANKS := 106

# IDs >= 100 are refined items, not placeable blocks.
static func is_item(id: int) -> bool:
	return id >= 100

static func is_placeable(id: int) -> bool:
	return id > BLOCK_AIR and id < 100 and id != BLOCK_WATER

# Optional helper to list all solid (collidable) blocks.
static func is_solid(block_id: int) -> bool:
	return block_id != BLOCK_AIR and block_id != BLOCK_WATER and block_id < 100

# Placeholder for names (useful for debug later).
static func get_block_name(block_id: int) -> String:
	match block_id:
		BLOCK_AIR:
			return "Air"
		BLOCK_GRASS:
			return "Grass"
		BLOCK_DIRT:
			return "Dirt"
		BLOCK_STONE:
			return "Stone"
		BLOCK_WATER:
			return "Water"
		BLOCK_WOOD:
			return "Wood"
		BLOCK_LEAVES:
			return "Leaves"
		ITEM_IRON:
			return "Iron Ore"
		ITEM_SILICON:
			return "Silicon"
		ITEM_NICKEL:
			return "Nickel Ore"
		ITEM_MINERALS:
			return "Minerals"
		ITEM_ORGANIC:
			return "Organic"
		ITEM_FIBER:
			return "Fiber"
		ITEM_WOOD_PLANKS:
			return "Wood Planks"
		_:
			return "Unknown(%d)" % block_id


static func get_item_color(id: int) -> Color:
	match id:
		BLOCK_GRASS:
			return Color(0.42, 0.65, 0.31)
		BLOCK_DIRT:
			return Color(0.55, 0.36, 0.24)
		BLOCK_STONE:
			return Color(0.55, 0.55, 0.55)
		BLOCK_WATER:
			return Color(0.2, 0.5, 0.9, 0.8)
		BLOCK_WOOD:
			return Color(0.45, 0.32, 0.18)
		BLOCK_LEAVES:
			return Color(0.25, 0.55, 0.18)
		ITEM_IRON:
			return Color(0.72, 0.45, 0.2)
		ITEM_SILICON:
			return Color(0.4, 0.45, 0.55)
		ITEM_NICKEL:
			return Color(0.7, 0.72, 0.65)
		ITEM_MINERALS:
			return Color(0.6, 0.75, 0.85)
		ITEM_ORGANIC:
			return Color(0.35, 0.7, 0.25)
		ITEM_FIBER:
			return Color(0.75, 0.6, 0.4)
		ITEM_WOOD_PLANKS:
			return Color(0.7, 0.55, 0.3)
		_:
			return Color(0.6, 0.6, 0.6)


# Returns icon texture path for items, or empty string if none.
static func get_item_icon(id: int) -> String:
	match id:
		ITEM_IRON:
			return "res://Assets/Icons/iron_icon.png"
		ITEM_SILICON:
			return "res://Assets/Icons/silicon_icon.png"
		ITEM_NICKEL:
			return "res://Assets/Icons/nickel_icon.png"
		ITEM_FIBER:
			return "res://Assets/Icons/fiber_icon.png"
		ITEM_WOOD_PLANKS:
			return "res://Assets/Icons/woodplanks.png"
		_:
			return ""
