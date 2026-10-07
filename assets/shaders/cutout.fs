#version 330

// Raylib's default fragment shader has no discard, so a fully transparent texel would
// blend instead of vanishing and still write depth, punching a hole in whatever is
// behind it. Throwing the texel away keeps depth writes usable for cutout surfaces.

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

out vec4 finalColor;

void main() {
    vec4 texel = texture(texture0, fragTexCoord);
    if (texel.a < 0.5) discard;
    finalColor = texel*colDiffuse*fragColor;
}
