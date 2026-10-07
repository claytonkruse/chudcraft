#version 330

// Samples land a fraction of a pixel apart, and blending them is what knocks
// the staircase off a silhouette. The inside of a block face is left alone:
// its texels are nearest-filtered, and a color box built from the whole
// neighborhood is wide enough to accept almost anything, which is what smears
// the texture and leaves trails.

uniform sampler2D texture0;
uniform sampler2D depthTex;
uniform sampler2D historyTex;
uniform mat4 invViewProj;
uniform mat4 prevViewProj;
uniform vec2 resolution;
uniform int historyValid;

out vec4 finalColor;

vec3 to_linear(vec3 color) {
    return pow(color, vec3(2.2));
}

vec3 to_gamma(vec3 color) {
    return pow(max(color, vec3(0.0)), vec3(1.0 / 2.2));
}

vec3 rgb_to_ycocg(vec3 color) {
    return vec3(
        dot(color, vec3(0.25, 0.5, 0.25)),
        dot(color, vec3(0.5, 0.0, -0.5)),
        dot(color, vec3(-0.25, 0.5, -0.25))
    );
}

vec3 ycocg_to_rgb(vec3 color) {
    float y = color.x;
    float co = color.y;
    float cg = color.z;
    return vec3(y + co - cg, y + cg, y - co - cg);
}

// Pulls history back onto the segment from the box center when it falls
// outside, instead of clamping each channel and muddying it.
vec3 clip_aabb(vec3 aabb_min, vec3 aabb_max, vec3 color) {
    vec3 center = 0.5 * (aabb_max + aabb_min);
    vec3 extent = max(0.5 * (aabb_max - aabb_min), vec3(1e-5));
    vec3 offset = color - center;
    float t = max(abs(offset.x) / extent.x, max(abs(offset.y) / extent.y, abs(offset.z) / extent.z));
    if (t > 1.0) return center + offset / t;
    return color;
}

// How unlike the neighbor's depth is, relative to how far this pixel is from
// the far plane. A silhouette scores near 1. A texel on the same face does not.
float depth_separation(float depth, float neighbor) {
    return abs(depth - neighbor) / max(1.0 - min(depth, neighbor), 1e-4);
}

void main() {
    ivec2 size = textureSize(texture0, 0);
    ivec2 pixel = clamp(ivec2(gl_FragCoord.xy), ivec2(0), size - 1);

    vec3 current = to_linear(texelFetch(texture0, pixel, 0).rgb);
    vec3 resolved = current;

    // gl_FragCoord is the pixel center, bottom-left origin, same as the depth
    // and color textures. Depth is the window value, not clip z.
    vec2 uv = (vec2(pixel) + 0.5) / resolution;
    float depth = texelFetch(depthTex, pixel, 0).r;

    vec3 current_ycocg = rgb_to_ycocg(current);
    vec3 aabb_min = current_ycocg;
    vec3 aabb_max = current_ycocg;
    bool edge = false;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue;
            ivec2 sample_pixel = clamp(pixel + ivec2(x, y), ivec2(0), size - 1);
            float neighbor_depth = texelFetch(depthTex, sample_pixel, 0).r;
            if (depth_separation(depth, neighbor_depth) < 0.2) continue;
            edge = true;
            vec3 neighbor = rgb_to_ycocg(to_linear(texelFetch(texture0, sample_pixel, 0).rgb));
            aabb_min = min(aabb_min, neighbor);
            aabb_max = max(aabb_max, neighbor);
        }
    }

    if (historyValid != 0) {
        vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
        vec4 world = invViewProj * clip;
        world /= world.w;

        vec4 prev_clip = prevViewProj * vec4(world.xyz, 1.0);
        vec2 prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;

        vec3 history = to_linear(texture(historyTex, prev_uv).rgb);
        float pixels = length((prev_uv - uv) * resolution);
        // A still camera only moves by the jitter, about a pixel. A few pixels
        // of real motion and the outline would trail, so this frame takes over.
        float motion = clamp((pixels - 1.0) / 8.0, 0.0, 1.0);
        float weight = 0.0;
        vec3 blended = current;

        if (edge) {
            blended = ycocg_to_rgb(clip_aabb(aabb_min, aabb_max, rgb_to_ycocg(history)));
            // The jitter swaps a silhouette between two colors. A low weight
            // leaves that swap visible; most of the pixel has to be history.
            weight = 0.9 * (1.0 - motion);
        } else {
            // Same face: average samples that already agree, and leave a texel
            // that does not alone. A wide neighborhood box would accept the
            // neighbor and turn the texture into mush.
            float delta = length(rgb_to_ycocg(history) - current_ycocg);
            float match = 1.0 - clamp((delta - 0.02) / 0.12, 0.0, 1.0);
            blended = history;
            weight = 0.9 * match * (1.0 - motion);
        }

        if (prev_uv.x < 0.0 || prev_uv.y < 0.0 || prev_uv.x > 1.0 || prev_uv.y > 1.0 || prev_clip.w <= 0.0) {
            weight = 0.0;
        }

        resolved = mix(current, blended, weight);
    }

    finalColor = vec4(to_gamma(resolved), 1.0);
}
