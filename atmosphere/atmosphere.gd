@tool
class_name Atmosphere
extends Node3D

@export var directional_light: DirectionalLight3D
@export var world_environment: WorldEnvironment

## Whether to automatically update atmosphere shader params in _process.
## For more control, you can disable this and manually call update_atmosphere_params().
@export var update_params_in_process: bool = true:
	set(v):
		update_params_in_process = v
		set_process(update_params_in_process)

@export_group("Sky")
@export var sky_luminance_color: Color = Color.WHITE
@export var sky_luminance_scale: float = 2.0
## The angular diameter of the sun, which is roughly half a degree. This precise number was taken
## from Bruneton's precomputed scattering implementation.
@export var sun_angular_diameter_degrees: float = 0.5357
@export var limb_darkening: bool = true

# Note that we access some of these variables from the render thread. Normally it'd be better to
# .bind() specific values to improve thread safety and guarantee a consistent snapshot of values for
# a given frame, but since these usually don't change over time (unlike camera pos / sun dir), we
# cheat a bit.
# Unfortunately, GDScript doesn't support structs, so we'd have to create a Resource type and
# duplicate it when passing it to the render thread (lest we pass each parameter individually).

@export_group("Scattering")
@export var ground_radius_km: float = 6360.0
@export var atmosphere_thickness_km: float = 100.0
@export var ground_albedo: Color = Color(0.1, 0.1, 0.1)

# These factors differ a bit from common implementations, see
# https://forums.flightsimulator.com/t/replace-the-atmosphere-parameters-with-more-accurate-ones-from-arpc/607603
@export var rayleigh_scattering_factor: Color = Color(0.22456112907, 0.41971499107, 1.0)
@export var rayleigh_scattering_scale: float = 29.412623e-3
@export var mie_scattering_factor: Color = Color(1.0, 1.0, 1.0)
@export var mie_scattering_scale: float = 3.996e-3
@export var mie_absorption_factor: Color = Color(1.0, 1.0, 1.0)
@export var mie_absorption_scale: float = 4.44e-3
@export var mie_g: float = 0.8
@export var ozone_absorption_factor: Color = Color(1.0, 0.67233180574, 0)
@export var ozone_absorption_scale: float = 2.29107232e-3
@export var ms_contribution: float = 1.0

@export_group("Aerial Perspective")
@export var ap_luminance_color: Color = Color.WHITE
@export var ap_luminance_scale: float = 2.0
@export var max_ap_distance_km: float = 50.0

@export_group("Performance")
# LUT sizes. These are only created once during _ready()
@export var transmittance_lut_size := Vector2i(256, 64)
@export var ms_lut_size := Vector2i(32, 32)
@export var skyview_lut_size := Vector2i(200, 100)
@export var ap_lut_size := Vector3i(32, 32, 32)

# Raymarch configuration.
@export var transmittance_raymarch_steps: int = 40
@export var ms_dir_samples: int = 8
@export var ms_raymarch_steps: int = 20
@export var skyview_raymarch_steps: int = 20
@export var ap_raymarch_steps: int = 20

@export_group("Debug")
@export var debug_draw: bool:
	set(v):
		debug_draw = v
		$DebugView.visible = v

# Debug TextureRects.
@onready var _transmittance_rect := $DebugView/Transmittance
@onready var _ms_rect := $DebugView/MultipleScattering
@onready var _skyview_rect := $DebugView/SkyView
var _transmittance_texture := Texture2DRD.new()
var _ms_texture := Texture2DRD.new()
var _skyview_texture := Texture2DRD.new()
var _ap_texture := Texture3DRD.new()

var rctx: RenderContext

func _ready() -> void:
	set_process(update_params_in_process)
	_initialize_debug_rects()
	RenderingServer.call_on_render_thread(_initialize_compute_resources)

func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rctx != null:
			rctx.free()

func _initialize_debug_rects() -> void:
	# Reassign to have the setter activate.
	debug_draw = debug_draw
	_transmittance_rect.texture = _transmittance_texture
	_transmittance_rect.size = transmittance_lut_size
	_transmittance_rect.position = Vector2.ZERO
	_ms_rect.texture = _ms_texture
	_ms_rect.size = ms_lut_size
	_ms_rect.position = Vector2(_transmittance_rect.position.x + _transmittance_rect.size.x + 1, 0)
	_skyview_rect.texture = _skyview_texture
	_skyview_rect.size = skyview_lut_size
	_skyview_rect.position = Vector2(_ms_rect.position.x + _ms_rect.size.x + 1, 0)

func _is_aerial_perspective_compositor_effect(v: Variant) -> bool:
	return v is AerialPerspective

func _process(_delta: float) -> void:
	update_atmosphere_params()

# Updates all relevant atmosphere properties once relevant properties have been updated.
# Normally just called from _process, but can
func update_atmosphere_params() -> void:
	# Special case when the 'Atmosphere' scene is open. Required attributes can't possibly be wired
	# up, so we exit early to avoid logspam.
	if self == get_tree().edited_scene_root:
		return

	if directional_light == null:
		push_error("Atmosphere needs a directional light hooked up")
		return
	if world_environment == null:
		push_error("Atmosphere needs a WorldEnvironment hooked up")
		return

	# Update sky shader parameters.
	if world_environment.environment.sky.sky_material is not ShaderMaterial:
		push_error("Sky material must be the atmosphere shader material")
		return

	var sky_material: ShaderMaterial = world_environment.environment.sky.sky_material
	sky_material.set_shader_parameter("sky_luminance_multiplier", sky_luminance_color * sky_luminance_scale)
	sky_material.set_shader_parameter("sun_angular_diameter", deg_to_rad(sun_angular_diameter_degrees))
	sky_material.set_shader_parameter("limb_darkening", limb_darkening)
	sky_material.set_shader_parameter("ground_radius_km", ground_radius_km)
	sky_material.set_shader_parameter("atmosphere_thickness_km", atmosphere_thickness_km)
	sky_material.set_shader_parameter("skyview_lut", _skyview_texture)
	sky_material.set_shader_parameter("transmittance_lut", _transmittance_texture)

	# Trigger the render updates.
	var camera := get_viewport().get_camera_3d()
	if Engine.is_editor_hint():
		camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var camera_transform := camera.global_transform
	var inv_projection := camera.get_camera_projection().inverse()
	var sun_direction := directional_light.quaternion * Vector3.BACK

	RenderingServer.call_on_render_thread(_render_process.bind(camera_transform, inv_projection, sun_direction))

	var idx := world_environment.compositor.compositor_effects.find_custom(_is_aerial_perspective_compositor_effect)
	if idx == null:
		push_error("Atmosphere needs an AerialPerspective CompositorEffect registered for aerial perspective")
		return

	var ap_compositor_effect: AerialPerspective = world_environment.compositor.compositor_effects[idx]
	ap_compositor_effect.max_distance_km = max_ap_distance_km
	ap_compositor_effect.luminance_multiplier = ap_luminance_color * ap_luminance_scale
	ap_compositor_effect.inv_projection = inv_projection
	ap_compositor_effect.ap_lut = ap_lut


## Render thread code.
##

# Local thread group size.
const TEXTURE_FORMAT := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT

# This size has to match the struct definition of CameraParams, per std140 rules.
const CAMERA_PARAMS_BYTES = BytePacker.Alignment.VEC3 + BytePacker.Alignment.MAT3 + BytePacker.Alignment.MAT4 + BytePacker.Alignment.VEC3
# This size has to match the struct definition of AtmosphereParams, per std430 rules.
const ATMOSPHERE_PARAMS_BYTES = 4 * BytePacker.Alignment.FLOAT + 5 * BytePacker.Alignment.VEC3

var rd: RenderingDevice

var camera_params_byte_array: PackedByteArray = PackedByteArray()
var camera_params_uniform_buffer: RID

var atmosphere_params_byte_array: PackedByteArray = PackedByteArray()
var atmosphere_params_storage_buffer: RID

var transmittance_shader: RID
var transmittance_pipeline: RID
var transmittance_lut: RID
var transmittance_uniform_set: RID
var transmittance_sampler: RID

var ms_shader: RID
var ms_pipeline: RID
var ms_lut: RID
var ms_uniform_set: RID
var ms_sampler: RID

var skyview_shader: RID
var skyview_pipeline: RID
var skyview_lut: RID
var skyview_uniform_set: RID

var ap_shader: RID
var ap_pipeline: RID
var ap_lut: RID
var ap_uniform_set: RID

func _update_camera_params_byte_array(array: PackedByteArray, camera_transform: Transform3D, inv_projection: Projection, sun_direction: Vector3) -> void:
	var updater := BytePacker.new(array, false)
	updater.pack_vec3(camera_transform.origin)
	updater.pack_mat3_basis(camera_transform.basis)
	updater.pack_mat4_projection(inv_projection)
	updater.pack_vec3(sun_direction)
	updater.fill_tail_padding()

func _update_atmosphere_params_byte_array(array: PackedByteArray) -> void:
	# Order of field updates must match the order in the AtmosphereParams GLSL struct.
	var updater := BytePacker.new(array)
	updater.pack_float(ground_radius_km)
	updater.pack_float(atmosphere_thickness_km)
	updater.pack_float(mie_g)
	updater.pack_float(ms_contribution)
	updater.pack_vec3(BytePacker.color_to_vec3(ground_albedo))
	updater.pack_vec3(BytePacker.color_to_vec3(rayleigh_scattering_factor) * rayleigh_scattering_scale)
	updater.pack_vec3(BytePacker.color_to_vec3(mie_scattering_factor) * mie_scattering_scale)
	updater.pack_vec3(BytePacker.color_to_vec3(mie_absorption_factor) * mie_absorption_scale)
	updater.pack_vec3(BytePacker.color_to_vec3(ozone_absorption_factor) * ozone_absorption_scale)
	updater.fill_tail_padding()

func _update_camera_params_uniform_buffer(camera_transform: Transform3D, inv_projection: Projection, sun_direction: Vector3) -> void:
	_update_camera_params_byte_array(camera_params_byte_array, camera_transform, inv_projection, sun_direction)
	rd.buffer_update(camera_params_uniform_buffer, 0, camera_params_byte_array.size(), camera_params_byte_array)

func _update_atmosphere_params_storage_buffer() -> void:
	_update_atmosphere_params_byte_array(atmosphere_params_byte_array)
	rd.buffer_update(atmosphere_params_storage_buffer, 0, atmosphere_params_byte_array.size(), atmosphere_params_byte_array)

func _initialize_compute_resources():
	assert(RenderingServer.is_on_render_thread())
	# Use main rendering device, since the atmosphere is part of normal frame rendering.
	rd = RenderingServer.get_rendering_device()
	rctx = RenderContext.new(rd)

	# Shared among the shaders.
	camera_params_byte_array.resize(CAMERA_PARAMS_BYTES)
	camera_params_uniform_buffer = rctx.create_uniform_buffer(camera_params_byte_array)

	atmosphere_params_byte_array.resize(ATMOSPHERE_PARAMS_BYTES)
	atmosphere_params_storage_buffer = rctx.create_storage_buffer(atmosphere_params_byte_array)

	# Transmittance LUT.
	transmittance_shader = rctx.load_compute_shader("res://atmosphere/transmittance_lut.comp")
	transmittance_pipeline = rctx.create_compute_pipeline(transmittance_shader)
	transmittance_lut = rctx.create_texture_2d(transmittance_lut_size, TEXTURE_FORMAT)
	_transmittance_texture.texture_rd_rid = transmittance_lut
	transmittance_uniform_set = rctx.create_uniform_set([
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [transmittance_lut]),
	], transmittance_shader, 0)
	transmittance_sampler = rctx.create_sampler()

	# MS LUT.
	ms_shader = rctx.load_compute_shader("res://atmosphere/ms_lut.comp")
	ms_pipeline = rctx.create_compute_pipeline(ms_shader)
	ms_lut = rctx.create_texture_2d(ms_lut_size, TEXTURE_FORMAT)
	_ms_texture.texture_rd_rid = ms_lut
	ms_uniform_set = rctx.create_uniform_set([
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [ms_lut]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [transmittance_sampler, transmittance_lut]),
	], ms_shader, 0)
	ms_sampler = rctx.create_sampler()

	# Skyview LUT.
	skyview_shader = rctx.load_compute_shader("res://atmosphere/skyview_lut.comp")
	skyview_pipeline = rctx.create_compute_pipeline(skyview_shader)
	skyview_lut = rctx.create_texture_2d(skyview_lut_size, TEXTURE_FORMAT)
	_skyview_texture.texture_rd_rid = skyview_lut
	skyview_uniform_set = rctx.create_uniform_set([
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [camera_params_uniform_buffer]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [skyview_lut]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [transmittance_sampler, transmittance_lut]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [ms_sampler, ms_lut]),
	], skyview_shader, 0)

	# AP LUT.
	ap_shader = rctx.load_compute_shader("res://atmosphere/ap_lut.comp")
	ap_pipeline = rctx.create_compute_pipeline(ap_shader)
	ap_lut = rctx.create_texture_3d(ap_lut_size, TEXTURE_FORMAT)
	_ap_texture.texture_rd_rid = ap_lut
	ap_uniform_set = rctx.create_uniform_set([
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 1, [camera_params_uniform_buffer]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [ap_lut]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [transmittance_sampler, transmittance_lut]),
		rctx.uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [ms_sampler, ms_lut]),
	], ap_shader, 0)

func _encode_transmittance_push_constants() -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := PackedByteArray()
	var updater := BytePacker.new(constants)
	updater.pack_ivec2(transmittance_lut_size)
	updater.pack_int(transmittance_raymarch_steps)
	updater.fill_tail_padding()
	return constants

func _encode_ms_push_constants() -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := PackedByteArray()
	var updater := BytePacker.new(constants)
	updater.pack_ivec2(ms_lut_size)
	updater.pack_int(ms_dir_samples)
	updater.pack_int(ms_raymarch_steps)
	updater.fill_tail_padding()
	return constants

func _encode_skyview_push_constants() -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := PackedByteArray()
	var updater := BytePacker.new(constants)
	updater.pack_ivec2(skyview_lut_size)
	updater.pack_int(skyview_raymarch_steps)
	updater.fill_tail_padding()
	return constants

func _encode_ap_push_constants() -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := PackedByteArray()
	var updater := BytePacker.new(constants)
	updater.pack_ivec3(ap_lut_size)
	updater.pack_int(ap_raymarch_steps)
	updater.pack_float(max_ap_distance_km)
	updater.fill_tail_padding()
	return constants

func _render_process(camera_transform: Transform3D, inv_projection: Projection, sun_direction: Vector3) -> void:
	assert(RenderingServer.is_on_render_thread())

	# Update camera params.
	_update_camera_params_uniform_buffer(camera_transform, inv_projection, sun_direction)

	# Update our params storage buffer with latest param values. As an optimization, this could be
	# skipped if scattering parameters haven't changed (and both the transmittance and MS LUTs
	# wouldn't need to be rebuilt).
	_update_atmosphere_params_storage_buffer()

	var compute_list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(compute_list, transmittance_pipeline)
	var transmittance_push_constants := _encode_transmittance_push_constants()
	rd.compute_list_set_push_constant(compute_list, transmittance_push_constants, transmittance_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, transmittance_uniform_set, 0)
	var transmittance_workgroup_size := RenderContext.workgroup_size_2d(transmittance_lut_size)
	rd.compute_list_dispatch(compute_list, transmittance_workgroup_size.x, transmittance_workgroup_size.y, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, ms_pipeline)
	var ms_push_constants := _encode_ms_push_constants()
	rd.compute_list_set_push_constant(compute_list, ms_push_constants, ms_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, ms_uniform_set, 0)
	var ms_workgroup_size := RenderContext.workgroup_size_2d(ms_lut_size)
	rd.compute_list_dispatch(compute_list, ms_workgroup_size.x, ms_workgroup_size.y, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, skyview_pipeline)
	var skyview_push_constants := _encode_skyview_push_constants()
	rd.compute_list_set_push_constant(compute_list, skyview_push_constants, skyview_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, skyview_uniform_set, 0)
	var skyview_workgroup_size := RenderContext.workgroup_size_2d(skyview_lut_size)
	rd.compute_list_dispatch(compute_list, skyview_workgroup_size.x, skyview_workgroup_size.y, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, ap_pipeline)
	var ap_push_constants := _encode_ap_push_constants()
	rd.compute_list_set_push_constant(compute_list, ap_push_constants, ap_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, ap_uniform_set, 0)
	var ap_workgroup_size := RenderContext.workgroup_size_3d(ap_lut_size)
	rd.compute_list_dispatch(compute_list, ap_workgroup_size.x, ap_workgroup_size.y, ap_workgroup_size.z)

	rd.compute_list_end()

	# We don't need to manually call rd.submit() since we're using the main rendering device;
	# only local devices are allowed to manually submit/sync.
