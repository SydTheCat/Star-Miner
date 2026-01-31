extends CharacterBody3D

# Basic first-person controller for Godot 4.x.
# Uses Input Map actions:
#   move_forward, move_back, move_left, move_right, jump, sprint, toggle_mouse_capture

const MOVE_SPEED := 6.0
const SPRINT_MULTIPLIER := 1.7
const JUMP_VELOCITY := 5.5

# Use a normal var here because ProjectSettings.get_setting() is not a constant expression.
var GRAVITY: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var mouse_sensitivity: float = 0.0025
var yaw: float = 0.0
var pitch: float = 0.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(delta: float) -> void:
	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input_dir.y = Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")

	var direction := Vector3.ZERO
	if input_dir.length() > 0.0:
		input_dir = input_dir.normalized()
		direction = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	var speed := MOVE_SPEED
	if Input.is_action_pressed("sprint"):
		speed *= SPRINT_MULTIPLIER

	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		if Input.is_action_just_pressed("jump"):
			velocity.y = JUMP_VELOCITY

	move_and_slide()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, deg_to_rad(-89.0), deg_to_rad(89.0))

		rotation.y = yaw
		head.rotation.x = pitch

	if event.is_action_pressed("toggle_mouse_capture"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
