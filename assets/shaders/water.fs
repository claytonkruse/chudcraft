#version 330

in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragWorld;
in float fragFoam;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

uniform vec3 sunDir;
uniform vec3 moonDir;
uniform vec3 sunColor;
uniform vec3 moonColor;
uniform vec3 ambient;
uniform vec3 skyFill;
uniform vec3 upDir;
uniform mat4 lightVP;
uniform sampler2D shadowMap;
uniform vec2 shadowTexel;
uniform float enableLight;
uniform float useShadow;
uniform float shadowOnSun;

out vec4 finalColor;

float unpackDepth(vec4 rgba) {
    const vec4 bitShift = vec4(1.0, 1.0 / 255.0, 1.0 / 65025.0, 1.0 / 16581375.0);
    return dot(rgba, bitShift);
}

float shadowAt(vec3 world, vec3 normal, float ndl) {
    if (useShadow < 0.5) return 1.0;
    vec4 clip = lightVP * vec4(world + normal * 0.12, 1.0);
    vec3 ndc = clip.xyz / clip.w;
    vec2 uv = ndc.xy * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
    float z = ndc.z * 0.5 + 0.5;
    float bias = 0.002 + 0.006 * (1.0 - clamp(ndl, 0.0, 1.0));
    float shade = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float occ = 1.0 - unpackDepth(texture(shadowMap, uv + vec2(float(x), float(y)) * shadowTexel));
            shade += z > occ + bias ? 0.0 : 1.0;
        }
    }
    return shade / 9.0;
}

vec3 sunLight(vec3 world) {
    if (enableLight < 0.5) return vec3(1.0);
    vec3 n = cross(dFdx(world), dFdy(world));
    if (dot(n, n) < 1e-10) return ambient;
    n = normalize(n);
    if (!gl_FrontFacing) n = -n;
    float ndl = max(dot(n, sunDir), 0.0);
    float ndm = max(dot(n, moonDir), 0.0);
    float shade = shadowAt(world, n, shadowOnSun > 0.5 ? ndl : ndm);
    float sunShade = shadowOnSun > 0.5 ? shade : 1.0;
    float moonShade = shadowOnSun > 0.5 ? 1.0 : shade;
    float lift = max(dot(n, upDir) - ndl, 0.0);
    return ambient + (sunColor * ndl + skyFill * lift) * sunShade + moonColor * ndm * moonShade;
}

void main() {
    vec4 texel = texture(texture0, fragTexCoord);
    finalColor = texel * colDiffuse * fragColor;
    finalColor.rgb *= sunLight(fragWorld);
    // The crest whitens as it pitches, and the lip stays white where the
    // wave has already collapsed onto the bank.
    float foam = clamp(fragFoam, 0.0, 1.0);
    finalColor.rgb = mix(finalColor.rgb, vec3(0.78, 0.86, 0.88), foam);
    finalColor.a = mix(finalColor.a, 1.0, foam * 0.65);
}
