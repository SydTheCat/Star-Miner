extends Control

# Inventory UI - 6x4 grid for blocks/items + backpack refinery.
# Toggle with Tab key. Expandable in the future.

const BlockTypes = preload("res://Data/BlockTypes.gd")
const BlockTextures = preload("res://Data/BlockTextures.gd")

const COLUMNS := 6
const ROWS := 4
const SLOT_COUNT := COLUMNS * ROWS  # 24 slots

var block_textures: Node = null

signal inventory_opened
signal inventory_closed
signal block_selected(block_id: int)

var is_open: bool = false
var player: Node = null

# Slot data: each slot holds a block_id and count.
var slot_data: Array[Dictionary] = []  # [{block_id, count}, ...]
var selected_slot_index: int = -1

# Refinery state.
var refinery_input_id: int = BlockTypes.BLOCK_AIR
var refinery_input_count: int = 0
var is_refining: bool = false
var refine_total: int = 0
var refine_processed: int = 0
var refine_timer: float = 0.0
var refine_time_per_item: float = 2.0  # Set per recipe.
var refinery_sound: AudioStreamPlayer = null
var refinery_done_sound: AudioStreamPlayer = null

@onready var panel: Panel = $Panel
@onready var close_button: Button = $Panel/VBoxContainer/TitleBar/CloseButton
@onready var item_grid: GridContainer = $Panel/VBoxContainer/ContentArea/ItemGrid
@onready var refinery_input_slot: Panel = $Panel/VBoxContainer/ContentArea/RefineryPanel/InputSlot
@onready var process_button: Button = $Panel/VBoxContainer/ContentArea/RefineryPanel/ProcessButton
@onready var progress_bar: ProgressBar = $Panel/VBoxContainer/ContentArea/RefineryPanel/ProgressBar
@onready var status_label: Label = $Panel/VBoxContainer/ContentArea/RefineryPanel/StatusLabel


func _ready() -> void:
	visible = false
	close_button.pressed.connect(_on_close_pressed)
	process_button.pressed.connect(_on_process_pressed)
	
	# Initialize empty slot data.
	slot_data.resize(SLOT_COUNT)
	for i in SLOT_COUNT:
		slot_data[i] = {"block_id": BlockTypes.BLOCK_AIR, "count": 0}
	
	_build_grid()
	_style_refinery_slots()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inventory"):
		toggle()
		get_viewport().set_input_as_handled()
		return


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
	_refresh_grid()
	_refresh_refinery_input()
	inventory_opened.emit()


func close() -> void:
	if not is_open:
		return
	is_open = false
	visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	inventory_closed.emit()


# --- Inventory data management ---

func add_block(block_id: int, amount: int = 1) -> int:
	if block_id == BlockTypes.BLOCK_AIR:
		return amount
	var remaining := amount
	
	for i in SLOT_COUNT:
		if remaining <= 0:
			break
		if slot_data[i].block_id == block_id:
			var can_add: int = 64 - int(slot_data[i].count)
			if can_add > 0:
				var to_add: int = mini(remaining, can_add)
				slot_data[i].count += to_add
				remaining -= to_add
	
	for i in SLOT_COUNT:
		if remaining <= 0:
			break
		if slot_data[i].block_id == BlockTypes.BLOCK_AIR:
			var to_add := mini(remaining, 64)
			slot_data[i].block_id = block_id
			slot_data[i].count = to_add
			remaining -= to_add
	
	if is_open:
		_refresh_grid()
	return remaining


func remove_block(block_id: int, amount: int = 1) -> bool:
	if block_id == BlockTypes.BLOCK_AIR:
		return false
	if get_block_count(block_id) < amount:
		return false
	
	var remaining := amount
	for i in SLOT_COUNT:
		if remaining <= 0:
			break
		if slot_data[i].block_id == block_id:
			var to_remove: int = mini(remaining, int(slot_data[i].count))
			slot_data[i].count -= to_remove
			remaining -= to_remove
			if slot_data[i].count <= 0:
				slot_data[i].block_id = BlockTypes.BLOCK_AIR
				slot_data[i].count = 0
	
	if is_open:
		_refresh_grid()
	return true


func get_block_count(block_id: int) -> int:
	var total := 0
	for i in SLOT_COUNT:
		if slot_data[i].block_id == block_id:
			total += slot_data[i].count
	return total


func get_selected_block() -> int:
	if selected_slot_index >= 0 and selected_slot_index < SLOT_COUNT:
		return slot_data[selected_slot_index].block_id
	return BlockTypes.BLOCK_AIR


func can_place_block() -> bool:
	if selected_slot_index < 0 or selected_slot_index >= SLOT_COUNT:
		return false
	var d: Dictionary = slot_data[selected_slot_index]
	return d.block_id != BlockTypes.BLOCK_AIR and d.count > 0 and BlockTypes.is_placeable(d.block_id)


func remove_selected_block(amount: int = 1) -> bool:
	if selected_slot_index < 0 or selected_slot_index >= SLOT_COUNT:
		return false
	var d: Dictionary = slot_data[selected_slot_index]
	if d.block_id == BlockTypes.BLOCK_AIR or d.count < amount:
		return false
	d.count -= amount
	if d.count <= 0:
		d.block_id = BlockTypes.BLOCK_AIR
		d.count = 0
	if is_open:
		_refresh_grid()
	return true


# --- Grid UI ---

func _build_grid() -> void:
	for child in item_grid.get_children():
		child.queue_free()
	
	for i in SLOT_COUNT:
		var slot := _create_slot(i)
		item_grid.add_child(slot)


func _refresh_grid() -> void:
	var children := item_grid.get_children()
	for i in mini(children.size(), SLOT_COUNT):
		_update_slot_visual(children[i], i)


func _create_slot(index: int) -> Button:
	var slot := Button.new()
	slot.custom_minimum_size = Vector2(56, 56)
	slot.flat = true
	slot.set_meta("slot_index", index)
	slot.clip_contents = true
	
	var style := _make_slot_style(false)
	slot.add_theme_stylebox_override("normal", style)
	slot.add_theme_stylebox_override("hover", _make_slot_style_hover())
	slot.add_theme_stylebox_override("pressed", style)
	slot.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	
	# Block icon.
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.position = Vector2(6, 6)
	icon.size = Vector2(44, 44)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)
	
	# Color swatch for items without textures (ores).
	var color_swatch := ColorRect.new()
	color_swatch.name = "ColorSwatch"
	color_swatch.position = Vector2(6, 6)
	color_swatch.size = Vector2(44, 44)
	color_swatch.visible = false
	color_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(color_swatch)
	
	# Count label.
	var count_label := Label.new()
	count_label.name = "CountLabel"
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.add_theme_font_size_override("font_size", 11)
	count_label.add_theme_color_override("font_color", Color.WHITE)
	count_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	count_label.add_theme_constant_override("shadow_offset_x", 1)
	count_label.add_theme_constant_override("shadow_offset_y", 1)
	count_label.anchors_preset = Control.PRESET_FULL_RECT
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count_label)
	
	# Name label (shown on hover via tooltip).
	slot.tooltip_text = ""
	
	slot.pressed.connect(_on_slot_pressed.bind(index))
	slot.gui_input.connect(_on_slot_gui_input.bind(index))
	
	# Enable drag-and-drop from this slot.
	slot.set_drag_forwarding(_slot_get_drag_data.bind(index), _slot_can_drop_data, _slot_drop_data)
	
	return slot


func _update_slot_visual(slot: Button, index: int) -> void:
	var d: Dictionary = slot_data[index]
	var icon: TextureRect = slot.get_node_or_null("Icon")
	var color_swatch: ColorRect = slot.get_node_or_null("ColorSwatch")
	var count_label: Label = slot.get_node_or_null("CountLabel")
	
	_ensure_block_textures()
	
	var has_item: bool = d.block_id != BlockTypes.BLOCK_AIR and d.count > 0
	
	if has_item:
		var item_id: int = d.block_id
		# Check if it's a refined item or a block.
		if BlockTypes.is_item(item_id):
			var icon_path: String = BlockTypes.get_item_icon(item_id)
			if icon_path != "" and icon:
				icon.texture = load(icon_path)
				icon.visible = true
				if color_swatch:
					color_swatch.visible = false
			else:
				if icon:
					icon.texture = null
					icon.visible = false
				if color_swatch:
					color_swatch.color = BlockTypes.get_item_color(item_id)
					color_swatch.visible = true
		else:
			if icon and block_textures:
				var tex: AtlasTexture = block_textures.get_block_texture(item_id, "side")
				icon.texture = tex
				icon.visible = true
			if color_swatch:
				color_swatch.visible = false
		
		if count_label:
			count_label.text = str(d.count) if d.count > 1 else ""
		slot.tooltip_text = "%s x%d" % [BlockTypes.get_block_name(item_id), d.count]
		slot.modulate = Color.WHITE
	else:
		if icon:
			icon.texture = null
			icon.visible = false
		if color_swatch:
			color_swatch.visible = false
		if count_label:
			count_label.text = ""
		slot.tooltip_text = ""
		slot.modulate = Color.WHITE  # Keep outlines visible on empty slots.
	
	# Update selection highlight.
	var is_selected := (index == selected_slot_index)
	var style := _make_slot_style(is_selected)
	slot.add_theme_stylebox_override("normal", style)
	slot.add_theme_stylebox_override("pressed", style)


func _on_slot_pressed(index: int) -> void:
	var d: Dictionary = slot_data[index]
	if d.block_id == BlockTypes.BLOCK_AIR or d.count <= 0:
		selected_slot_index = -1
	elif selected_slot_index == index:
		selected_slot_index = -1
	else:
		selected_slot_index = index
	
	block_selected.emit(get_selected_block())
	_refresh_grid()


# --- Drag and drop ---

func _on_slot_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pass  # Selection handled by _on_slot_pressed.


func _slot_get_drag_data(at_position: Vector2, index: int) -> Variant:
	var d: Dictionary = slot_data[index]
	if d.block_id == BlockTypes.BLOCK_AIR or d.count <= 0:
		return null
	
	# Create drag preview.
	var preview := _make_drag_preview(int(d.block_id), int(d.count))
	set_drag_preview(preview)
	
	return {"source": "inventory", "slot_index": index, "block_id": d.block_id, "count": d.count}


func _slot_can_drop_data(_at_position: Vector2, _data: Variant) -> bool:
	return false  # Inventory slots don't accept drops for now.


func _slot_drop_data(_at_position: Vector2, _data: Variant) -> void:
	pass


func _make_drag_preview(item_id: int, count: int) -> Control:
	_ensure_block_textures()
	
	var preview := Panel.new()
	preview.custom_minimum_size = Vector2(48, 48)
	preview.size = Vector2(48, 48)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.18, 0.22, 0.9)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	preview.add_theme_stylebox_override("panel", style)
	preview.modulate.a = 0.9
	
	# Show the actual texture/icon in the preview.
	if BlockTypes.is_item(item_id):
		var icon_path: String = BlockTypes.get_item_icon(item_id)
		if icon_path != "":
			var tex_icon := TextureRect.new()
			tex_icon.texture = load(icon_path)
			tex_icon.position = Vector2(4, 4)
			tex_icon.size = Vector2(40, 40)
			tex_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex_icon.stretch_mode = TextureRect.STRETCH_SCALE
			tex_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			preview.add_child(tex_icon)
		else:
			var swatch := ColorRect.new()
			swatch.color = BlockTypes.get_item_color(item_id)
			swatch.position = Vector2(4, 4)
			swatch.size = Vector2(40, 40)
			swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
			preview.add_child(swatch)
	else:
		if block_textures:
			var tex: AtlasTexture = block_textures.get_block_texture(item_id, "side")
			if tex:
				var tex_icon := TextureRect.new()
				tex_icon.texture = tex
				tex_icon.position = Vector2(4, 4)
				tex_icon.size = Vector2(40, 40)
				tex_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tex_icon.stretch_mode = TextureRect.STRETCH_SCALE
				tex_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
				preview.add_child(tex_icon)
	
	var lbl := Label.new()
	lbl.text = "%s" % BlockTypes.get_block_name(item_id)
	if count > 1:
		lbl.text += " x%d" % count
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.position = Vector2(0, -18)
	preview.add_child(lbl)
	
	return preview


# --- Refinery ---

func _process(delta: float) -> void:
	if not is_refining:
		return
	
	refine_timer += delta
	
	# Keep sound looping while refining.
	if refinery_sound and not refinery_sound.playing:
		refinery_sound.play()
	
	# Progress bar fills 0→1 for the current single item.
	var item_progress: float = clampf(refine_timer / refine_time_per_item, 0.0, 1.0)
	progress_bar.value = item_progress
	
	# Update status.
	var time_left: float = refine_time_per_item - refine_timer
	status_label.text = "Refining... %d / %d  (%.0fs)" % [refine_processed, refine_total, maxf(time_left, 0.0)]
	
	# Check if current item is done.
	if refine_timer >= refine_time_per_item:
		refine_timer = 0.0
		
		# Get result based on input type.
		var result_id: int = _get_refine_result(refinery_input_id)
		
		# Try to add to inventory.
		var leftover: int = add_block(result_id, 1)
		if leftover > 0:
			is_refining = false
			process_button.text = "REFINE ALL"
			progress_bar.value = 0.0
			status_label.text = "Inventory full! %d left." % refinery_input_count
			if refinery_sound:
				refinery_sound.stop()
			_refresh_refinery_input()
			return
		
		# Consume 1 input, advance count.
		refinery_input_count -= 1
		refine_processed += 1
		
		# Play done sound for this block.
		if refinery_done_sound:
			refinery_done_sound.play()
		
		# Flash the bar full briefly then reset.
		progress_bar.value = 1.0
		status_label.text = "Produced: %s (%d/%d)" % [BlockTypes.get_block_name(result_id), refine_processed, refine_total]
		_refresh_refinery_input()
		_refresh_grid()
		
		# Check if all done.
		if refine_processed >= refine_total or refinery_input_count <= 0:
			is_refining = false
			process_button.text = "REFINE ALL"
			if refinery_input_count <= 0:
				refinery_input_id = BlockTypes.BLOCK_AIR
				refinery_input_count = 0
			status_label.text = "Done! Refined %d items." % refine_processed
			progress_bar.value = 0.0
			if refinery_sound:
				refinery_sound.stop()
			_refresh_refinery_input()
			_refresh_grid()


func _style_refinery_slots() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.18, 0.95)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.4, 0.45, 0.5)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	refinery_input_slot.add_theme_stylebox_override("panel", style)
	
	refinery_input_slot.mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Add icon children to input slot.
	var tex_icon := TextureRect.new()
	tex_icon.name = "TexIcon"
	tex_icon.position = Vector2(8, 8)
	tex_icon.size = Vector2(48, 48)
	tex_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex_icon.stretch_mode = TextureRect.STRETCH_SCALE
	tex_icon.visible = false
	tex_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refinery_input_slot.add_child(tex_icon)
	
	var icon := ColorRect.new()
	icon.name = "Icon"
	icon.position = Vector2(8, 8)
	icon.size = Vector2(48, 48)
	icon.visible = false
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refinery_input_slot.add_child(icon)
	
	var lbl := Label.new()
	lbl.name = "CountLabel"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color.BLACK)
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.anchors_preset = Control.PRESET_FULL_RECT
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	refinery_input_slot.add_child(lbl)
	
	# Connect input slot for click-to-load.
	refinery_input_slot.gui_input.connect(_on_refinery_input_gui_input)
	
	# Enable drop on refinery input slot.
	refinery_input_slot.set_drag_forwarding(_refinery_get_drag_data, _refinery_can_drop_data, _refinery_drop_data)
	
	# Initialize progress bar.
	progress_bar.value = 0.0
	
	# Load refinery sounds.
	refinery_sound = AudioStreamPlayer.new()
	refinery_sound.stream = load("res://Assets/SoundFX/backpack_process1.mp3")
	refinery_sound.volume_db = -11.0
	add_child(refinery_sound)
	
	refinery_done_sound = AudioStreamPlayer.new()
	refinery_done_sound.stream = load("res://Assets/SoundFX/done_process.mp3")
	refinery_done_sound.volume_db = -11.0
	add_child(refinery_done_sound)


func _refinery_get_drag_data(_at_position: Vector2) -> Variant:
	return null  # Can't drag out of refinery input.


func _refinery_can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if is_refining:
		return false
	if data is Dictionary and data.has("source") and data.source == "inventory":
		return true
	return false


func _refinery_drop_data(_at_position: Vector2, data: Variant) -> void:
	if is_refining:
		return
	if not (data is Dictionary and data.has("slot_index")):
		return
	var slot_index: int = data.slot_index
	if slot_index < 0 or slot_index >= SLOT_COUNT:
		return
	var d: Dictionary = slot_data[slot_index]
	if d.block_id == BlockTypes.BLOCK_AIR or d.count <= 0:
		return
	_load_into_refinery(slot_index)


func _on_refinery_input_gui_input(event: InputEvent) -> void:
	if is_refining:
		return  # Don't allow changes while refining.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# If we have a selected inventory slot, move its contents to refinery input.
		if selected_slot_index >= 0 and selected_slot_index < SLOT_COUNT:
			var d: Dictionary = slot_data[selected_slot_index]
			if d.block_id != BlockTypes.BLOCK_AIR and d.count > 0:
				_load_into_refinery(selected_slot_index)
		elif refinery_input_id != BlockTypes.BLOCK_AIR:
			# Click input slot to return items to inventory.
			_return_refinery_input()


func _load_into_refinery(slot_index: int) -> void:
	var d: Dictionary = slot_data[slot_index]
	var item_id: int = d.block_id
	var count: int = d.count
	
	# If input already has something different, return it first.
	if refinery_input_id != BlockTypes.BLOCK_AIR and refinery_input_id != item_id:
		_return_refinery_input()
	
	# Stack into refinery input.
	if refinery_input_id == item_id:
		refinery_input_count += count
	else:
		refinery_input_id = item_id
		refinery_input_count = count
	
	# Clear the inventory slot.
	d.block_id = BlockTypes.BLOCK_AIR
	d.count = 0
	selected_slot_index = -1
	
	_refresh_grid()
	_refresh_refinery_input()


func _return_refinery_input() -> void:
	if refinery_input_id == BlockTypes.BLOCK_AIR:
		return
	var leftover: int = add_block(refinery_input_id, refinery_input_count)
	refinery_input_count = leftover
	if refinery_input_count <= 0:
		refinery_input_id = BlockTypes.BLOCK_AIR
		refinery_input_count = 0
	_refresh_refinery_input()
	_refresh_grid()


func _on_process_pressed() -> void:
	# If already refining, stop.
	if is_refining:
		_stop_refining()
		return
	
	if refinery_input_id == BlockTypes.BLOCK_AIR or refinery_input_count <= 0:
		status_label.text = "Nothing to refine!"
		return
	
	# Check if this material can be refined.
	var time: float = _get_refine_time(refinery_input_id)
	if time <= 0.0:
		status_label.text = "Can't refine %s" % BlockTypes.get_block_name(refinery_input_id)
		return
	
	# Start batch refining.
	is_refining = true
	refine_total = refinery_input_count
	refine_processed = 0
	refine_timer = 0.0
	refine_time_per_item = time
	progress_bar.value = 0.0
	process_button.text = "STOP"
	status_label.text = "Refining... 0 / %d  (%.0fs)" % [refine_total, time]


func _stop_refining() -> void:
	is_refining = false
	progress_bar.value = 0.0
	process_button.text = "REFINE ALL"
	if refinery_sound:
		refinery_sound.stop()
	if refinery_input_count <= 0:
		refinery_input_id = BlockTypes.BLOCK_AIR
		refinery_input_count = 0
	if refine_processed > 0:
		status_label.text = "Stopped. Refined %d items." % refine_processed
	else:
		status_label.text = "Stopped."
	_refresh_refinery_input()
	_refresh_grid()


# Returns processing time per block, or 0 if not refinable.
static func _get_refine_time(input_id: int) -> float:
	match input_id:
		BlockTypes.BLOCK_DIRT:
			return 2.0
		BlockTypes.BLOCK_LEAVES:
			return 3.0
		BlockTypes.BLOCK_WOOD:
			return 7.0
		BlockTypes.BLOCK_STONE:
			return 10.0
		_:
			return 0.0


# Returns the output item for a given input block.
func _get_refine_result(input_id: int) -> int:
	match input_id:
		BlockTypes.BLOCK_DIRT:
			return BlockTypes.ITEM_MINERALS
		BlockTypes.BLOCK_LEAVES:
			return BlockTypes.ITEM_FIBER
		BlockTypes.BLOCK_WOOD:
			return BlockTypes.ITEM_WOOD_PLANKS
		BlockTypes.BLOCK_STONE:
			# Weighted: Iron 40%, Silicon 35%, Nickel 25%.
			var roll: int = randi() % 100
			if roll < 40:
				return BlockTypes.ITEM_IRON
			elif roll < 75:
				return BlockTypes.ITEM_SILICON
			else:
				return BlockTypes.ITEM_NICKEL
		_:
			return BlockTypes.BLOCK_AIR


func _refresh_refinery_input() -> void:
	_ensure_block_textures()
	var input_icon: ColorRect = refinery_input_slot.get_node_or_null("Icon")
	var input_tex: TextureRect = refinery_input_slot.get_node_or_null("TexIcon")
	var input_count: Label = refinery_input_slot.get_node_or_null("CountLabel")
	if refinery_input_id != BlockTypes.BLOCK_AIR and refinery_input_count > 0:
		var showed_tex: bool = false
		if BlockTypes.is_item(refinery_input_id):
			# Item with a custom icon.
			var icon_path: String = BlockTypes.get_item_icon(refinery_input_id)
			if icon_path != "" and input_tex:
				input_tex.texture = load(icon_path)
				input_tex.visible = true
				showed_tex = true
		else:
			# Block — use atlas texture.
			if block_textures and input_tex:
				var tex: AtlasTexture = block_textures.get_block_texture(refinery_input_id, "side")
				if tex:
					input_tex.texture = tex
					input_tex.visible = true
					showed_tex = true
		if showed_tex:
			if input_icon:
				input_icon.visible = false
		else:
			if input_tex:
				input_tex.visible = false
			if input_icon:
				input_icon.color = BlockTypes.get_item_color(refinery_input_id)
				input_icon.visible = true
		if input_count:
			input_count.text = str(refinery_input_count) if refinery_input_count > 1 else ""
	else:
		if input_icon:
			input_icon.visible = false
		if input_tex:
			input_tex.texture = null
			input_tex.visible = false
		if input_count:
			input_count.text = ""


# --- Styles ---

func _make_slot_style(selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.18, 0.22, 0.9)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	if selected:
		style.border_color = Color(1.0, 1.0, 0.0)
	else:
		style.border_color = Color(0.35, 0.4, 0.45, 1.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


func _make_slot_style_hover() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.24, 0.28, 0.95)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.5, 0.55, 0.6, 1.0)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


func _ensure_block_textures() -> void:
	if block_textures:
		return
	block_textures = get_tree().root.get_node_or_null("BlockTextures")
	if block_textures == null:
		block_textures = BlockTextures.new()
		block_textures.name = "BlockTextures"
		get_tree().root.add_child(block_textures)


func _on_close_pressed() -> void:
	close()
