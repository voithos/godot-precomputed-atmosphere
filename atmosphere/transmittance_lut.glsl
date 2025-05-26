#[compute]
#version 450

// Perform work in 8x8 == 64 local threads. For reference, NVIDIA warps are 32,
// AMD GPUs use 64.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform
    restrict writeonly image2D transmittance_lut;

void main() {
  // TODO: parameterize texture size
  ivec2 texture_size = ivec2(256, 64);
  ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
  if ((texel_coord.x > texture_size.x) || (texel_coord.y > texture_size.y)) {
    return;
  }

  vec4 color = vec4(1.0, 0.0, 1.0, 1.0);
  imageStore(transmittance_lut, texel_coord, color);
}