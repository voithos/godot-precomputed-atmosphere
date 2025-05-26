class_name Atmosphere
extends Node3D

@export var transmittance_lut_size := Vector2i(256, 64)
@export var ms_lut_size := Vector2i(32, 32)
@export var skyview_lut_size := Vector2i(200, 100)

@export var debug_draw: bool:
	set(v):
		debug_draw = v
		$DebugView.visible = v

# Debug TextureRects.
@onready var _transmittance_rect := $DebugView/Transmittance
@onready var _ms_rect := $DebugView/MultipleScattering
@onready var _skyview_rect := $DebugView/SkyView
var _transmittance_debug_texture := Texture2DRD.new()
var _ms_debug_texture := Texture2DRD.new()
var _skyview_debug_texture := Texture2DRD.new()

func _ready() -> void:
	_initialize_debug_rects()
	RenderingServer.call_on_render_thread(_initialize_compute_resources)

func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		_cleanup()

func _initialize_debug_rects() -> void:
	# debug_draw = false
	_transmittance_rect.texture = _transmittance_debug_texture
	_transmittance_rect.size = transmittance_lut_size
	_transmittance_rect.position = Vector2.ZERO
	_ms_rect.texture = _ms_debug_texture
	_ms_rect.size = ms_lut_size
	_ms_rect.position = Vector2(_transmittance_rect.position.x + _transmittance_rect.size.x + 1, 0)
	_skyview_rect.texture = _skyview_debug_texture
	_skyview_rect.size = skyview_lut_size
	_skyview_rect.position = Vector2(_ms_rect.position.x + _ms_rect.size.x + 1, 0)

func _cleanup() -> void:
	RenderingServer.call_on_render_thread(_cleanup_compute_resources)

func _process(delta: float) -> void:
	RenderingServer.call_on_render_thread(_render_process)

## Render thread code.
##

# Local thread group size.
const LOCAL_SIZE := Vector2i(8, 8)
const TEXTURE_FORMAT := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT

var rd: RenderingDevice
# Track RIDs for cleanup.
var rids: Array[RID] = []

var transmittance_shader: RID
var transmittance_pipeline: RID
var transmittance_lut: RID
var transmittance_uniform_set: RID

func _initialize_compute_resources():
	assert(RenderingServer.is_on_render_thread())
	# Use main rendering device, since the atmosphere is part of normal frame rendering.
	rd = RenderingServer.get_rendering_device()

	transmittance_shader = load_shader("res://atmosphere/transmittance_lut.glsl")
	transmittance_pipeline = create_compute_pipeline(transmittance_shader)
	transmittance_lut = create_texture_2d(transmittance_lut_size, TEXTURE_FORMAT)
	_transmittance_debug_texture.texture_rd_rid = transmittance_lut
	_ms_debug_texture.texture_rd_rid = transmittance_lut
	_skyview_debug_texture.texture_rd_rid = transmittance_lut

	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(transmittance_lut)
	transmittance_uniform_set = rd.uniform_set_create([uniform], transmittance_shader, 0)
	rids.push_back(transmittance_uniform_set)

func _render_process() -> void:
	assert(RenderingServer.is_on_render_thread())
	var workgroup_size := workgroup_size(transmittance_lut_size)

	var transmittance_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(transmittance_list, transmittance_pipeline)
	rd.compute_list_bind_uniform_set(transmittance_list, transmittance_uniform_set, 0)
	rd.compute_list_dispatch(transmittance_list, workgroup_size.x, workgroup_size.y, 1)
	rd.compute_list_end()

	# TODO: do we need rd.submit()?
	# also remember rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE) for later

func _cleanup_compute_resources():
	assert(RenderingServer.is_on_render_thread())
	rids.reverse()
	for rid in rids:
		rd.free_rid(rid)

func load_shader(file_path: String) -> RID:
	var shader_file := load(file_path)
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)
	rids.push_back(shader)
	return shader

func create_compute_pipeline(shader: RID) -> RID:
	var pipeline := rd.compute_pipeline_create(shader)
	rids.push_back(pipeline)
	return pipeline

func create_texture_2d(size: Vector2i, format: RenderingDevice.DataFormat) -> RID:
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.format = format
	tf.width = size.x
	tf.height = size.y
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	var texture := rd.texture_create(tf, RDTextureView.new())
	rids.push_back(texture)
	return texture

func workgroup_size(texture_size: Vector2i) -> Vector2i:
	# In case texture is not a perfect multiple of LOCAL_SIZE, we compute a slightly larger
	# workgroup size.
	return (texture_size - Vector2i(1, 1)) / LOCAL_SIZE + Vector2i(1, 1)
