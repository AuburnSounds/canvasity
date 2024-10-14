# Canvasity

`canvasity` DUB package is a port of the C++ library `canvas_ity.h` as seen [here](https://github.com/a-e-k/canvas_ity).
It provides a canvas type `Canvasity` similar to HTML Canvas API.

## Features
 - Familiar [Canvas API](https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API)
 - CSS color Support through the `colors` DUB [package](https://github.com/AuburnSounds/colors).
 - Lines, quadratic and bezier paths.
 - Line joins, line caps.
 - Support `fill()` AND `stroke()`.
 - Support `shadowBlur`.
 - Support `lineDash`.
 - Support `lineWidth`.
 - Support `save`/`restore` properly.
 - Support `clip` paths.
 - Support `globalAlpha` and most `globalCompositeOperation` modes.
 - Trapezoidal anti-aliasing.
 - Gamma-aware rect blending, interpolation, and resampling.
 - Premultiplied blending.
 - Support various underlying buffer types, 1 to 4 channels:
     - sRGB 8-bit 
     - sRGB 16-bit
     - sRGB 32-bit float
 - Quality options with `CanvasOptions`.
 - Suitable for `-betterC`, `nothrow @nogc`.
 - Amortized allocations, all buffers are reused.
 - SIMD optimizations. But for more performance for filled paths, consider using [`dplug:canvas`](). 
 - Stringly typed constants, but also enums for performance.

## Future
- Restore support for gradients
- Restore and solidify support for fonts
- Restore dither
- Restore image pattern fill
- Display-P3 support

## Limitations

The library does no input or output on its own. Instead, you must provide it with buffers to copy into or out of. 
This buffer must be a [`gamut`](https://github.com/AuburnSounds/gamut) `Image`.