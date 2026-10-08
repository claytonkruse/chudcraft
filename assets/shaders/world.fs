#version 330

// fragTexCoord.x is the block column across the quad. fragTexCoord.y is the block
// row plus the atlas tile times 64, so a quad wider than one block can repeat
// inside its own tile instead of sliding into the neighbor.
in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec4 tiles[16];

out vec4 finalColor;

void main() {
    float tile = floor(fragTexCoord.y / 64.0);
    float v = fragTexCoord.y - tile * 64.0;
    float u = fragTexCoord.x;
    float fu = u - floor(u);
    float fv = v - floor(v);
    if (fu == 0.0 && u > 0.0) fu = 1.0;
    if (fv == 0.0 && v > 0.0) fv = 1.0;
    vec4 rect = tiles[int(tile)];
    vec2 uv = rect.xy + vec2(fu, fv) * rect.zw;
    vec4 texel = texture(texture0, uv);
    if (texel.a < 0.5) discard;
    finalColor = texel * colDiffuse * fragColor;
}
