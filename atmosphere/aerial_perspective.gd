#@tool
extends CompositorEffect
class_name AerialPerspective

var rd: RenderingDevice
var rctx: RenderContext

var shader: RID
var pipeline: RID
var sampler: RID

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# Use main rendering device, since the atmosphere is part of normal frame rendering.
	rd = RenderingServer.get_rendering_device()
	rctx = RenderContext.new(rd)

func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rctx != null:
			rctx.free()

func _init_shader() -> bool:
	assert(RenderingServer.is_on_render_thread())
	if !rd or !rctx:
		return false
	if pipeline.is_valid():
		# Already initialized.
		return true

	shader = rctx.load_compute_shader("res://atmosphere/ap_post_process.comp")
	pipeline = rctx.create_compute_pipeline(shader)
	# We need a sampler in order to sample the depth buffer, since you can't imageLoad/Store depth
	# textures in a compute shader.
	sampler = rctx.create_sampler(RenderingDevice.SAMPLER_FILTER_NEAREST, RenderingDevice.SAMPLER_FILTER_NEAREST)
	return pipeline.is_valid()

# Called by the rendering thread every frame.
func _render_callback(p_effect_callback_type: EffectCallbackType, p_render_data: RenderData):
	if rd and p_effect_callback_type == EFFECT_CALLBACK_TYPE_POST_TRANSPARENT and _init_shader():
		# Get our render scene buffers object, this gives us access to our render buffers.
		# Note that implementation differs per renderer hence the need for the cast.
		var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var texture_size := render_scene_buffers.get_internal_size()
			if texture_size.x == 0 and texture_size.y == 0:
				# What's going on here?
				return

			# We can use a compute shader here.
			var workgroup_size := RenderContext.workgroup_size_2d(texture_size)

			# Push constant.
			var push_constants := PackedByteArray()
			var packer := BytePacker.new(push_constants)
			packer.pack_ivec2(texture_size)
			packer.fill_tail_padding()

			# Loop through views just in case we're doing stereo rendering. No extra cost if this is mono.
			var view_count := render_scene_buffers.get_view_count()
			for view in range(view_count):
				# Get the RID for our color image, we will be reading from and writing to it.
				var color_image := render_scene_buffers.get_color_layer(view)
				var depth_image := render_scene_buffers.get_depth_layer(view)

				# Create a uniform set. It's important that we do this every frame instead of using the RenderContext API,
				# since this uniform set will have to change if the color buffer changes.
				var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [
					rctx.uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color_image]),
					rctx.uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [sampler, depth_image]),
				])

				# Run our compute shader.
				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
				rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
				rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
				rd.compute_list_dispatch(compute_list, workgroup_size.x, workgroup_size.y, 1)
				rd.compute_list_end()
