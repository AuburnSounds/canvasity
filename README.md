# Canvasity

`canvasity` DUB package is a port of the C++ library `canvas_ity.h` as seen [here](https://github.com/a-e-k/canvas_ity).
It provides a canvas type `Canvasity` similar to HTML Canvas API.

## Features
 - Familiar [Canvas API](https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API)
 - CSS color Support through the `colors` DUB [package](https://github.com/AuburnSounds/colors).
 - Lines, quadratic and bezier paths.
 - Line joins, line caps.
 - `fill()` AND `stroke()`.
 - Support `shadowBlur`.
 - Support `setLineDash`.
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


# Examples



## 1. Drawing rectangles

![Rect example](https://github.com/AuburnSounds/canvasity/blob/main/rect-example.png?raw=true)

```d
import canvasity;
import gamut;

void main() {

    Image image;
    image.create(250, 250, PixelType.rgba8);

    Canvasity canvas = Canvasity(image);
    canvas.fillStyle = "#fff";
    canvas.fillRect(0, 0, 250, 250);
    canvas.fillStyle("red");
    canvas.fillRect(140, 20, 40, 250);
    canvas.fillStyle("blue");
    canvas.fillRect(50, 50, 150, 100);

    image.saveToFile("output-rectangle.png");
}
```

## 2. Applying Strokes with .stroke()

This example illustrate how `.fill()` and `.stroke` may be used in any order.

![Stroke example](https://github.com/AuburnSounds/canvasity/blob/main/stroke-example.png?raw=true)

```d
import canvasity;
import gamut;

void main() {

    Image image;
    image.create(300, 150, PixelType.rgba16);

    with(Canvasity(image)) {

        lineWidth = 30;
        strokeStyle = "red";
        lineJoin = "round";

        // Stroke on top of fill
        beginPath;
        rect(25, 25, 100, 100);
        fill;
        stroke;

        // Fill on top of stroke
        beginPath;
        rect(175, 25, 100, 100);
        stroke;
        fill;
    }
    image.convertTo8Bit();
    image.saveToFile("output-shadow.png");
}
```

## 3. Adding a shadow to a shape

This example adds a blurred shadow to a rectangle. The `shadowColor` property sets its color, and `shadowBlur` sets its level of blurriness.

![Shadow example](https://github.com/AuburnSounds/canvasity/blob/main/shadow-example.png?raw=true)

```d
import canvasity;
import gamut;

void main() {

    Image image;
    image.create(300, 300, PixelType.rgba16);

    with(Canvasity(image)) {
        shadowBlur    = 20;
        shadowOffsetX = 10;
        shadowOffsetY = 10;
        shadowColor("rgba(0, 0, 0, 0.5)");
        fillStyle("purple");
        fillRect(60, 60, 190, 190);
    }

    image.saveToFile("output-shadow.png");
}
```