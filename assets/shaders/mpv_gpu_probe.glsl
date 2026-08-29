//!HOOK MAIN
//!BIND HOOKED
//!DESC BiliTV libmpv GPU probe

vec4 hook() {
    vec4 color = HOOKED_tex(HOOKED_pos);
    // Deliberate red marker in the upper-right corner. If this marker is
    // visible, the frame passed through libmpv's GLSL hook.
    if (HOOKED_pos.x > 0.86 && HOOKED_pos.y < 0.14) {
        color.rgb = mix(color.rgb, vec3(1.0, 0.05, 0.05), 0.85);
    }
    return color;
}
