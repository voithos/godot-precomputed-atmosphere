#ifndef ATMOSPHERE_COMMON_INC
#define ATMOSPHERE_COMMON_INC
// Common parameters and logic for atmospheric scattering.

// Want high precision floats due to distances involved.
precision highp float;

// Common atmospheric scattering parameters. These are expected to be loaded
// from a storage buffer, so the parameter order is intentionally made to
// minimize padding (std430 alignment, vec4 / 16 bytes).
// The vec3's all take up 16 bytes due to alignment.
struct AtmosphereParams {
  float ground_radius_km;
  float atmosphere_thickness_km;
  float mie_g;
  float ms_contribution;
  vec3 ground_albedo;
  vec3 rayleigh_scattering_coefficient;
  vec3 mie_scattering_coefficient;
  vec3 mie_absorption_coefficient;
  vec3 ozone_absorption_coefficient;
};

vec2 texel_center_uv(ivec2 texel_coord, ivec2 texture_size) {
  return (vec2(texel_coord) + 0.5) / vec2(texture_size);
}

bool out_of_bounds(ivec2 texel_coord, ivec2 texture_size) {
  return (texel_coord.x > texture_size.x) || (texel_coord.y > texture_size.y);
}
#endif