// WiVRn color adjustment, GPL-3.0-or-later.
vec3 apply_vibrance(vec3 color, float amount)
{
    if (amount <= 0.0)
        return color;
    vec3 c = clamp(color, 0.0, 1.0);
    float brightest = max(c.r, max(c.g, c.b));
    float darkest = min(c.r, min(c.g, c.b));
    float saturation = brightest > 0.0 ? (brightest - darkest) / brightest : 0.0;
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    vec3 chroma = c - vec3(luma);
    float gain = 1.0 + clamp(amount, 0.0, 1.0) * (1.0 - saturation);
    // Limit chroma expansion at the gamut boundary, preserving hue/luma rather
    // than clipping individual channels. Neutral pixels have zero chroma.
    for (int i = 0; i < 3; ++i)
    {
        if (chroma[i] > 0.0)
            gain = min(gain, (1.0 - luma) / chroma[i]);
        else if (chroma[i] < 0.0)
            gain = min(gain, -luma / chroma[i]);
    }
    return clamp(vec3(luma) + gain * chroma, 0.0, 1.0);
}
