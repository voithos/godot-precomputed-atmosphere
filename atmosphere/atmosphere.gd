@tool
class_name Atmosphere
extends Node3D

@export var directional_light: DirectionalLight3D
@export var world_environment: WorldEnvironment

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

func _ready() -> void:
	_initialize_debug_rects()
	RenderingServer.call_on_render_thread(_initialize_compute_resources)

func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		_cleanup()

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

func _cleanup() -> void:
	RenderingServer.call_on_render_thread(_cleanup_compute_resources)

func _process(_delta: float) -> void:
	# TODO: Ideally this should happen after the camera has been moved, otherwise we'll get a 1 frame delay.
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
	var camera_position := get_viewport().get_camera_3d().global_position
	if Engine.is_editor_hint():
		camera_position = EditorInterface.get_editor_viewport_3d(0).get_camera_3d().global_position
	var sun_direction := directional_light.quaternion * Vector3.BACK
	RenderingServer.call_on_render_thread(_render_process.bind(camera_position, sun_direction))

## Render thread code.
##

# Local thread group size.
const LOCAL_SIZE := Vector2i(8, 8)
const TEXTURE_FORMAT := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
const FLOAT_BYTES = 4
const VEC4_BYTES = FLOAT_BYTES * 4
const VEC3_BYTES = VEC4_BYTES  # std430 mandates that vec3's are aligned like vec4's.
const INT_BYTES = 4
const IVEC2_BYTES = INT_BYTES * 2
const IVEC4_BYTES = INT_BYTES * 4
const IVEC3_BYTES = IVEC4_BYTES  # std430 mandates that vec3's are aligned like vec4's.
# This size has to match the struct definition of AtmosphereParams.
const ATMOSPHERE_PARAMS_BYTES = 4 * FLOAT_BYTES + 5 * VEC3_BYTES
# These sizes have to match the push constants block definitions.
const TRANSMITTANCE_PUSH_CONSTANTS_BYTES = IVEC2_BYTES + INT_BYTES
const MS_PUSH_CONSTANTS_BYTES = IVEC2_BYTES + INT_BYTES * 2
const SKYVIEW_PUSH_CONSTANTS_BYTES = IVEC2_BYTES + INT_BYTES + VEC3_BYTES * 2
# TODO: Some of these are bigger than needed, we're treating alignment bytes as if they were
# storage bytes, which is not correct.
const AP_PUSH_CONSTANTS_BYTES = 48 #IVEC3_BYTES + INT_BYTES + VEC3_BYTES + VEC3_BYTES + FLOAT_BYTES

var rd: RenderingDevice
# Track RIDs for cleanup.
var rids: Array[RID] = []

var atmosphere_params_byte_array: PackedByteArray
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

# Creates an empty packed byte array of the given size, in bytes.
func _create_packed_byte_array_of_size(size: int) -> PackedByteArray:
	var buffer := PackedByteArray()
	for i in range(size):
		buffer.push_back(0)
	return buffer

func _pad_buffer_size_to_vec4(size: int) -> int:
	var misaligned := size % VEC4_BYTES
	if misaligned == 0:
		return size
	return size + (VEC4_BYTES - misaligned)

func _create_atmosphere_params_byte_array() -> PackedByteArray:
	return _create_packed_byte_array_of_size(_pad_buffer_size_to_vec4(ATMOSPHERE_PARAMS_BYTES))

func color_to_vec3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

# Updater for byte arrays that abides by std430 alignment rules.
class ByteArrayUpdater:
	var array: PackedByteArray
	var next_byte_offset := 0
	func _init(input: PackedByteArray) -> void:
		array = input

	func pack_float(v: float) -> void:
		array.encode_float(next_byte_offset, v)
		next_byte_offset += FLOAT_BYTES

	func pack_vec4(v: Vector4) -> void:
		_align_to_byte_offset(VEC4_BYTES)
		pack_float(v.x)
		pack_float(v.y)
		pack_float(v.z)
		pack_float(v.w)

	func pack_vec3(v: Vector3) -> void:
		_align_to_byte_offset(VEC3_BYTES)
		pack_float(v.x)
		pack_float(v.y)
		pack_float(v.z)

	func pack_mat4(v: Projection) -> void:
		# mat4's are aligned as vec4's.
		pack_vec4(v.x)
		pack_vec4(v.y)
		pack_vec4(v.z)
		pack_vec4(v.w)

	func pack_int(v: int) -> void:
		array.encode_s32(next_byte_offset, v)
		next_byte_offset += INT_BYTES

	func pack_ivec2(v: Vector2i) -> void:
		_align_to_byte_offset(IVEC2_BYTES)
		pack_int(v.x)
		pack_int(v.y)

	func pack_ivec3(v: Vector3i) -> void:
		_align_to_byte_offset(IVEC3_BYTES)
		pack_int(v.x)
		pack_int(v.y)
		pack_int(v.z)

	func fill_tail_padding() -> void:
		while next_byte_offset < array.size():
			pack_float(0.0)

	func _align_to_byte_offset(alignment: int) -> void:
		while next_byte_offset % alignment != 0:
			# Float is arbitrary, but a good padding unit.
			pack_float(0.0)

func _update_atmosphere_params_byte_array(array: PackedByteArray) -> void:
	assert(array.size() >= _pad_buffer_size_to_vec4(ATMOSPHERE_PARAMS_BYTES))

	# Order of field updates must match the order in the AtmosphereParams GLSL struct.
	var updater := ByteArrayUpdater.new(array)
	updater.pack_float(ground_radius_km)
	updater.pack_float(atmosphere_thickness_km)
	updater.pack_float(mie_g)
	updater.pack_float(ms_contribution)
	updater.pack_vec3(color_to_vec3(ground_albedo))
	updater.pack_vec3(color_to_vec3(rayleigh_scattering_factor) * rayleigh_scattering_scale)
	updater.pack_vec3(color_to_vec3(mie_scattering_factor) * mie_scattering_scale)
	updater.pack_vec3(color_to_vec3(mie_absorption_factor) * mie_absorption_scale)
	updater.pack_vec3(color_to_vec3(ozone_absorption_factor) * ozone_absorption_scale)
	updater.fill_tail_padding()

func _update_atmosphere_params_storage_buffer() -> void:
	_update_atmosphere_params_byte_array(atmosphere_params_byte_array)
	rd.buffer_update(atmosphere_params_storage_buffer, 0, atmosphere_params_byte_array.size(), atmosphere_params_byte_array)

func _initialize_compute_resources():
	assert(RenderingServer.is_on_render_thread())
	# Use main rendering device, since the atmosphere is part of normal frame rendering.
	rd = RenderingServer.get_rendering_device()

	# Shared among the shaders.
	atmosphere_params_byte_array = _create_atmosphere_params_byte_array()
	atmosphere_params_storage_buffer = create_storage_buffer(atmosphere_params_byte_array)

	# Transmittance LUT.
	transmittance_shader = load_compute_shader("res://atmosphere/transmittance_lut.comp")
	transmittance_pipeline = create_compute_pipeline(transmittance_shader)
	transmittance_lut = create_texture_2d(transmittance_lut_size, TEXTURE_FORMAT)
	_transmittance_texture.texture_rd_rid = transmittance_lut
	transmittance_uniform_set = create_uniform_set([
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [transmittance_lut]),
	], transmittance_shader, 0)
	transmittance_sampler = create_sampler()

	# MS LUT.
	ms_shader = load_compute_shader("res://atmosphere/ms_lut.comp")
	ms_pipeline = create_compute_pipeline(ms_shader)
	ms_lut = create_texture_2d(ms_lut_size, TEXTURE_FORMAT)
	_ms_texture.texture_rd_rid = ms_lut
	ms_uniform_set = create_uniform_set([
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [ms_lut]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [transmittance_sampler, transmittance_lut]),
	], ms_shader, 0)
	ms_sampler = create_sampler()

	# Skyview LUT.
	skyview_shader = load_compute_shader("res://atmosphere/skyview_lut.comp")
	skyview_pipeline = create_compute_pipeline(skyview_shader)
	skyview_lut = create_texture_2d(skyview_lut_size, TEXTURE_FORMAT)
	_skyview_texture.texture_rd_rid = skyview_lut
	skyview_uniform_set = create_uniform_set([
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [skyview_lut]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [transmittance_sampler, transmittance_lut]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [ms_sampler, ms_lut]),
	], skyview_shader, 0)

	# AP LUT.
	ap_shader = load_compute_shader("res://atmosphere/ap_lut.comp")
	ap_pipeline = create_compute_pipeline(ap_shader)
	ap_lut = create_texture_3d(ap_lut_size, TEXTURE_FORMAT)
	_ap_texture.texture_rd_rid = ap_lut
	ap_uniform_set = create_uniform_set([
		uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, [atmosphere_params_storage_buffer]),
		uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [ap_lut]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [transmittance_sampler, transmittance_lut]),
		uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [ms_sampler, ms_lut]),
	], ap_shader, 0)

func _encode_transmittance_push_constants() -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := _create_packed_byte_array_of_size(
		_pad_buffer_size_to_vec4(TRANSMITTANCE_PUSH_CONSTANTS_BYTES))
	var updater := ByteArrayUpdater.new(constants)
	updater.pack_ivec2(transmittance_lut_size)
	updater.pack_int(transmittance_raymarch_steps)
	updater.fill_tail_padding()
	return constants

func _encode_ms_push_constants() -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := _create_packed_byte_array_of_size(
		_pad_buffer_size_to_vec4(MS_PUSH_CONSTANTS_BYTES))
	var updater := ByteArrayUpdater.new(constants)
	updater.pack_ivec2(ms_lut_size)
	updater.pack_int(ms_dir_samples)
	updater.pack_int(ms_raymarch_steps)
	updater.fill_tail_padding()
	return constants

func _encode_skyview_push_constants(camera_position: Vector3, sun_direction: Vector3) -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := _create_packed_byte_array_of_size(
		_pad_buffer_size_to_vec4(SKYVIEW_PUSH_CONSTANTS_BYTES))
	var updater := ByteArrayUpdater.new(constants)
	updater.pack_ivec2(skyview_lut_size)
	updater.pack_int(skyview_raymarch_steps)
	updater.pack_vec3(camera_position)
	updater.pack_vec3(sun_direction)
	updater.fill_tail_padding()
	return constants

func _encode_ap_push_constants(camera_position: Vector3, sun_direction: Vector3) -> PackedByteArray:
	# We push these every frame, and they're quite small, so create a new one.
	var constants := _create_packed_byte_array_of_size(
		_pad_buffer_size_to_vec4(AP_PUSH_CONSTANTS_BYTES))
	var updater := ByteArrayUpdater.new(constants)
	updater.pack_ivec3(ap_lut_size)
	updater.pack_int(ap_raymarch_steps)
	updater.pack_vec3(camera_position)
	updater.pack_vec3(sun_direction)
	updater.pack_float(max_ap_distance_km)
	updater.fill_tail_padding()
	return constants

func _render_process(camera_position: Vector3, sun_direction: Vector3) -> void:
	assert(RenderingServer.is_on_render_thread())

	# Update our params storage buffer with latest param values. As an optimization, this could be
	# skipped if scattering parameters haven't changed (and both the transmittance and MS LUTs
	# wouldn't need to be rebuilt).
	_update_atmosphere_params_storage_buffer()

	var compute_list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(compute_list, transmittance_pipeline)
	var transmittance_push_constants := _encode_transmittance_push_constants()
	rd.compute_list_set_push_constant(compute_list, transmittance_push_constants, transmittance_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, transmittance_uniform_set, 0)
	var transmittance_workgroup_size := workgroup_size(transmittance_lut_size)
	rd.compute_list_dispatch(compute_list, transmittance_workgroup_size.x, transmittance_workgroup_size.y, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, ms_pipeline)
	var ms_push_constants := _encode_ms_push_constants()
	rd.compute_list_set_push_constant(compute_list, ms_push_constants, ms_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, ms_uniform_set, 0)
	var ms_workgroup_size := workgroup_size(ms_lut_size)
	rd.compute_list_dispatch(compute_list, ms_workgroup_size.x, ms_workgroup_size.y, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, skyview_pipeline)
	var skyview_push_constants := _encode_skyview_push_constants(camera_position, sun_direction)
	rd.compute_list_set_push_constant(compute_list, skyview_push_constants, skyview_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, skyview_uniform_set, 0)
	var skyview_workgroup_size := workgroup_size(skyview_lut_size)
	rd.compute_list_dispatch(compute_list, skyview_workgroup_size.x, skyview_workgroup_size.y, 1)

	rd.compute_list_bind_compute_pipeline(compute_list, ap_pipeline)
	var ap_push_constants := _encode_ap_push_constants(camera_position, sun_direction)
	rd.compute_list_set_push_constant(compute_list, ap_push_constants, ap_push_constants.size())
	rd.compute_list_bind_uniform_set(compute_list, ap_uniform_set, 0)
	var ap_workgroup_size := workgroup_size_3d(ap_lut_size)
	rd.compute_list_dispatch(compute_list, ap_workgroup_size.x, ap_workgroup_size.y, ap_workgroup_size.z)

	rd.compute_list_end()

	# We don't need to manually call rd.submit() since we're using the main rendering device;
	# only local devices are allowed to manually submit/sync.

func _cleanup_compute_resources():
	assert(RenderingServer.is_on_render_thread())
	rids.reverse()
	for rid in rids:
		rd.free_rid(rid)

func create_compute_pipeline(shader: RID) -> RID:
	var pipeline := rd.compute_pipeline_create(shader)
	rids.push_back(pipeline)
	return pipeline

func create_storage_buffer(array: PackedByteArray) -> RID:
	var buffer := rd.storage_buffer_create(array.size(), array)
	rids.push_back(buffer)
	return buffer

func uniform(type: RenderingDevice.UniformType, binding: int, ids: Array[RID]) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for rid in ids:
		u.add_id(rid)
	return u

func create_uniform_set(uniforms: Array[RDUniform], shader: RID, shader_set: int) -> RID:
	var uniform_set := rd.uniform_set_create(uniforms, shader, shader_set)
	rids.push_back(uniform_set)
	return uniform_set

func create_texture_2d(size: Vector2i, format: RenderingDevice.DataFormat) -> RID:
	return create_texture(RenderingDevice.TEXTURE_TYPE_2D, Vector3i(size.x, size.y, 1), format)

func create_texture_3d(size: Vector3i, format: RenderingDevice.DataFormat) -> RID:
	return create_texture(RenderingDevice.TEXTURE_TYPE_3D, size, format)

func create_texture(type: RenderingDevice.TextureType, size: Vector3i, format: RenderingDevice.DataFormat) -> RID:
	var tf := RDTextureFormat.new()
	tf.texture_type = type
	tf.format = format
	tf.width = size.x
	tf.height = size.y
	tf.depth = size.z
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

func create_sampler() -> RID:
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	var sampler := rd.sampler_create(ss)
	rids.push_back(sampler)
	return sampler

# Returns required workgroup size to process a given texture, given configured LOCAL_SIZE.
func workgroup_size(texture_size: Vector2i) -> Vector2i:
	# In case texture is not a perfect multiple of LOCAL_SIZE, we compute a slightly larger
	# workgroup size.
	return (texture_size - Vector2i(1, 1)) / LOCAL_SIZE + Vector2i(1, 1)

func workgroup_size_3d(texture_size: Vector3i) -> Vector3i:
	# We assume local size is smaller than a layer of the texture.
	var size_2d := workgroup_size(Vector2i(texture_size.x, texture_size.y))
	return Vector3i(size_2d.x, size_2d.y, texture_size.z)

# Loads and compiles a compute shader from the given path.
func load_compute_shader(file_path: String) -> RID:
	var shader_text := expand_shader(file_path)
	var shader_source := RDShaderSource.new()
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, shader_text)
	var shader_spirv := rd.shader_compile_spirv_from_source(shader_source)
	assert(shader_spirv.compile_error_compute.is_empty(), "Shader compilation error: " + shader_spirv.compile_error_compute)
	var shader := rd.shader_create_from_spirv(shader_spirv)
	rids.push_back(shader)
	return shader

# Reads and expands #includes in the shader source. Godot's existing glsl #include functionality is
# buggy, see https://github.com/godotengine/godot/issues/76024.
# To avoid the editor complaining about your shaders, you can use file extensions that Godot doesn't
# look for, like `.comp` for compute shaders, and `.glsl.inc` for included GLSL snippets.
func expand_shader(file_path: String) -> String:
	var shader_text := read_file(file_path)
	var regex := RegEx.new()
	# Muti-line regex for includes. We use a pragma to avoid clashing with the built in #include scheme.
	regex.compile("(?m)^\\s*#pragma\\s+include\\s+\"(.*)\"")
	# Safety net, in case we include a file that includes itself recursively.
	const MAX_RUNS := 100
	var runs := 0
	while true:
		runs += 1
		if runs > MAX_RUNS:
			printerr("Exceeded maximum iterations while expanding shader, is there a circular include? Expanded source: ", shader_text.substr(0, 1000))
			return ""
		# We don't need to track a start index because we repeatedly search until we run out of
		# substrings to replace.
		var result := regex.search(shader_text)
		if !result:
			# We're done.
			break
		var include_path := result.get_string(1)
		var included_snippet := read_file(include_path)
		shader_text = string_replace(shader_text, included_snippet, result.get_start(), result.get_end())
	return shader_text

# Replaces the substring in str between [from, to] inclusive with the given replacement.
func string_replace(string: String, replacement: String, from: int, to: int) -> String:
	return string.substr(0, from) + replacement + string.substr(to + 1)

func read_file(file_path: String) -> String:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		printerr("Could not open file: ", file_path, ", Error: ", FileAccess.get_open_error())
		return ""
	var content := file.get_as_text()
	file.close()
	return content
