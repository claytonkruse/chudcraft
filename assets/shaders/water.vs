#version 330

// Keep this height in step with wave_height in wave.odin. The blocks do not
// move; this displacement is the surface the player and drops also collide with.

in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
in vec3 vertexNormal;
in vec4 vertexColor;

uniform mat4 mvp;
uniform mat4 matModel;
uniform float waveTime;

out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragWorld;
out float fragFoam;

float wave_smooth(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

void wave_height(vec2 xz, float time, float shore, float fetch, out float height, out float foam) {
    float open = wave_smooth(8.0, 14.0, fetch);
    if (open <= 0.0) {
        height = 0.0;
        foam = 0.0;
        return;
    }
    float lip = wave_smooth(0.2, 1.35, shore);
    float offshore = wave_smooth(2.2, 6.5, shore);

    float swell = 0.0;
    swell += sin(xz.x * 0.085 + xz.y * 0.045 - time * 1.15) * 0.16;
    swell += sin(-xz.x * 0.06 + xz.y * 0.11 - time * 0.82) * 0.08;
    swell += sin(xz.x * 0.17 - xz.y * 0.13 - time * 1.70) * 0.04;
    swell *= (0.45 + 0.55 * offshore) * open;

    float seaward = -(xz.x * 0.60 + xz.y * 0.80);
    float k = 0.18 + (1.0 - offshore) * 0.22;
    float phase = seaward * k + time * 1.35;
    float u = phase / 6.28318530718;
    u = u - floor(u);

    float rise = wave_smooth(0.05, 0.72, u);
    float face = wave_smooth(0.55, 0.86, u);
    float crash = 1.0 - wave_smooth(0.80, 0.98, u);
    float shape = rise * crash * 0.85 + face * crash * 0.15 - 0.16;
    float break_env = sin(clamp(shore / 6.5, 0.0, 1.0) * 3.14159265) * open;
    float breaker = shape * 0.40 * break_env;

    height = clamp((swell + breaker) * lip, -0.55, 0.90);
    float crest = wave_smooth(0.62, 0.82, u) * crash;
    float wash = (1.0 - wave_smooth(0.25, 1.8, shore)) * wave_smooth(0.50, 0.82, u);
    foam = clamp(break_env * crest * 1.15 + wash * open, 0.0, 1.0);
}

void main() {
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    vec3 pos = vertexPosition;
    float foam = 0.0;
    // vertexNormal.z marks the free surface. Sides and bottoms stay put,
    // and a block icon has no such flag, so it stays a cube.
    if (vertexNormal.z > 0.5) {
        vec3 world = (matModel * vec4(vertexPosition, 1.0)).xyz;
        float height;
        wave_height(world.xz, waveTime, vertexTexCoord2.x, vertexTexCoord2.y, height, foam);
        pos.y += height;
    }
    fragFoam = foam;
    fragWorld = (matModel * vec4(pos, 1.0)).xyz;
    gl_Position = mvp * vec4(pos, 1.0);
}
