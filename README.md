# Canvasity

`canvasity` DUB package is a port of the C++ library `canva_ity.h` as seen [here]().
It defines basic types for colors, and a **monomorphic** `Color` type to 
use as interchange.

_The problem is that screens and CSS now support the P3 colorspace, the 
end-goal is to be ready for more conversions than just staying sRGB forever. Color will be able to "do it all", in the future._

**This is a work in progress. Only sRGB supported for now.**