extends Node

# Block texture manager - creates a texture atlas from individual block textures.
# Textures are loaded from res://Textures/

const BlockTypes = preload("res://Data/BlockTypes.gd")

# Texture atlas (created at runtime).
var atlas_texture: ImageTexture = null

# UV data for each block face.
# Key: "block_id:face" where face is "top", "bottom", or "side"
# Value: Rect2 with UV coordinates (position and size in 0-1 range)
var uv_rects: Dictionary = {}

# Atlas configuration.
const TEXTURE_SIZE := 16  # Expected size of each texture
const ATLAS_COLUMNS := 4  # 4x4 atlas = 16 texture slots
const ATLAS_ROWS := 4

var _initialized := false


func _ready() -> void:
	_build_atlas()


func _build_atlas() -> void:
	if _initialized:
		return
	_initialized = true
	
	# Define which textures to load and their atlas positions.
	# Format: [atlas_index, block_id, face_type, texture_path]
	# face_type: "all" = use for all faces, "top"/"bottom"/"side" = specific face
	var texture_entries := [
		[0, BlockTypes.BLOCK_GRASS, "top", "res://Textures/grass_side.png"],
		[1, BlockTypes.BLOCK_GRASS, "side", "res://Textures/grass_top.png"],
		[2, BlockTypes.BLOCK_DIRT, "all", "res://Textures/dirt.png"],
		[3, BlockTypes.BLOCK_STONE, "all", "res://Textures/stone.png"],
	]
	
	# Create atlas image.
	var atlas_size := TEXTURE_SIZE * ATLAS_COLUMNS
	var atlas_image := Image.create(atlas_size, atlas_size, false, Image.FORMAT_RGBA8)
	atlas_image.fill(Color(1, 0, 1, 1))  # Magenta for missing textures
	
	# Load textures into atlas.
	for entry in texture_entries:
		var atlas_idx: int = entry[0]
		var block_id: int = entry[1]
		var face_type: String = entry[2]
		var tex_path: String = entry[3]
		
		var atlas_x := (atlas_idx % ATLAS_COLUMNS) * TEXTURE_SIZE
		var atlas_y := (atlas_idx / ATLAS_COLUMNS) * TEXTURE_SIZE
		
		# Calculate UV rect for this texture slot.
		var uv_pos := Vector2(float(atlas_idx % ATLAS_COLUMNS) / ATLAS_COLUMNS, float(atlas_idx / ATLAS_COLUMNS) / ATLAS_ROWS)
		var uv_size := Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS)
		var uv_rect := Rect2(uv_pos, uv_size)
		
		# Store UV rect for this block/face combination.
		if face_type == "all":
			uv_rects[str(block_id) + ":top"] = uv_rect
			uv_rects[str(block_id) + ":bottom"] = uv_rect
			uv_rects[str(block_id) + ":side"] = uv_rect
		else:
			uv_rects[str(block_id) + ":" + face_type] = uv_rect
		
		# Load and copy texture to atlas.
		if ResourceLoader.exists(tex_path):
			var tex := load(tex_path) as Texture2D
			if tex:
				var img := tex.get_image()
				if img:
					if img.get_format() != Image.FORMAT_RGBA8:
						img.convert(Image.FORMAT_RGBA8)
					if img.get_width() != TEXTURE_SIZE or img.get_height() != TEXTURE_SIZE:
						img.resize(TEXTURE_SIZE, TEXTURE_SIZE, Image.INTERPOLATE_NEAREST)
					atlas_image.blit_rect(img, Rect2i(0, 0, TEXTURE_SIZE, TEXTURE_SIZE), Vector2i(atlas_x, atlas_y))
	
	# Grass bottom uses dirt texture.
	uv_rects[str(BlockTypes.BLOCK_GRASS) + ":bottom"] = uv_rects[str(BlockTypes.BLOCK_DIRT) + ":top"]
	
	# Debug: print grass UV rects
	print("Grass top UV: ", uv_rects.get(str(BlockTypes.BLOCK_GRASS) + ":top", "NOT FOUND"))
	print("Grass side UV: ", uv_rects.get(str(BlockTypes.BLOCK_GRASS) + ":side", "NOT FOUND"))
	print("Grass bottom UV: ", uv_rects.get(str(BlockTypes.BLOCK_GRASS) + ":bottom", "NOT FOUND"))
	
	# Water uses a solid blue color (slot 4).
	var water_x := (4 % ATLAS_COLUMNS) * TEXTURE_SIZE
	var water_y := (4 / ATLAS_COLUMNS) * TEXTURE_SIZE
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			atlas_image.set_pixel(water_x + x, water_y + y, Color(0.2, 0.5, 0.9, 0.8))
	var water_uv := Rect2(Vector2(float(4 % ATLAS_COLUMNS) / ATLAS_COLUMNS, float(4 / ATLAS_COLUMNS) / ATLAS_ROWS), Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS))
	uv_rects[str(BlockTypes.BLOCK_WATER) + ":top"] = water_uv
	uv_rects[str(BlockTypes.BLOCK_WATER) + ":bottom"] = water_uv
	uv_rects[str(BlockTypes.BLOCK_WATER) + ":side"] = water_uv
	
	# Wood uses log textures (slots 5, 7, 8 for top, side, bottom).
	# Log top (slot 5).
	var log_top_tex := load("res://Textures/log_top.png") as Texture2D
	var log_top_x := (5 % ATLAS_COLUMNS) * TEXTURE_SIZE
	var log_top_y := (5 / ATLAS_COLUMNS) * TEXTURE_SIZE
	if log_top_tex:
		var log_top_img := log_top_tex.get_image()
		if log_top_img.get_format() != Image.FORMAT_RGBA8:
			log_top_img.convert(Image.FORMAT_RGBA8)
		log_top_img.resize(TEXTURE_SIZE, TEXTURE_SIZE, Image.INTERPOLATE_NEAREST)
		atlas_image.blit_rect(log_top_img, Rect2i(0, 0, TEXTURE_SIZE, TEXTURE_SIZE), Vector2i(log_top_x, log_top_y))
	var wood_top_uv := Rect2(Vector2(float(5 % ATLAS_COLUMNS) / ATLAS_COLUMNS, float(5 / ATLAS_COLUMNS) / ATLAS_ROWS), Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS))
	uv_rects[str(BlockTypes.BLOCK_WOOD) + ":top"] = wood_top_uv
	
	# Log side (slot 7).
	var log_side_tex := load("res://Textures/log_side.png") as Texture2D
	var log_side_x := (7 % ATLAS_COLUMNS) * TEXTURE_SIZE
	var log_side_y := (7 / ATLAS_COLUMNS) * TEXTURE_SIZE
	if log_side_tex:
		var log_side_img := log_side_tex.get_image()
		if log_side_img.get_format() != Image.FORMAT_RGBA8:
			log_side_img.convert(Image.FORMAT_RGBA8)
		log_side_img.resize(TEXTURE_SIZE, TEXTURE_SIZE, Image.INTERPOLATE_NEAREST)
		atlas_image.blit_rect(log_side_img, Rect2i(0, 0, TEXTURE_SIZE, TEXTURE_SIZE), Vector2i(log_side_x, log_side_y))
	var wood_side_uv := Rect2(Vector2(float(7 % ATLAS_COLUMNS) / ATLAS_COLUMNS, float(7 / ATLAS_COLUMNS) / ATLAS_ROWS), Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS))
	uv_rects[str(BlockTypes.BLOCK_WOOD) + ":side"] = wood_side_uv
	
	# Log bottom (slot 8).
	var log_bottom_tex := load("res://Textures/log_bottom.png") as Texture2D
	var log_bottom_x := (8 % ATLAS_COLUMNS) * TEXTURE_SIZE
	var log_bottom_y := (8 / ATLAS_COLUMNS) * TEXTURE_SIZE
	if log_bottom_tex:
		var log_bottom_img := log_bottom_tex.get_image()
		if log_bottom_img.get_format() != Image.FORMAT_RGBA8:
			log_bottom_img.convert(Image.FORMAT_RGBA8)
		log_bottom_img.resize(TEXTURE_SIZE, TEXTURE_SIZE, Image.INTERPOLATE_NEAREST)
		atlas_image.blit_rect(log_bottom_img, Rect2i(0, 0, TEXTURE_SIZE, TEXTURE_SIZE), Vector2i(log_bottom_x, log_bottom_y))
	var wood_bottom_uv := Rect2(Vector2(float(8 % ATLAS_COLUMNS) / ATLAS_COLUMNS, float(8 / ATLAS_COLUMNS) / ATLAS_ROWS), Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS))
	uv_rects[str(BlockTypes.BLOCK_WOOD) + ":bottom"] = wood_bottom_uv
	
	# Leaves uses leaves.png texture tinted green (slot 6).
	var leaves_tex := load("res://Textures/leaves.png") as Texture2D
	var leaves_x := (6 % ATLAS_COLUMNS) * TEXTURE_SIZE
	var leaves_y := (6 / ATLAS_COLUMNS) * TEXTURE_SIZE
	if leaves_tex:
		var leaves_img := leaves_tex.get_image()
		leaves_img.resize(TEXTURE_SIZE, TEXTURE_SIZE)
		# Tint the texture green.
		var green_tint := Color(0.3, 0.7, 0.2, 1.0)
		for y in TEXTURE_SIZE:
			for x in TEXTURE_SIZE:
				var pixel := leaves_img.get_pixel(x, y)
				var tinted := Color(pixel.r * green_tint.r, pixel.g * green_tint.g, pixel.b * green_tint.b, pixel.a)
				atlas_image.set_pixel(leaves_x + x, leaves_y + y, tinted)
	else:
		# Fallback to green color.
		for y in TEXTURE_SIZE:
			for x in TEXTURE_SIZE:
				atlas_image.set_pixel(leaves_x + x, leaves_y + y, Color(0.2, 0.5, 0.15, 1.0))
	var leaves_uv := Rect2(Vector2(float(6 % ATLAS_COLUMNS) / ATLAS_COLUMNS, float(6 / ATLAS_COLUMNS) / ATLAS_ROWS), Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS))
	uv_rects[str(BlockTypes.BLOCK_LEAVES) + ":top"] = leaves_uv
	uv_rects[str(BlockTypes.BLOCK_LEAVES) + ":bottom"] = leaves_uv
	uv_rects[str(BlockTypes.BLOCK_LEAVES) + ":side"] = leaves_uv
	
	# Create texture from atlas.
	atlas_texture = ImageTexture.create_from_image(atlas_image)
	print("BlockTextures: Atlas created with ", uv_rects.size(), " UV entries")


func get_atlas() -> ImageTexture:
	if not _initialized:
		_build_atlas()
	return atlas_texture


func get_uv_rect(block_id: int, face: String) -> Rect2:
	# face should be "top", "bottom", or "side"
	if not _initialized:
		_build_atlas()
	var key := str(block_id) + ":" + face
	if key in uv_rects:
		return uv_rects[key]
	# Fallback to magenta (0,0 in atlas which is grass_top, but we'll use a default)
	return Rect2(Vector2.ZERO, Vector2(1.0 / ATLAS_COLUMNS, 1.0 / ATLAS_ROWS))


func get_block_texture(block_id: int, face: String) -> AtlasTexture:
	# Returns an AtlasTexture for the specified block face, suitable for UI display.
	if not _initialized:
		_build_atlas()
	
	var uv_rect := get_uv_rect(block_id, face)
	var atlas_tex := AtlasTexture.new()
	atlas_tex.atlas = atlas_texture
	
	# Convert UV rect (0-1) to pixel rect.
	var atlas_size := Vector2(ATLAS_COLUMNS * TEXTURE_SIZE, ATLAS_ROWS * TEXTURE_SIZE)
	atlas_tex.region = Rect2(
		uv_rect.position * atlas_size,
		uv_rect.size * atlas_size
	)
	atlas_tex.filter_clip = true
	
	return atlas_tex
