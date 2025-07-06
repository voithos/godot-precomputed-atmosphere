extends RefCounted
class_name BytePacker

## Packer and updater for byte arrays that abides by std140 or std430 alignment rules (somewhat).
## Note that this doesn't handle nested structs, nor arrays.

class Alignment:
	const FLOAT = 4
	const VEC2 = FLOAT * 2
	const VEC3 = FLOAT * 4  # std430 mandates that vec3's are aligned like vec4's.
	const VEC4 = FLOAT * 4

	const INT = 4
	const IVEC2 = INT * 2
	const IVEC3 = INT * 4  # std430 mandates that vec3's are aligned like vec4's.
	const IVEC4 = INT * 4

	const MAT3 = VEC4 * 3
	const MAT4 = VEC4 * 4

const FLOAT_BYTES = 4
const INT_BYTES = 4


var array: PackedByteArray
var next_byte_offset := 0
# Smallest alignment unit. Also works for ints.
var strictest_alignment := Alignment.FLOAT
var std430 := true

func _init(input: PackedByteArray, is_std430: bool = true) -> void:
	array = input
	std430 = is_std430

func pack_float(v: float) -> void:
	_maybe_expand_byte_array()
	array.encode_float(next_byte_offset, v)
	next_byte_offset += FLOAT_BYTES

func pack_vec2(v: Vector2) -> void:
	_align_to_byte_offset(Alignment.VEC2)
	pack_float(v.x)
	pack_float(v.y)
	_align_if_std140(Alignment.VEC2)

func pack_vec3(v: Vector3) -> void:
	_align_to_byte_offset(Alignment.VEC3)
	pack_float(v.x)
	pack_float(v.y)
	pack_float(v.z)
	_align_if_std140(Alignment.VEC3)

func pack_vec4(v: Vector4) -> void:
	_align_to_byte_offset(Alignment.VEC4)
	pack_float(v.x)
	pack_float(v.y)
	pack_float(v.z)
	pack_float(v.w)
	_align_if_std140(Alignment.VEC4)

func pack_mat3_basis(v: Basis) -> void:
	pack_vec3(v.x)
	pack_vec3(v.y)
	pack_vec3(v.z)

func pack_mat4_projection(v: Projection) -> void:
	# mat4's are aligned as vec4's.
	pack_vec4(v.x)
	pack_vec4(v.y)
	pack_vec4(v.z)
	pack_vec4(v.w)

func pack_mat4_transform(v: Transform3D) -> void:
	# mat4's are aligned as vec4's.
	pack_vec4(Vector4(v.basis.x.x, v.basis.x.y, v.basis.x.z, 0.0))
	pack_vec4(Vector4(v.basis.y.x, v.basis.y.y, v.basis.y.z, 0.0))
	pack_vec4(Vector4(v.basis.z.x, v.basis.z.y, v.basis.z.z, 0.0))
	pack_vec4(Vector4(v.origin.x, v.origin.y, v.origin.z, 1.0))

func pack_int(v: int) -> void:
	_maybe_expand_byte_array()
	array.encode_s32(next_byte_offset, v)
	next_byte_offset += INT_BYTES

func pack_ivec2(v: Vector2i) -> void:
	_align_to_byte_offset(Alignment.IVEC2)
	pack_int(v.x)
	pack_int(v.y)
	_align_if_std140(Alignment.IVEC2)

func pack_ivec3(v: Vector3i) -> void:
	_align_to_byte_offset(Alignment.IVEC3)
	pack_int(v.x)
	pack_int(v.y)
	pack_int(v.z)
	_align_if_std140(Alignment.IVEC3)

func pack_ivec4(v: Vector4i) -> void:
	_align_to_byte_offset(Alignment.IVEC4)
	pack_int(v.x)
	pack_int(v.y)
	pack_int(v.z)
	pack_int(v.w)
	_align_if_std140(Alignment.IVEC4)

# std430 mandates that structs are aligned to their largest member, so this fills the tail in
# order to abide by it. Note that this doesn't handle aligning the struct start.
func fill_tail_padding() -> void:
	# We simply align to the strictest alignment we've seen so far.
	_align_to_byte_offset(strictest_alignment)

func _align_to_byte_offset(alignment: int) -> void:
	# Keep track of the strictest alignment rules we've encountered.
	strictest_alignment = max(strictest_alignment, alignment)
	while next_byte_offset % alignment != 0:
		# Float is arbitrary, but a good padding unit.
		pack_float(0.0)

func _align_if_std140(alignment: int) -> void:
	if !std430:
		# std140 conflates size and alignment, so we always pad.
		_align_to_byte_offset(alignment)

func _maybe_expand_byte_array():
	while array.size() < next_byte_offset + FLOAT_BYTES:
		array.push_back(0)

static func color_to_vec3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)
