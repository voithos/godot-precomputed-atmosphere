shader_type sky;

// Multiplier for sky luminance, on top of light color/intensity.
uniform vec3 sky_luminance_multiplier : source_color;
// Angular size of the sun in radians. We use this instead of LIGHT0_SIZE since
// the latter also affects shadow softness.
uniform float sun_angular_diameter : hint_range(0, 3.14);
// The configured ground radius.
uniform float ground_radius_km;

// The actual skyview LUT! We disable repeat since the vertical axis maps
// [0, 1] to [nadir, zenith] respectively. This does mean that repeat is
// disabled for the horizontal axis as well, which is unfortunate, but the sky
// is fairly uniform so it's not the worst.
uniform sampler2D skyview_lut : hint_default_black, repeat_disable;

const float EPSILON = 0.0001;

vec3 sample_skyview_lut(float height_km, vec3 eye_dir) {
	const vec3 UP = vec3(0, 1, 0);
	const vec3 RIGHT = vec3(1, 0, 0);
	const vec3 FORWARD = vec3(0, 0, -1);

	vec2 uv;
	// Determine azimuth. Remove the up component.
	float azimuth = 0.0;
	if (abs(eye_dir.y) < (1.0 - EPSILON)) {
		vec3 planar_dir = normalize(eye_dir * vec3(1, 0, 1));
		float sin_theta = dot(planar_dir, RIGHT);
		float cos_theta = dot(planar_dir, FORWARD);
		azimuth = atan(sin_theta, cos_theta);
	}
	uv.x = (azimuth / (2.0 * PI)) - 0.75;

	// Determine altitude. We adjust for the horizon angle so that the we always
	// sample the horizon at uv.y == 0.5.
	float radius_km = height_km + ground_radius_km;
	float horizon_dist = sqrt(radius_km * radius_km - ground_radius_km * ground_radius_km);
	float horizon_angle = acos(horizon_dist / radius_km);
	float ray_angle = acos(dot(eye_dir, -UP));
	float altitude = ray_angle - horizon_angle;

	// Nonlinear mapping of altitude. See section 5.3 of the paper.
	uv.y = 0.5 + 0.5 * sign(altitude) * sqrt(abs(altitude) * 2.0 / PI);
	return texture(skyview_lut, uv).rgb;
}

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

vec3 sun_disk(vec3 eye_pos, vec3 eye_dir) {
	float cos_theta = dot(LIGHT0_DIRECTION, eye_dir);
	if (cos_theta <= cos(sun_angular_diameter)) {
		return vec3(0.0);
	}
	float earth_dist = sphere_intersect_dist(
		eye_pos + vec3(0.0, ground_radius_km, 0.0), eye_dir, ground_radius_km);
	if (earth_dist >= 0.0) {
		// Earth intersection, means the sun disk is below the horizon.
		return vec3(0.0);
	}
	return LIGHT0_COLOR * LIGHT0_ENERGY;
}

void sky() {
	vec3 luminance = vec3(0.0);
	if (LIGHT0_ENABLED) {
		// Treat y=0 as the surface of the ground, so clamp position to a small
		// number if the camera is "underground".
		vec3 pos_km = POSITION * 1e-3;
		pos_km.y = max(pos_km.y, 0.1);
		luminance = sample_skyview_lut(pos_km.y, EYEDIR);
		luminance += sun_disk(pos_km, EYEDIR);
	}
	luminance *= sky_luminance_multiplier;
	COLOR = luminance;
}
