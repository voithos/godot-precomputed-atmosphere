extends Camera3D

## Simple debug helper script for WASD and mouse camera movement.

@export var directional_light: DirectionalLight3D

@export var mouse_sensitivity: float = 0.002
@export var movement_speed: float = 5.0

var is_panning: bool = false
var is_lifting: bool = false
var is_sunmove: bool = false

## Nonlinear speed multiplier for WASD movement.
var speed_level := 0
const MIN_SPEED_LEVEL = 0
const MAX_SPEED_LEVEL = 10

func _input(event):
	if event is InputEventMouseMotion:
		if is_panning:
			rotation.y = wrapf(rotation.y - event.relative.x * mouse_sensitivity, 0, PI * 2)
			rotation.x = clamp(rotation.x - event.relative.y * mouse_sensitivity, deg_to_rad(-90), deg_to_rad(90))
		elif is_lifting:
			# Lift logarithmically.
			position.y += -event.relative.y * mouse_sensitivity * pow(3, log(abs(position.y)))
		elif is_sunmove:
			directional_light.rotation.y = wrapf(directional_light.rotation.y - event.relative.x * mouse_sensitivity, 0, PI * 2)
			directional_light.rotation.x = clamp(directional_light.rotation.x + event.relative.y * mouse_sensitivity, deg_to_rad(-90), deg_to_rad(90))
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN or event.button_index == MOUSE_BUTTON_WHEEL_UP:
			var level_change := -1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1
			speed_level = clamp(speed_level + level_change, MIN_SPEED_LEVEL, MAX_SPEED_LEVEL)
		else:
			# Capture mouse for remaining mouse buttons.
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE)
			if event.button_index == MOUSE_BUTTON_LEFT:
				is_panning = event.pressed
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				is_lifting = event.pressed
			elif event.button_index == MOUSE_BUTTON_MIDDLE:
				is_sunmove = event.pressed

func _physics_process(delta):
	var input_dir = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir += -global_transform.basis.z # Forward relative to camera's facing direction.
	if Input.is_key_pressed(KEY_S):
		input_dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		input_dir += -global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		input_dir += global_transform.basis.x

	var direction := input_dir.normalized()
	var speed_boost := exp(speed_level / 2.0)
	position += direction * movement_speed * speed_boost * delta
