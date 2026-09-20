#include <CoreImage/CoreImage.h>
using namespace metal;

// Barrel and pincushion correction. A warp kernel answers, for the pixel being written, which
// pixel of the source to read: the inverse of the distortion, which is the correction itself.
//
// r' = r (1 + k1 r^2 + k2 r^4), with r running from 0 at the middle to 1 at the corner, so
// that the coefficients mean the same thing whatever the size of the picture.
extern "C" float2 lensDistortion(float k1, float k2, float2 centre, float halfDiagonal,
                                 coreimage::destination destination) {
    float2 offset = destination.coord() - centre;
    float radius = length(offset) / halfDiagonal;
    float squared = radius * radius;
    float scale = 1.0f + k1 * squared + k2 * squared * squared;
    return centre + offset * scale;
}
