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

# Optional helper to list all solid (collidable) blocks.
static func is_solid(block_id: int) -> bool:
	return block_id != BLOCK_AIR and block_id != BLOCK_WATER

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
		_:
			return "Unknown(%d)" % block_id
