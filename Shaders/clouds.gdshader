shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float cloud_speed : hint_range(0.0, 0.1) = 0.01;
uniform float cloud_scale : hint_range(1.0, 50.0) = 15.0;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_softness : hint_range(0.0, 0.5) = 0.2;
uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 0.9);
uniform float time_offset = 0.0;

// Simple noise functions
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    
    for (int i = 0; i < 5; i++) {
        value += amplitude * noise(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

void fragment() {
    vec2 uv = UV * cloud_scale;
    float time = TIME * cloud_speed + time_offset;
    
    // Animate clouds
    uv.x += time;
    uv.y += time * 0.3;
    
    // Generate cloud pattern
    float n = fbm(uv);
    
    // Apply coverage and softness
    float cloud = smoothstep(cloud_coverage - cloud_softness, cloud_coverage + cloud_softness, n);
    
    ALBEDO = cloud_color.rgb;
    ALPHA = cloud * cloud_color.a;
}
