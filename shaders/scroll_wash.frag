#version 440
// a blurred cover behind a scrolling panel: it moves up with what scrolls,
// fading out downwards as it goes, while the panel's own rounded top, given
// as a mask that stays put, keeps it inside the panel's corners.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // how far it has scrolled, as a share of its height
    float shift;
};

layout(binding = 1) uniform sampler2D source;
layout(binding = 2) uniform sampler2D mask;

void main()
{
    float y = qt_TexCoord0.y + shift;
    // full at the top, a little less by the middle, nothing at the bottom
    float fade = y < 0.55 ? mix(1.0, 0.8, y / 0.55) : mix(0.8, 0.0, clamp((y - 0.55) / 0.45, 0.0, 1.0));
    vec4 colour = y < 1.0 ? texture(source, vec2(qt_TexCoord0.x, y)) : vec4(0.0);
    fragColor = colour * (fade * texture(mask, qt_TexCoord0).a * qt_Opacity);
}
