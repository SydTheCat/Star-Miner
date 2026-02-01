shader_type sky;

// Realistic procedural sky with atmospheric scattering, sun, and stars

// Sun parameters
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform float sun_intensity : hint_range(0.0, 100.0) = 22.0;
uniform float sun_size : hint_range(0.0, 1.0) = 0.04;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.9);

// Atmosphere parameters
uniform float atmosphere_density : hint_range(0.0, 5.0) = 1.0;
uniform float rayleigh_strength : hint_range(0.0, 2.0) = 1.0;
uniform float mie_strength : hint_range(0.0, 2.0) = 0.005;
uniform float mie_g : hint_range(-1.0, 1.0) = 0.76;

// Colors
uniform vec3 rayleigh_color : source_color = vec3(0.26, 0.41, 0.88);
uniform vec3 mie_color : source_color = vec3(1.0, 0.95, 0.85);

// Night sky
uniform float star_intensity : hint_range(0.0, 5.0) = 2.5;
uniform float star_threshold : hint_range(0.0, 1.0) = 0.97;  // Higher = fewer stars
uniform float night_sky_brightness : hint_range(0.0, 0.5) = 0.03;
uniform vec3 night_color : source_color = vec3(0.02, 0.02, 0.06);

// Time (0-1, controls sun position indirectly via sun_direction)
uniform float time_of_day : hint_range(0.0, 1.0) = 0.5;

// Hash function for stars
float hash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// 3D noise for star variation
float noise3d(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    return mix(
        mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
            mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
        mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
            mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y),
        f.z
    );
}

// Generate stars - simple and reliable
float stars(vec3 dir) {
    // Create a grid in the sky
    vec3 p = dir * 200.0;
    vec3 cell = floor(p);
    vec3 local = fract(p) - 0.5;
    
    // Hash to determine if this cell has a star
    float h = hash(cell);
    
    // Only some cells have stars (threshold controls density)
    if (h < star_threshold) {
        return 0.0;
    }
    
    // Star position within cell (slight offset from center)
    vec3 star_offset = vec3(
        hash(cell + vec3(1.0, 0.0, 0.0)) - 0.5,
        hash(cell + vec3(0.0, 1.0, 0.0)) - 0.5,
        hash(cell + vec3(0.0, 0.0, 1.0)) - 0.5
    ) * 0.4;
    
    // Distance from star center
    float dist = length(local - star_offset);
    
    // Sharp star point
    float star_point = 1.0 - smoothstep(0.0, 0.15, dist);
    
    // Brightness variation per star
    float brightness = 0.5 + 0.5 * hash(cell + vec3(42.0));
    
    // Subtle twinkle
    float twinkle = 0.8 + 0.2 * sin(TIME * (1.0 + h * 3.0) + h * 50.0);
    
    return star_point * brightness * twinkle * star_intensity;
}

// Rayleigh phase function
float rayleigh_phase(float cos_theta) {
    return 0.75 * (1.0 + cos_theta * cos_theta);
}

// Mie phase function (Henyey-Greenstein)
float mie_phase(float cos_theta, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * cos_theta;
    return (1.0 - g2) / (4.0 * PI * pow(denom, 1.5));
}

// Atmospheric scattering
vec3 atmosphere(vec3 dir, vec3 sun_dir) {
    // View-sun angle
    float cos_theta = dot(dir, sun_dir);
    
    // Height-based density (simplified)
    float altitude = max(dir.y, 0.0);
    float density = exp(-altitude * 4.0 * atmosphere_density) * atmosphere_density;
    
    // Rayleigh scattering (blue sky)
    float rayleigh = rayleigh_phase(cos_theta) * rayleigh_strength;
    vec3 rayleigh_scatter = rayleigh_color * rayleigh * density;
    
    // Mie scattering (sun glow/haze)
    float mie = mie_phase(cos_theta, mie_g) * mie_strength;
    vec3 mie_scatter = mie_color * mie * density;
    
    // Sun visibility factor (how much sun is above horizon)
    float sun_visibility = smoothstep(-0.1, 0.2, sun_dir.y);
    
    // Combine scattering
    vec3 scatter = (rayleigh_scatter + mie_scatter) * sun_visibility;
    
    // Horizon glow during sunrise/sunset
    float horizon_factor = 1.0 - abs(dir.y);
    horizon_factor = pow(horizon_factor, 3.0);
    
    float sunset_factor = smoothstep(0.0, 0.3, sun_dir.y) * smoothstep(0.5, 0.0, sun_dir.y);
    vec3 sunset_color = vec3(1.0, 0.4, 0.1) * sunset_factor * horizon_factor * 2.0;
    
    return scatter + sunset_color;
}

// Sun disk
vec3 sun_disk(vec3 dir, vec3 sun_dir) {
    float cos_angle = dot(dir, sun_dir);
    
    // Sharp sun disk
    float sun_disk_mask = smoothstep(1.0 - sun_size * 0.01, 1.0 - sun_size * 0.005, cos_angle);
    
    // Soft sun glow
    float sun_glow = pow(max(cos_angle, 0.0), 256.0) * 2.0;
    sun_glow += pow(max(cos_angle, 0.0), 64.0) * 0.5;
    sun_glow += pow(max(cos_angle, 0.0), 16.0) * 0.2;
    
    // Only show sun above horizon
    float sun_above_horizon = smoothstep(-0.05, 0.05, sun_dir.y);
    
    vec3 sun = sun_color * (sun_disk_mask * sun_intensity + sun_glow) * sun_above_horizon;
    
    return sun;
}

// Ground gradient
vec3 ground(vec3 dir, vec3 sun_dir) {
    if (dir.y >= 0.0) {
        return vec3(0.0);
    }
    
    float ground_factor = smoothstep(0.0, -0.4, dir.y);
    
    // Ground color based on sun position
    float sun_up = max(sun_dir.y, 0.0);
    vec3 ground_day = vec3(0.3, 0.25, 0.2);
    vec3 ground_night = vec3(0.02, 0.02, 0.03);
    vec3 ground_color = mix(ground_night, ground_day, sun_up);
    
    return ground_color * ground_factor;
}

void sky() {
    vec3 dir = EYEDIR;
    vec3 sun_dir = normalize(sun_direction);
    
    // Calculate how much it's night (sun below horizon)
    float night_amount = smoothstep(0.1, -0.2, sun_dir.y);
    float day_amount = 1.0 - night_amount;
    
    // Day sky (atmospheric scattering)
    vec3 day_sky = atmosphere(dir, sun_dir);
    
    // Night sky (dark blue + stars)
    vec3 night_sky = night_color * night_sky_brightness;
    if (dir.y > 0.0 && night_amount > 0.0) {
        night_sky += vec3(stars(dir)) * night_amount;
    }
    
    // Blend day and night
    vec3 sky_color = mix(day_sky, night_sky, night_amount * night_amount);
    
    // Add sun
    sky_color += sun_disk(dir, sun_dir);
    
    // Add ground below horizon
    if (dir.y < 0.0) {
        sky_color = ground(dir, sun_dir);
    }
    
    // Horizon blend
    float horizon_blend = smoothstep(-0.02, 0.02, dir.y);
    vec3 horizon_color = mix(ground(vec3(dir.x, -0.01, dir.z), sun_dir), sky_color, horizon_blend);
    
    COLOR = max(horizon_color, vec3(0.0));
}
