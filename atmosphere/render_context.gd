extends Object
class_name RenderContext

## RenderingDevice helper that tracks resources being created and helps compile shaders.
## NOTE: Because of a Godot bug, RefCounted cleanup functionality (e.g. PREDELETE) is unreliable,
## see https://github.com/godotengine/godot/issues/31166. Hence, this helper is an Object, which
## means it must be explicitly freed by callers.

# Default local work ground size.
const LOCAL_SIZE := Vector2i(8, 8)

var rd: RenderingDevice
# Track RIDs for cleanup.
var rids: Array[RID] = []

func _init(in_rd: RenderingDevice) -> void:
	rd = in_rd

func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		RenderingServer.call_on_render_thread(_cleanup_compute_resources)

func _cleanup_compute_resources():
	assert(RenderingServer.is_on_render_thread())
	rids.reverse()
	for rid in rids:
		rd.free_rid(rid)

func create_compute_pipeline(shader: RID) -> RID:
	var pipeline := rd.compute_pipeline_create(shader)
	rids.push_back(pipeline)
	return pipeline

func create_uniform_buffer(array: PackedByteArray) -> RID:
	var buffer := rd.uniform_buffer_create(array.size(), array)
	rids.push_back(buffer)
	return buffer

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
static func workgroup_size_2d(texture_size: Vector2i, local_size := LOCAL_SIZE) -> Vector2i:
	# In case texture is not a perfect multiple of LOCAL_SIZE, we compute a slightly larger
	# workgroup size.
	return (texture_size - Vector2i(1, 1)) / local_size + Vector2i(1, 1)

static func workgroup_size_3d(texture_size: Vector3i, local_size := LOCAL_SIZE) -> Vector3i:
	# We assume local size is smaller than a layer of the texture.
	var size_2d := workgroup_size_2d(Vector2i(texture_size.x, texture_size.y), local_size)
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
