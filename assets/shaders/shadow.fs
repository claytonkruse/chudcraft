#version 330

in vec2 fragTexCoord;

uniform sampler2D texture0;
uniform float cutout;

out vec4 finalColor;

// 1 at the near plane packs to zero, which is also the cleared color, so the
// clear reads as "nothing occludes". The receiver subtracts the unpacked value
// from 1 to get the usual window depth.
vec4 packFar(float z) {
    float v = 1.0 - clamp(z, 0.0, 1.0);
    const vec4 bitShift = vec4(1.0, 255.0, 65025.0, 16581375.0);
    const vec4 bitMask = vec4(1.0 / 255.0, 1.0 / 255.0, 1.0 / 255.0, 0.0);
    vec4 res = fract(v * bitShift);
    res -= res.xxyz * bitMask;
    return res;
}

void main() {
    if (cutout > 0.5 && texture(texture0, fragTexCoord).a < 0.5) discard;
    finalColor = packFar(gl_FragCoord.z);
}
