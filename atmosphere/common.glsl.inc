#ifndef ATMOSPHERE_COMMON_INC
#define ATMOSPHERE_COMMON_INC
// Common parameters and logic for atmospheric scattering.

// Want high precision floats due to distances involved.
precision highp float;

const float PI = 3.1415926535897932384626433832795;

float saturate(float v) { return clamp(v, 0.0, 1.0); }

// Define up vector to align with Godot's +Y convention.
const vec3 UP = vec3(0.0, 1.0, 0.0);

// Segment offset in the range (0, 1) exclusive, to avoid sampling at segment
// edges. Specific value seems arbitrary, but was taken from example
// implementations.
const float OFFSET_SEGMENT_T = 0.3;
const float OFFSET_SAMPLE_THETA = 0.3;
const float OFFSET_SAMPLE_PHI = 0.5;

// Rayleigh and mie scattering have a max height before they stop having an
// effect.
const float RAYLEIGH_MAX_HEIGHT_KM = 8.0;
const float MIE_MAX_HEIGHT_KM = 1.2;

// Ozone absorption peaks at a specific height, and falls off around it.
const float OZONE_PEAK_ABSORPTION_HEIGHT_KM = 40.179;
const float OZONE_ABSORPTION_FALLOFF_KM = 17.83;

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

float safe_acos(const float x) { return acos(clamp(x, -1.0, 1.0)); }

// Converts cosine to sine, based on the identity
// sin^2(theta) + cos^2(theta) = 1.
float cos_to_sin(const float cos_theta) {
  return sqrt(1.0 - cos_theta * cos_theta);
}

struct ZenithAngleHeight {
  // The cosine of the sun's zenith angle.
  float cos_zenith_angle;
  // Height above ground.
  float height_km;
};

// Maps a UV in the range [0, 1] to the sun's zenith angle (x) and height above
// ground (y) based on atmosphere thickness.
ZenithAngleHeight uv_to_zenith_angle_height(vec2 uv,
                                            float atmosphere_thickness_km) {
  ZenithAngleHeight res;
  res.cos_zenith_angle = 2.0 * uv.x - 1.0;
  res.height_km = atmosphere_thickness_km * uv.y;
  return res;
}

// Maps a zenith angle + height above ground to a corresponding UV coordinate
// that can be used for sampling LUTs.
vec2 zenith_angle_height_to_uv(ZenithAngleHeight zah,
                               float atmosphere_thickness_km) {
  float u = saturate(0.5 + 0.5 * zah.cos_zenith_angle);
  float v = saturate(zah.height_km / atmosphere_thickness_km);
  return vec2(u, v);
}

// Samples the given LUT based on position and sun parameters.
vec3 sample_zenith_angle_height_lut(sampler2D lut, vec3 pos, vec3 sun_dir,
                                    float ground_radius_km,
                                    float atmosphere_thickness_km) {
  ZenithAngleHeight zah;
  zah.cos_zenith_angle = dot(sun_dir, UP);
  zah.height_km = length(pos) - ground_radius_km;
  vec2 uv = zenith_angle_height_to_uv(zah, atmosphere_thickness_km);
  return texture(lut, uv).rgb;
}

struct AzAlt {
  // Azimuth angle, [-PI, PI].
  float azimuth;
  // Altitude angle.
  float altitude;
};

// Computes an azimuth-altitude angle based on UVs. Uses a nonlinear mapping
// relative to texture UVs in order to concentrate more texels near the horizon
AzAlt uv_to_az_alt(vec2 uv, float height_km, float ground_radius_km) {
  AzAlt aa;
  // Map [0, 1] to [-PI, PI].
  aa.azimuth = (uv.x - 0.5) * 2.0 * PI;

  float linear_v = 2.0 * uv.y - 1.0;
  float nonlinear_v = linear_v * linear_v * sign(linear_v);

  float radius_km = height_km + ground_radius_km;
  float horizon_dist =
      sqrt(radius_km * radius_km - ground_radius_km * ground_radius_km);
  float horizon_angle = 0.5 * PI - safe_acos(horizon_dist / radius_km);
  aa.altitude = linear_v * 0.5 * PI - horizon_angle;
  return aa;
}

// Computes ray intersection with a sphere and returns the distance. ra is
// the radius of the sphere (assumed to be at origin). If the ray is inside
// the sphere, returns the positive distance to the edge of the sphere.
// Returns a negative value if there is no intersection.
float sphere_intersect_dist(vec3 ro, vec3 rd, float ra) {
  float b = dot(ro, rd);
  float c = dot(ro, ro) - ra * ra;
  if (c > 0.0 && b > 0.0)
    return -1.0;
  float discr = b * b - c;
  if (discr < 0.0)
    return -1.0;
  // Use far discriminant if we're inside the sphere.
  if (discr > b * b)
    return (-b + sqrt(discr));
  return -b - sqrt(discr);
}

struct SphereHit {
  float entry;
  float exit;
};

// Computes ray intersection with a sphere and returns the entry/exit points. ra
// is the radius of the sphere (at origin). If the ray origin is inside the
// sphere, 'entry' will be negative. If there is no intersection, 'exit' will be
// negative.
SphereHit sphere_intersect(vec3 ro, vec3 rd, float ra) {
  float b = dot(ro, rd);
  float c = dot(ro, ro) - ra * ra;
  float h = b * b - c;
  if (h < 0.0)
    return SphereHit(-1.0, -1.0); // No hit.
  h = sqrt(h);
  return SphereHit(-b - h, -b + h);
}

// Rayleigh phase function for a given cosine of scattering angle.
float rayleigh_phase(float cos_theta) {
  const float RAYLEIGH_FACTOR = 3.0 / (16.0 * PI);
  return RAYLEIGH_FACTOR * (1.0 + cos_theta * cos_theta);
}

// Cornette-Shanks phase function for Mie scattering.
float mie_phase(float cos_theta, float mie_g) {
  const float MIE_SCALE = 3.0 / (8.0 * PI);
  float num = (1.0 - mie_g * mie_g) * (1.0 + cos_theta * cos_theta);
  float denom = (2.0 + mie_g * mie_g) *
                pow((1.0 + mie_g * mie_g - 2.0 * mie_g * cos_theta), 1.5);
  return MIE_SCALE * num / denom;
}

// Scattering values computed at a specific height.
struct Scattering {
  vec3 rayleigh;
  vec3 mie;
  // Extinction is a combination of rayleigh/mie scattering in addition to mie
  // and ozone absorption.
  vec3 extinction;
};

// Computes scattering and extinction factors for a given height in atmosphere.
Scattering scattering(float height_km, AtmosphereParams params) {
  Scattering s;
  // Compute scattering.
  float rayleigh_density = exp(-height_km / RAYLEIGH_MAX_HEIGHT_KM);
  float mie_density = exp(-height_km / MIE_MAX_HEIGHT_KM);
  s.rayleigh = params.rayleigh_scattering_coefficient * rayleigh_density;
  s.mie = params.mie_scattering_coefficient * mie_density;

  // Compute extinction factors.
  vec3 mie_absorption = params.mie_absorption_coefficient * mie_density;
  // Approximate ozone peak+falloff with a linear coefficient.
  float ozone_density =
      max(1.0 - abs(height_km - OZONE_PEAK_ABSORPTION_HEIGHT_KM) /
                    OZONE_ABSORPTION_FALLOFF_KM,
          0.0);
  vec3 ozone_absorption = params.ozone_absorption_coefficient * ozone_density;
  s.extinction = s.rayleigh + s.mie + mie_absorption + ozone_absorption;
  return s;
}

struct SkyResult {
  vec3 luminance;
  vec3 transmittance;
};

// Raymarch sky luminance from a starting position and ray dir, based on
// precomputed transmittance and multiple-scattering LUTs.
SkyResult raymarch_sky(vec3 pos, vec3 ray_dir, vec3 sun_dir, int raymarch_steps,
                       AtmosphereParams params, sampler2D transmittance_lut,
                       sampler2D ms_lut) {
  SkyResult sky;
  sky.luminance = vec3(0.0);
  sky.transmittance = vec3(1.0);

  SphereHit atmo_hit = sphere_intersect(
      pos, ray_dir, params.ground_radius_km + params.atmosphere_thickness_km);
  if (atmo_hit.exit < 0.0) {
    // No hit.
    return sky;
  }
  float from_dist = max(atmo_hit.entry, 0.0);
  float to_dist = atmo_hit.exit;

  float ground_dist =
      sphere_intersect_dist(pos, ray_dir, params.ground_radius_km);
  if (ground_dist > 0.0) {
    to_dist = ground_dist;
  }

  // Start marching!
  vec3 start_pos = pos + from_dist * ray_dir;
  float ray_cos_theta = dot(ray_dir, sun_dir);
  float rayleigh_phase_v = rayleigh_phase(ray_cos_theta);
  float mie_phase_v = mie_phase(ray_cos_theta, params.mie_g);

  float t = 0.0;
  float t_max = to_dist - from_dist;
  for (int i = 0; i < raymarch_steps; i++) {
    float next_t =
        ((float(i) + OFFSET_SEGMENT_T) / float(raymarch_steps)) * t_max;
    float dt = next_t - t;
    t = next_t;

    vec3 sample_pos = start_pos + t * ray_dir;
    float height_km = length(sample_pos) - params.ground_radius_km;

    Scattering s = scattering(height_km, params);

    vec3 sample_transmittance = exp(-dt * s.extinction);
    vec3 sun_transmittance = sample_zenith_angle_height_lut(
        transmittance_lut, sample_pos, sun_dir, params.ground_radius_km,
        params.atmosphere_thickness_km);

    // Add multiple scattering contribution.
    vec3 psi_ms = sample_zenith_angle_height_lut(
                      ms_lut, sample_pos, sun_dir, params.ground_radius_km,
                      params.atmosphere_thickness_km) *
                  params.ms_contribution;

    // We apply the MS contribution to the base scattering.
    vec3 rayleigh_inscattering =
        s.rayleigh * (rayleigh_phase_v * sun_transmittance + psi_ms);
    vec3 mie_inscattering = s.mie * (mie_phase_v * sun_transmittance + psi_ms);
    vec3 inscattering = rayleigh_inscattering + mie_inscattering;

    vec3 scattering_integral =
        (inscattering - inscattering * sample_transmittance) / s.extinction;

    sky.luminance += scattering_integral * sky.transmittance;
    sky.transmittance *= sample_transmittance;
  }
  return sky;
}

#endif