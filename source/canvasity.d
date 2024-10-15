/*
    canvas_ity v1.00 -- ISC license
    Copyright (c) 2022 Andrew Kensler
    Copyright (c) 2024 Guillaume Piolat - translation to D.
  
    Permission to use, copy, modify, and/or distribute this software 
    for any purpose with or without fee is hereby granted, provided 
    that the above copyright notice and this permission notice appear 
    in all copies.
  
    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL 
    WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED 
    WARRANTIES OF MERCHANTABILITY AND FITNESS.  IN NO EVENT SHALL THE 
    AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR 
    CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM 
    LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, 
    NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN 
    CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.


  ======== ABOUT ========
  
    This is a tiny D library for rasterizing immediate-mode 2D vector 
    graphics, closely modeled on the basic W3C (not WHATWG) HTML5 2D
    canvas specification:
        https://www.w3.org/TR/2015/REC-2dcontext-20151119/
  
    The priorities for this library are high-quality rendering, ease 
    of use, and compact size. Speed is important too, but secondary to 
    the other priorities. Notably, this library takes an opinionated 
    approach and does not provide options for trading off quality for 
    speed.
   
    Despite its small size, it supports nearly everything listed in 
    the W3C HTML5 2D canvas specification, except for hit regions and 
    getting certain properties. 
   
    The main differences lie in the surface-level API to make this
    easier for C++ use, while the underlying implementation is 
    carefully based on the specification. 
   
    In particular: stroke, fill, gradient, pattern, image, and font 
    styles are specified slightly differently (avoiding strings and 
    auxiliary classes). Nonetheless, the goal is that this library 
    could produce a conforming HTML5 2D canvas implementation if 
    wrapped in a thin layer of JavaScript bindings. 
   
    See the accompanying C++ automated test suite and its HTML5 port 
    for a mapping between the APIs and a comparison of this library's 
    rendering output against browser canvas implementations.
    Original link: https://github.com/a-e-k/canvas_ity


  ======== FEATURES ========
  
    High-quality rendering:
  
  - Trapezoidal area antialiasing provides very smooth antialiasing, 
    even when lines are nearly horizontal or vertical.
  
  - Gamma-correct blending, interpolation, and resampling are used
    throughout. It linearizes all colors and premultiplies alpha on
    input and converts back to unpremultiplied sRGB on output. This
    reduces muddiness on many gradients (e.g., red to green), makes 
    line thicknesses more perceptually uniform, and avoids dark 
    fringes when interpolating opacity.
  
  - Bicubic convolution resampling is used whenever it needs to 
    resample a pattern or image. This smoothly interpolates with 
    less blockiness when magnifying, and antialiases well when 
    minifying. It can simultaneously magnify and minify along 
    different axes.
  
  - Ordered dithering is used on output. This reduces banding on 
    subtle gradients while still being compression-friendly.
  
  - High curvature is handled carefully in line joins. Thick lines 
    are drawn correctly as though tracing with a wide pen nib, even
    where the lines curve sharply. (Simpler curve offsetting 
    approaches tend to show bite-like artifacts in these cases.)
  
  - Uses no static or global variables. Threads may safely work with
    different canvas instances concurrently without locking.
  

  ======== LIMITATIONS ========
 
  - Trapezoidal antialiasing overestimates coverage where paths self-
    intersect within a single pixel.  Where inner joins are visible, 
    this can lead to a "grittier" appearance due to the extra 
    windings used.

  - Clipping uses an antialiased sparse pixel mask rather than 
    geometrically intersecting paths. Therefore, it is not 
    subpixel-accurate.

  - Text rendering is extremely basic and mainly for convenience. It 
    only supports left-to-right text, and does not do any hinting, 
    kerning, ligatures, text shaping, or text layout. If you require 
    any of those, consider using another library to provide those and 
    feed the results to this library as either placed glyphs or raw 
    paths.

  - TRUETYPE FONT PARSING IS NOT SECURE!  It does some basic validity
    checking, but should only be used with known-good or sanitized 
    fonts.

  - Parameter checking does not test for non-finite floating-point 
    values.

  - Rendering is single-threaded, not explicitly vectorized, and not 
    GPU-accelerated. It also copies data to avoid ownership issues.
    If you need the speed, you are better off using a more 
    fully-featured library.

  - The library does no input or output on its own.  Instead, you must
      provide it with buffers to copy into or out of.

  ======== USAGE ========

    1. Construct an instance of `Canvasity` with a iven image buffer.
    2. Use public methods of `Canvasity`.
*/
/// D Port of canvas_ity.h 
/// Modifications:
/// * some SIMD
/// * buffer is passed and external instead of owned, it can be any
///   format
/// * removal of text, gradients, patterns, TODO add them back
/// * integration with `gamut` and `colors`
module canvasity;

nothrow @nogc:

import core.stdc.stdlib: malloc, free;
import core.stdc.math: cosf, sinf, tanf, floorf, fmodf, roundf,
                       sqrtf, acosf, ceilf, atan2f;
import core.stdc.string: memset, memcpy;
import dplug.core.vec;
import dplug.core.nogc;
import gamut;
import colors;
import inteli.emmintrin;
import inteli.math;

// Public API enums

/**
    Compositing operation for blending new drawing and old pixels.
    The sourceCopy, sourceIn, sourceOut, destinationAtop, and
    destinationIn operations may clear parts of the canvas outside 
    the new drawing but within the clip region. Defaults to:
    `sourceOver`.
*/
enum CompositeOperation {

    sourceIn = 1,   /// Replace old with new where old was opaque.
    sourceCopy,     /// Replace old with new.
    sourceOut,      /// Replace old with new where old is transparent.
    destinationIn,  /// Clear old where new is transparent.
    destinationAtop = 7, /// Show old over new where new is opaque.
    add     = 10,   /// Sum old with new.
    lighter = 10,   /// ditto
    destinationOver,/// Show new under old.
    destinationOut, /// Clear old where new is opaque.
    sourceAtop,     /// Show new over old where old is opaque.
    sourceOver,     /// Show new over old.
    exclusiveOr     /// Show new and old, clear where both are opaque.
}

/**
    The shape used to draw the end points of lines.

    The actual shape may be affected by the current transform at the 
    time of drawing. Only affects stroking. 

    Defaults to `LineCap.butt`.
*/
enum LineCap {

    butt,   /// Use a flat cap flush to the end of the line.
    square, /// Use a half-square cap that extends past the end of the
            /// line.
    circle  /// Use a semicircular cap.
}

/**
    The shape used to join two line segments where they meet.

    The actual shape may be affected by the current transform at the 
    time of drawing. Only affects stroking.

    Defaults to `LineJoin.miter`.
*/
enum LineJoin {

    miter, /// Continue the ends until they intersect, if within miter
           /// limit.
    bevel, /// Connect the ends with a flat triangle.
    round  /// Join the ends with a circular arc.
}


// TODO comment
enum repetition_style {

    repeat, 
    repeat_x, 
    repeat_y, 
    no_repeat 
}

/**  
    Horizontal position of the text relative to the anchor point.

    When drawing text, the positioning of the text relative to the 
    anchor point includes the side bearings of the first and last 
    glyphs.
    Defaults to leftward.
*/
enum align_style { // TODO rename and provide API to be like in HTML

    leftward,   /// Draw the text's left edge at the anchor point.
    rightward,  /// Draw the text's right edge at the anchor point.
    center,     /// Draw the text's horizontal center at the anchor 
                /// point.
    start = 0,  /// This is a synonym for leftward.
    ending      /// This is a synonym for rightward.
}


/**
    Vertical position of the text relative to the anchor point.

    Defaults to alphabetic.
*/
enum baseline_style { // TODO rename and provide API to be like in HTML

    alphabetic, /// Alphabetic baseline as the anchor point.
    top,        /// Top of the em box as the anchor point.
    middle,     /// Exact middle of the em box as the anchor point.
    bottom,     /// Bottom of the em box as the anchor point.
    hanging,    /// Draw 60% of an em over the baseline at the anchor 
                /// point. (??? Not what I remember from printed:font)
    ideographic = 3 /// This is a synonym for bottom.
}

/**
    The gamma space where colors are manipulated.
    Proper sRGB conversion to linear and back is very expensive.

    Note: alpha itself is always kept as is and considered linear.
*/
enum GammaCurve {

    none,   /// Colors are blended in storage space 
            /// without gamma-conversion beyond going float(fastest).
            /// It can look way worse than the other modes.

    pow2,   /// Colors are squared/sqrt to fake linear space.
            /// without accounting for sRGB linear part.
            /// Essentially nearly the quality of linear at much 
            /// cheaper cost.

    linear, /// Colors converted to linear space before blend (slow).
}

/**
    Options you can give while initializing a `Canvasity`.
*/
struct CanvasOptions {

    /// Default: medium quality.
    GammaCurve gammaCurve = GammaCurve.pow2;
}


/**
    Main canvas API.
    Given an image buffer, a `Canvasity` can draw 2D shapes without
    any GPU usage.
*/
struct Canvasity {

nothrow @nogc:
public:


    // ======== LIFECYCLE ========

    /**
        Construct a new canvas. Reset to default state.

        The buffer is provided externally and will NOT be cleared to
        transparent black. It MUST outlive the Canvasity.

        Initially, the visible coordinates will run from (0,0) in the
        upper-left to (width, height) in the lower-right and with 
        pixel centers offset (0.5, 0.5) from the integer grid, though 
        all this may be changed by transforms.  

        The sizes must be between 1 and 32768, inclusive.

        Note: internal allocated memory is reused if you keep 
        reusing the same instance with `.initialize`.
       
        Params: 
            buffer  Buffer to use as output. Not cleared on init.
            options Creation options.

        Warning: this does NOT clear the image. If you reuse the same
         Canvasity struct, all allocations will be reused eventually, 
         leading to zero allocation per frame.
    */
    this(ref Image buffer, 
         CanvasOptions options = CanvasOptions.init) {

        initialize(buffer, options);
    }
    ///ditto
    void initialize(ref Image buffer,
                    CanvasOptions options = CanvasOptions.init) {

        // Initialize as reference.
        outBitmap = buffer.layer(0);

        this.options = options;
        this.size_x = outBitmap.width();
        this.size_y = outBitmap.height();

        // Initialize state
        if (_state is null) {
            size_t stackSize = (maxSaveRestoreDepth + 1);
            size_t stateBytes = State.sizeof * stackSize;
            _state = cast(State*) malloc(stateBytes);

            // Initialize all stack items with State.init
            for (size_t n = 0; n < stackSize; ++n) {
                State i;
                memcpy(&_state[n], &i, State.sizeof);
            }
        }
        else
        {
            // Reset state[0] to State.init, without overriding the Vec
            // allocations
            {
                State initial;
                _state[0] = initial;
            }
        }

        // Reset stack, some allocation will linger if canvas reused.
        _stateCount = 1;

        fillStyle("black");
        strokeStyle("black");
        
        // Initialize clipping state
        // PERF: create that lazily?
        
        State* curr = current;
        ushort sz_x = cast(ushort)size_x;
        for ( ushort y = 0; y < size_y; ++y ) {
            pixel_run piece_1 = pixel_run(   0, y, 1.0f);
            pixel_run piece_2 = pixel_run(sz_x, y, -1.0f);
            curr.mask.pushBack(piece_1);
            curr.mask.pushBack(piece_2);
        }

        interType = scanlinesInterType(outBitmap.type, PixelType.rgbaf32);
        scanBuf.resize(buffer.width * pixelTypeSize(PixelType.rgbaf32));
        interBuf.resize(buffer.width * pixelTypeSize(interType));
    }

    ~this() {
        free( _state);
    }


    // ======== TRANSFORMS ========

    // document things that are part of the state stack, and saved
    // by the save/restore sequence.
    enum { savedBySaveRestore }


    /**
        Scale the current transform.

        Negative scaling factors will flip or mirror it in that 
        direction. The scaling factors must be non-zero.
        If either is zero, most drawing operations will do nothing.

        Params:
            x Horizontal scaling factor.
            y Vertical scaling factor.
    */
    @savedBySaveRestore
    void scale(float x, float y) {
        transform(x, 0, 0, y, 0, 0);
    }


    /**
        Rotate the current transform.
    
        The rotation is applied clockwise in a direction around the 
        origin.

        Note: To rotate around another point, first translate that 
              point to the origin, then do the rotation, and then 
              translate back.

        Params:
            angle Clockwise angle in radians.
    */
    @savedBySaveRestore
    void rotate(float angle) {
        float cosine = cosf(angle);
        float sine = sinf(angle);
        transform(cosine, sine, -sine, cosine, 0, 0);
    }


    /** 
        Translate the current transform.
    
        By default, positive x values shift that many pixels to the 
        right, while negative y values shift left, positive y values 
        shift up, and negative y values shift down.
    
        Params:
            x Amount to shift horizontally.
            y Amount to shift vertically.
    */
    @savedBySaveRestore
    void translate(float x, float y) {
        transform(1, 0, 0, 1, x, y);
    }


    /**
        Add an arbitrary transform to the current transform.

        This takes six values for the upper two rows of a homogenous 
        3x3 matrix (i.e., {{a, c, e}, {b, d, f}, {0.0, 0.0, 1.0}}) 
        describing an arbitrary affine transform and appends it to 
        the current transform. The values can represent any affine 
        transform such as scaling,  rotation, translation, or skew, 
        or any composition of affine transforms.  
        The matrix must be invertible.  If it is not, most drawing 
        operations will do nothing.

        Params:
            a  Horizontal scaling factor (m11).
            b  Vertical skewing (m12).
            c  Horizontal skewing (m21).
            d  vertical scaling factor (m22).
            e  Horizontal translation (m31).
            f  Vertical translation (m32).
    */
    @savedBySaveRestore
    void transform(float a, float b, 
                   float c, float d, 
                   float e, float f) {
        affine_matrix fwd = current.forward;
        setTransform( fwd.a * a + fwd.c * b,
                      fwd.b * a + fwd.d * b,
                      fwd.a * c + fwd.c * d,
                      fwd.b * c + fwd.d * d,
                      fwd.a * e + fwd.c * f + fwd.e,
                      fwd.b * e + fwd.d * f + fwd.f );
    }


    /** 
        Replace the current transform.
       
        This takes six values for the upper two rows of a homogenous 
        3x3 matrix (i.e., {{a, c, e}, {b, d, f}, {0.0, 0.0, 1.0}}) 
        describing an arbitrary affine transform and replaces the 
        current transform with it. The values can represent any affine 
        transform such as scaling, rotation, translation, or skew, or 
        any composition of affine transforms. 

        The matrix must be invertible. f it is not, most drawing 
        operations will do nothing.
       
        Note: to reset the current transform back to the default, use
              1.0, 0.0, 0.0, 1.0, 0.0, 0.0.
       
        Params:
            a Horizontal scaling factor (m11).
            b Vertical skewing (m12).
            c Horizontal skewing (m21).
            d Vertical scaling factor (m22).
            e Horizontal translation (m31).
            f Vertical translation (m32).
    */
    @savedBySaveRestore
    void setTransform(float a, float b, 
                      float c, float d, 
                      float e, float f)
    {
        float determinant = a * d - b * c;
        float scaling = determinant != 0 ? (1 / determinant) : 0;
        affine_matrix new_forward = affine_matrix(a, b, c, d, e, f);
        affine_matrix new_inverse = affine_matrix(
            scaling * d, scaling * -b, scaling * -c, scaling * a,
            scaling * ( c * f - d * e ), scaling * ( b * e - a * f ));
        current.forward = new_forward;
        current.inverse = new_inverse;
    }


    // ======== COMPOSITING ========


    /**
        Set/get the opacity applied to all drawing operations.

        If an operation already uses a transparent color, this can 
        make it yet more transparent. 

        `alpha` must be in the range 0.0 for fully transparent 
                                  to 1.0 for fully opaque.

        Defaults to 1.0 (opaque).

        Params:
            alpha Degree of opacity applied to all drawing operations.
    */
    @savedBySaveRestore
    void globalAlpha(float alpha) {
        if (0 <= alpha && alpha <= 1.0)
            current.global_alpha = alpha;
    }
    ///ditto
    float globalAlpha() {
        return current.global_alpha;
    }


    // ======== SHADOWS ========


    /** 
        Set the color and opacity of the shadow.
        
        Shadows will only be drawn if the shadow color has any 
        opacity and the shadow is either offset or blurred.

        Defaults to transparent black.

        Can give:
        - a `Color`, such as one obtained by the `colors` package
        - a CSS string, 
        - a `RGBA8` 8-bit sRGB ubyte quadruplet
        - a `RGBA16` 16-bit sRGB ubyte quadruplet
        - a `RGBAf` 32-bit sRGB ubyte quadruplet
    */
    @savedBySaveRestore
    void shadowColor(Color col) {
        RGBAf co = col.toRGBAf();
        rgba c = rgba(co.r,co.g,co.b,co.a);
        c = clamped(c);
        fromGammaSpace((&c)[0..1], options.gammaCurve);
        current.shadow_color = premultiplied(c);
    }
    ///ditto
    void shadowColor(const(char)[] cssColor) {
        shadowColor(Color(cssColor));
    }
    ///ditto
    void shadowColor(RGBAf col)  { shadowColor(Color(col)); }
    ///ditto
    void shadowColor(RGBA8 col)  { shadowColor(Color(col)); }
    ///ditto
    void shadowColor(RGBA16 col) { shadowColor(Color(col)); }
    // <old method of original library>
    deprecated void shadowColor(float r, float g, float b, float a) {
        shadowColor(RGBAf(r, g, b, a));
    }
    // </old method of original library>

    // TODO: getter, store shadow color as Color


    /**
        Set/get the level of gaussian blurring on the shadow.

        Zero produces no blur, while larger values will blur the 
        shadow more strongly. This is not affected by the current 
        transform. Must be non-negative. If it is not, this does 
        nothing. 

        Defaults to 0.0 (no blur).
        
        Params:
            level The level of gaussian blurring on the shadow.
    */     
    @savedBySaveRestore
    void shadowBlur(float level) {
        if (0.0f <= level)
            current.shadow_blur = level;
    }
    ///ditto
    float shadowBlur() {
        return current.shadow_blur;
    }

    /** 
        Set/get offset of the shadow in pixels.
        
        Negative shifts left/top, positive shifts right/bottom. 
        Not affected by the current transform. 
        Defaults to 0 (no offset).
    */
    @savedBySaveRestore
    void shadowOffsetX(float offsetX) {
        current.shadow_offset_x = offsetX;
    }
    ///ditto
    float shadowOffsetX() {
        return current.shadow_offset_x;
    }
    ///ditto
    @savedBySaveRestore
    void shadowOffsetY(float offsetY) {
        current.shadow_offset_y = offsetY;
    }
    ///ditto    
    float shadowOffsetY() {
        return current.shadow_offset_y;
    }


    // ======== LINE STYLES ========


    /**
        Set/get the width of the lines when stroking.
       
        Initially this is measured in pixels, though the current 
        transform at the time of drawing can affect this. 
        Must be positive. If it is not, this does nothing. 
        Defaults to 1.0.
       
        Params: 
            width Width of the lines when stroking.
    */
    @savedBySaveRestore
    void lineWidth(float width) {
        if ( 0.0f < width )
            current.line_width = width;
    }
    ///ditto
    float lineWidth() {
        return current.line_width;
    }


    ///
    @savedBySaveRestore
    void lineCap(LineCap capStyle) {
        current.line_cap = capStyle;
    }
    ///ditto
    void lineCap(const(char)[] capStyle) {
        switch(capStyle) {
            case "butt": current.line_cap = LineCap.butt; break;
            case "square": current.line_cap = LineCap.square; break;
            case "circle": current.line_cap = LineCap.circle; break;
            default:
        }
    }
    ///ditto
    LineCap lineCap() {
        return current.line_cap;
    }


    ///
    @savedBySaveRestore
    void lineJoin(LineJoin joinStyle) {
        current.line_join = joinStyle;
    }
    ///ditto
    void lineJoin(const(char)[] joinStyle) {
        switch(joinStyle) {
            case "miter": current.line_join = LineJoin.miter; break;
            case "bevel": current.line_join = LineJoin.bevel; break;
            case "round": current.line_join = LineJoin.round; break;
            default:
        }
    }
    ///ditto
    LineJoin lineJoin() {
        return current.line_join;
    }


    /**
        Set/get the limit on maximum pointiness allowed for miter 
        joins.

        If the distance from the point where the lines intersect to 
        the point where the outside edges of the join intersect 
        exceeds this ratio relative to the line width, then a bevel 
        join will be used instead, and the miter will be lopped off. 
        Larger values allow pointier miters.  Only affects stroking 
        and only when the line join style is miter. Must be positive.
        If it is not, this does nothing.

        Defaults to 10.0.
        
        Params:
            limit Limit on maximum pointiness allowed for miter joins.
    */
    @savedBySaveRestore
    void miterLimit(float limit) {
        if (0 < limit)
            current.miter_limit = limit;
    }
    ///ditto
    float miterLimit() {
        return current.miter_limit;
    }


    /** 
        Set or clear the line dash pattern.

        Takes an array with entries alternately giving the lengths of 
        dash and gap segments. All must be non-negative; if any are
        not, this does nothing. These will be used to draw with dashed 
        lines when stroking, with each subpath starting at the length 
        along the dash pattern indicated by the line dash offset.
        Initially these lengths are measured in pixels, though the 
        current transform at the time of drawing can affect this.  
        The count must be non-negative. If it is odd, the array will 
        be appended to itself to make an even count. If it is zero, 
        or the pointer is null, the dash pattern will be cleared and 
        strokes will be drawn as solid lines. The array is copied and
        it is safe to change or destroy it after this call. 
        Defaults to solid lines.

        Params:
            segments Pointer to array for dash pattern.
            count    Number of entries in the array.
    */
    @savedBySaveRestore
    void setLineDash(const(float)*segments, int count ) {

        if (segments)
            for (int i = 0; i < count; ++i)
                if (segments[i] < 0)
                    return;

        current.line_dash.clearContents();

        if ( ! segments)
            return;
        
        for (int i = 0; i < count; ++i)
            current.line_dash.pushBack(segments[i]);

        if (count & 1) // odd
            for (int i = 0; i < count; ++i)
                current.line_dash.pushBack(segments[i]);
    }
    ///ditto
    @savedBySaveRestore
    void setLineDash(const(float)[] segments) {
        setLineDash(segments.ptr, cast(int)segments.length);
    }
    ///ditto
    @savedBySaveRestore
    void setLineDash() {
        setLineDash(null, 0);
    }


    /** 
        Offset where each subpath starts the dash pattern.
    
        Changing this shifts the location of the dashes along the path 
        and animating it will produce a marching ants effect. Only 
        affects stroking and only when a dash pattern is set. May be 
        negative or exceed the length of the dash pattern, in which 
        case it will wrap.
        Defaults to 0.0.
    */
    @savedBySaveRestore
    void lineDashOffset(float offset) {
        current.line_dash_offset = offset;
    }
    float lineDashOffset() {
        return current.line_dash_offset;
    }


    // ======== FILL AND STROKE STYLES ========


    /** 
        Set filling or stroking to use a constant color and opacity.

        Can give:
        - a `Color`, such as one obtained by the `colors` package
        - a CSS string, 
        - a `RGBA8` 8-bit sRGB ubyte quadruplet
        - a `RGBA16` 16-bit sRGB ubyte quadruplet
        - a `RGBAf` 32-bit sRGB ubyte quadruplet
    */
    @savedBySaveRestore
    void fillStyle(Color col) {
        RGBAf c = col.toRGBAf();
        set_color(brush_type.fill_style, c.r, c.g, c.b, c.a);
    }
    ///ditto
    void fillStyle(const(char)[] cssColor) {
        fillStyle(Color(cssColor));
    }
    ///ditto
    void fillStyle(RGBAf col)  { fillStyle(Color(col)); }
    ///ditto
    void fillStyle(RGBA8 col)  { fillStyle(Color(col)); }
    ///ditto
    void fillStyle(RGBA16 col) { fillStyle(Color(col)); }
    ///ditto
    void fillStyle(T)(T col) if (isLikeRGBA8!T) {
        // Support a color-like struct like Dplug's RGBA
        fillStyle(RGBA8(cast(ubyte)col.r, 
                        cast(ubyte)col.g, 
                        cast(ubyte)col.b, 
                        cast(ubyte)col.a));
    }

    ///ditto
    @savedBySaveRestore
    void strokeStyle(Color col) {
        RGBAf c = col.toRGBAf();
        set_color(brush_type.stroke_style, c.r, c.g, c.b, c.a);
    }
    ///ditto
    void strokeStyle(const(char)[] cssColor) {
        strokeStyle(Color(cssColor));
    }
    ///ditto
    void strokeStyle(RGBAf col)  { strokeStyle(Color(col)); }
    ///ditto
    void strokeStyle(RGBA8 col)  { strokeStyle(Color(col)); }
    ///ditto
    void strokeStyle(RGBA16 col) { strokeStyle(Color(col)); }
    ///ditto
    void strokeStyle(T)(T rgba)  if (isLikeRGBA8!T) {
        strokeStyle(RGBA8(cast(ubyte)rgba.r, 
                          cast(ubyte)rgba.g, 
                          cast(ubyte)rgba.b, 
                          cast(ubyte)rgba.a));
    }

    // <Old canvasity ways to give a color>
    deprecated("Use fillStyle(str or Color) instead") 
        void fillStyle(float r, float g, float b, float a) {
            set_color(brush_type.fill_style, r, g, b, a);
    }
    deprecated("Use strokeStyle(str or Color) instead")
    void strokeStyle(float r, float g, float b, float a) {
        set_color(brush_type.stroke_style, r, g, b, a);
    }
    // </Old canvasity ways to give a color>


    // Note: the following doesn't follow the HTML5 Canvas API, which 
    // is different from dplug:canvas unfortunately.


    // TODO: port later

/+
    /// @brief  Set filling or stroking to use a linear gradient.
    ///
    /// Positions the start and end points of the gradient and clears all
    /// color stops to reset the gradient to transparent black.  Color stops
    /// can then be added again.  When drawing, pixels will be painted with
    /// the color of the gradient at the nearest point on the line segment
    /// between the start and end points.  This is affected by the current
    /// transform at the time of drawing.
    ///
    /// @param type     whether to set the fill_style or stroke_style
    /// @param start_x  horizontal coordinate of the start of the gradient
    /// @param start_y  vertical coordinate of the start of the gradient
    /// @param end_x    horizontal coordinate of the end of the gradient
    /// @param end_y    vertical coordinate of the end of the gradient
    ///
    void set_linear_gradient(brush_type type, float start_x, float start_y, 
                             float end_x, float end_y )
    {
        paint_brush* brush = type == brush_type.fill_style ? &fill_brush : &stroke_brush;
        brush.type = paint_brush.types.linear;
        brush.colors.clearContents();
        brush.stops.clearContents();
        brush.start = xy( start_x, start_y );
        brush.end = xy( end_x, end_y );
    }

    /// @brief  Set filling or stroking to use a radial gradient.
    ///
    /// Positions the start and end circles of the gradient and clears all
    /// color stops to reset the gradient to transparent black.  Color stops
    /// can then be added again.  When drawing, pixels will be painted as
    /// though the starting circle moved and changed size linearly to match
    /// the ending circle, while sweeping through the colors of the gradient.
    /// Pixels not touched by the moving circle will be left transparent
    /// black.  The radial gradient is affected by the current transform
    /// at the time of drawing.  The radii must be non-negative.
    ///
    /// @param type          whether to set the fill_style or stroke_style
    /// @param start_x       horizontal starting coordinate of the circle
    /// @param start_y       vertical starting coordinate of the circle
    /// @param start_radius  starting radius of the circle
    /// @param end_x         horizontal ending coordinate of the circle
    /// @param end_y         vertical ending coordinate of the circle
    /// @param end_radius    ending radius of the circle
    ///
    void set_radial_gradient(brush_type type,
                             float start_x,
                             float start_y,
                             float start_radius,
                             float end_x,
                             float end_y,
                             float end_radius )
    {
        if ( start_radius < 0.0f || end_radius < 0.0f )
            return;
        paint_brush* brush = type == brush_type.fill_style ? &fill_brush : &stroke_brush;
        brush.type = paint_brush.types.radial;
        brush.colors.clear();
        brush.stops.clear();
        brush.start = xy( start_x, start_y );
        brush.end = xy( end_x, end_y );
        brush.start_radius = start_radius;
        brush.end_radius = end_radius;
    }

    /// @brief  Add a color stop to a linear or radial gradient.
    ///
    /// Each color stop has an offset which defines its position from 0.0 at
    /// the start of the gradient to 1.0 at the end.  Colors and opacity are
    /// linearly interpolated along the gradient between adjacent pairs of
    /// stops without premultiplying the alpha.  If more than one stop is
    /// added for a given offset, the first one added is considered closest
    /// to 0.0 and the last is closest to 1.0.  If no stop is at offset 0.0
    /// or 1.0, the stops with the closest offsets will be extended.  If no
    /// stops are added, the gradient will be fully transparent black.  Set a
    /// new linear or radial gradient to clear all the stops and redefine the
    /// gradient colors.  Color stops may be added to a gradient at any time.
    /// The color and opacity values will be clamped to the 0.0 to 1.0 range,
    /// inclusive.  The offset must be in the 0.0 to 1.0 range, inclusive.
    /// If it is not, or if chosen style type is not currently set to a
    /// gradient, this does nothing.
    ///
    /// @param type    whether to add to the fill_style or stroke_style
    /// @param offset  position of the color stop along the gradient
    /// @param red     sRGB red component of the color stop
    /// @param green   sRGB green component of the color stop
    /// @param blue    sRGB blue component of the color stop
    /// @param alpha   opacity of the color stop (not premultiplied)
    ///
    void add_color_stop(brush_type type,
                        float offset,
                        float red,
                        float green,
                        float blue,
                        float alpha )
    {
        paint_brush* brush = type == brush_type.fill_style ? &fill_brush : &stroke_brush;
        if ( ( brush.type != paint_brush.types.linear &&
               brush.type != paint_brush.types.radial ) ||
             offset < 0.0f || 1.0f < offset )
            return;

        // Finds the first element in stop that is greater than offset.
        size_t index = brush.stops.length;
        for (size_t i = 0; i < brush.stops.length; ++i)
        {
            if ( brush.stops[i] > offset)
            {
                index = i;
                break;
            }
        }

        rgba color = linearized( clamped( rgba( red, green, blue, alpha ) ) );

        // Insert into colors and stops
        brush.colors.pushBack(rgba.init);
        brush.stops.pushBack(float.init);
        int last = cast(int)(brush.colors.length - 1);
        for (int i = last; i > index; --i)
        {
            brush.colors[i] = brush.colors[i-1];
            brush.stops[i] = brush.stops[i-1];
        }
        brush.colors[index] = color;
        brush.stops[index] = offset;
    }
    +/

    

    // ======== BUILDING PATHS ========


    /**
        Reset the current path.

        The current path and all subpaths will be cleared after this,
        and a new path can be built.
    */
    void beginPath() {
        path.points.clearContents();
        path.subpaths.clearContents();
    }


    /**
        Create a new subpath.
       
        The given point will become the first point of the new subpath 
        and is subject to the current transform at the time this is 
        called.
       
        Params:
            x  Horizontal coordinate of the new first point.
            y  Vertical coordinate of the new first point.
    */       
    void moveTo(float x, float y) {
        xy transformed = forwardTransform(xy(x, y));
        if ( (path.subpaths.length != 0) 
            && path.subpaths[$-1].count == 1 ) {
            path.points[$-1] = transformed;
            return;
        }
        subpath_data subpath = subpath_data(1, false);
        path.points.pushBack(transformed);
        path.subpaths.pushBack( subpath );
    }
    ///ditto
    void moveTo(T)(T v) {
        moveTo(v.x, v.y);
    }


    /**
        Close the current subpath.
        
        Adds a straight line from the end of the current subpath back 
        to its first point and marks the subpath as closed so that 
        this line will join with the beginning of the path at this 
        point. A new, empty subpath will be started beginning with the 
        same first point. If the current path is empty, this does 
        nothing.
    */        
    void closePath() {
        if (path.subpaths.length == 0)
            return;
        size_t pointsInSubpath = path.subpaths[$-1].count;
        xy first = path.points[path.points.length - pointsInSubpath];

        // MAYDO: ugly, maybe lineTo and moveTo could have a private 
        // impl with abs coordinates
        affine_matrix saved_forward = current.forward;
        current.forward = affine_matrix.identity;

        // finish path
        lineTo(first.x, first.y);
        path.subpaths[$-1].closed = true;

        // move there.
        moveTo(first.x, first.y);
        current.forward = saved_forward;
    }


    /**
        Extend the current subpath with a straight line.
       
        The line will go from the current end point (if the current 
        path is not empty) to the given point, which will become the 
        new end point. Its position is affected by the current 
        transform at the time that this is called. If the current path 
        was empty, this is equivalent to just a move.

        Params:
            x  Horizontal coordinate of the new end point.
            y  Vertical coordinate of the new end point.
    */       
    void lineTo(float x, float y) {
        if (path.subpaths.length == 0) {
            moveTo(x, y);
            return;
        }
        xy p1 = path.points[$-1];
        xy p2 = forwardTransform(xy(x, y));
        if (dot(p2 - p1, p2 - p1 ) == 0.0f)
            return;
        // PERF: pushBack all 3 at once
        path.points.pushBack(p1);
        path.points.pushBack(p2);
        path.points.pushBack(p2);
        path.subpaths[$-1].count += 3;
    }
    ///ditto
    void lineTo(T)(T v) { 
        lineTo(v.x, v.y); // support point types
    }


    /**
        Extend the current subpath with a quadratic Bezier curve.
       
        The curve will go from the current end point (or the control 
        point if the current path is empty) to the given point, which 
        will become the new end point. The curve will be tangent 
        toward the control point at both ends. The current transform 
        at the time that this is called will affect both points passed 
        in.
       
        Tip: to make multiple curves join smoothly, ensure that each 
             new end point is on a line between the adjacent control 
             points.
       
        Params:
            cx  Horizontal coordinate of the control point.
            cy  Vertical coordinate of the control point.
            x   Horizontal coordinate of the new end point.
            y   Vertical coordinate of the new end point.
    */       
    void quadraticCurveYo(float cx, float cy, float x, float y )
    {
        if (path.subpaths.length == 0)
            moveTo(cx, cy);
        xy point_1 = path.points[$-1];
        xy control = forwardTransform(xy(cx, cy));
        xy point_2 = forwardTransform(xy( x,  y));
        xy control_1 = lerp(point_1, control, 2.0f / 3.0f);
        xy control_2 = lerp(point_2, control, 2.0f / 3.0f);
        // PERF: same, pushback all 3 at once
        path.points.pushBack(control_1);
        path.points.pushBack(control_2);
        path.points.pushBack(point_2);
        path.subpaths[$-1].count += 3;
    }
    ///ditto
    void quadraticCurveYo(T)(T c, T p) {
        quadraticCurveYo(c.x, c.y, p.x, p.y); // support point types
    }

    /**
        Extend the current subpath with a cubic Bezier curve.
       
        The curve will go from the current end point (or the first 
        control point if the current path is empty) to the given 
        point, which will become the new end point. The curve will be 
        tangent toward the first control point at the beginning and 
        tangent toward the second control point at the end. The 
        current transform at the time that this is called will affect 
        all points passed in.
       
        Tip: to make multiple curves join smoothly, ensure that each 
             new end point is on a line between the adjacent control 
             points.
       
        Params:
            c1_x  Horizontal coordinate of 1st control point.
            c1_y  Vertical coordinate of 1st control point.
            c2_x  Horizontal coordinate of 2nd control point.
            c2_y  Vertical coordinate of 2nd control point.
            x     Horizontal coordinate of new end point.
            y     Vertical coordinate of new end point.
    */       
    void bezierCurveTo(float c1_x, float c1_y,
                       float c2_x, float c2_y,
                       float x, float y ) {
        if ( path.subpaths.length == 0 )
            moveTo( c1_x, c1_y );
        xy control_1 = forwardTransform(xy( c1_x, c1_y ));
        xy control_2 = forwardTransform(xy( c2_x, c2_y ));
        xy point_2   = forwardTransform(xy(    x,    y ));
        // PERF: same, pushback all 3 at once
        path.points.pushBack(control_1);
        path.points.pushBack(control_2);
        path.points.pushBack(point_2);
        path.subpaths[$-1].count += 3;
    }
    ///ditto
    void bezierCurveTo(T)(T c1, T c2, T p) {
        // support point types
        bezierCurveTo(c1.x, c1.y, c2.x, c2.y, p.x, p.y);
    }

    /**
        Extend the current subpath with an arc tangent to two lines.
       
        The arc is from the circle with the given radius tangent to 
        both the line from the current end point to the vertex, and to 
        the line from the vertex to the given point. A straight line 
        will be added from the current end point to the first tangent 
        point (unless the current path is empty), then the shortest 
        arc from the first to the second tangent points will be added.
        The second tangent point will become the new end point. 
        If the radius is large, these tangent points may fall outside 
        the line segments. The current transform at the time that this 
        is called will affect the passed in points and the arc. 
        If the current path was empty, this is equivalent to a move.  
        If the arc would be degenerate, it is equivalent to a line to 
        the vertex point. The radius must be non-negative. 
        If it is not, or if the current transform is not invertible, 
        this does nothing.
       
        Note: To draw a polygon with rounded corners, call this once 
             for each vertex and pass the midpoint of the adjacent 
             edge as the second point; this works especially well for 
             rounded boxes.
       
        Params:
            v_x    Horizontal coordinate where the tangent lines meet.
            v_y    Vertical coordinate where the tangent lines meet.
            x      A horizontal coordinate on the second tangent line.
            y      A vertical coordinate on the second tangent line.
            r Radius of the circle containing the arc.
    */
    void arcTo(float v_x, float v_y, float x, float y, float r ) {
        affine_matrix fwd = current.forward;
        if ( (r < 0) || ( ! fwd.isInvertible) == 0.0f)
            return;
        if (path.subpaths.length == 0)
            moveTo(v_x, v_y);
        xy point_1 = inverseTransform(path.points[$-1]);
        xy vertex  = xy(v_x, v_y);
        xy point_2 = xy(x, y);
        xy edge_1 = normalized(point_1 - vertex);
        xy edge_2 = normalized(point_2 - vertex);
        float sine = fabsf( dot( perpendicular( edge_1 ), edge_2 ) );
        enum float epsilon = 1.0e-4f;
        if (sine < epsilon) {
            lineTo(v_x, v_y);
            return;
        }
        xy offset = ( edge_1 + edge_2 ) * (r / sine);
        xy center = vertex + offset;
        float a1 = direction(dot(offset, edge_1)*edge_1 - offset);
        float a2 = direction(dot(offset, edge_2)*edge_2 - offset);
        bool reverse = cast(int)(floorf((a2 - a1) / 3.14159265f)) & 1;
        arc(center.x, center.y, r, a1, a2, reverse);
    }
    ///ditto
    void arcTo(T)(T v, T p, float r) {
        // support point types
        arcTo(v.x, v.y, p.x, p.y, r);
    }


    /** 
        Extend the current subpath with an arc between two angles.
        
        The arc is from the circle centered at the given point and 
        with the given radius.  A straight line will be added from the
        current end point to the starting point of the arc (unless the
        current path is empty), then the arc along the circle from the 
        starting angle to the ending angle in the given direction will 
        be added. 

        If they are more than two pi radians apart in the given 
        direction, the arc will stop after one full circle. The point 
        at the ending angle will become the new end point of the path.
        Initially, the angles are clockwise relative to the x-axis.  
        The current transform at the time that this is called will 
        affect the passed in point, angles, and arc.
        The radius must be non-negative else it does nothing.
        
        Params:
            x                Horizontal coordinate of circle center.
            y                Vertical coordinate of circle center.
            radius           Radius of the circle containing the arc.
            start_angle      Radians clockwise from x-axis to begin.
            end_angle        Radians clockwise from x-axis to end.
            counterClockwise `true` if arc turns counter-clockwise.
    */        
    void arc(float x, float y, float radius, 
             float start_angle, float end_angle, 
             bool counter_clockwise) {

        if (radius < 0)
            return;

        enum float tau = 6.28318531f;
        float winding = counter_clockwise ? -1.0f : 1.0f;
        float from = fmodf(start_angle, tau);
        float span = fmodf(end_angle, tau) - from;

        if (( end_angle - start_angle) * winding >= tau)
            span = tau * winding;
        else if (span * winding < 0.0f)
            span += tau * winding;

        xy centered_1 = radius * xy(cosf(from), sinf(from));
        lineTo(x + centered_1.x, y + centered_1.y);
        if (span == 0.0f)
            return;

        float fsteps = roundf(16.0f / tau * span * winding);
        int steps = cast(int)(fmaxf(1.0f, fsteps));
        float segment = span / cast(float)(steps);
        float alpha = 4.0f / 3.0f * tanf(0.25f * segment);

        // Note: it's a bit of the same weakness as dplug:canvas,
        //       in that the number of bezier subdivide do not depend
        //       on the transform.
        for ( int step = 0; step < steps; ++step ) {
            float angle = from + cast(float)( step + 1 ) * segment;
            xy centered_2 = radius * xy(cosf(angle), sinf(angle));
            xy point_1   = xy( x, y ) + centered_1;
            xy point_2   = xy( x, y ) + centered_2;
            xy control_1 = point_1 + alpha*perpendicular(centered_1);
            xy control_2 = point_2 - alpha*perpendicular(centered_2);
            bezierCurveTo(control_1.x, control_1.y,
                          control_2.x, control_2.y,
                          point_2.x, point_2.y );
            centered_1 = centered_2;
        }
    }
    ///ditto
    void arc(T)(T p, float radius,  float start_angle, 
                float end_angle, bool counter_clockwise) {
        // support point types
        arc(p.x, p.y, radius, start_angle, end_angle, counter_clockwise);
    }


    /** 
        Add a closed subpath in the shape of a rectangle.
       
        The rectangle has one corner at the given point and then goes 
        in the direction along the width before going in the direction 
        of the height towards the opposite corner.  The current 
        transform at the time that this is called will affect the 
        given point and rectangle. The width and/or the height may be 
        negative or zero, and this can affect the winding direction.
       
        Params:
            x       Horizontal coordinate of a rectangle corner.
            y       Vertical coordinate of a rectangle corner.
            width   Width of the rectangle.
            height  Height of the rectangle.
    */       
    void rect(float x, float y, float width, float height) {
        moveTo(x, y);
        lineTo(x + width, y);
        lineTo(x + width, y + height);
        lineTo(x, y + height);
        closePath();
    }


    // ======== DRAWING PATHS ========


    /** Draw the interior of the current path using the fill style.
       
        Interior pixels are determined by the non-zero winding rule, 
        with all open subpaths implicitly closed by a straight line 
        beforehand. If shadows have been enabled by setting the shadow 
        color with any opacity and either offsetting or blurring the 
        shadows, then the shadows of the filled areas will be drawn 
        first, followed by the filled areas themselves. Both will be 
        blended into the canvas according to the global alpha, the 
        global compositing operation, and the clip region. If the fill
        style is a gradient or a pattern, it will be affected by the 
        current transform. The current path is left unchanged by 
        filling; begin a new path to clear it. If the current 
        transform is not invertible, this does nothing.
    */       
    void fill() {
        path_to_lines(false);
        render_main(current.fill_brush);
    }
    

    /** 
        Draw the edges of the current path using the stroke style.
       
        Edges of the path will be expanded into strokes according to 
        the current dash pattern, dash offset, line width, line join 
        style (and possibly miter limit), line cap, and transform. 
        If shadows have been enabled by setting the shadow color with 
        any opacity and either offsetting or blurring the shadows, 
        then the shadow will be drawn for the stroked lines first, 
        then the stroked lines themselves. Both will be blended into 
        the canvas according to the global alpha, the global 
        compositing operation, and the clip region. If the stroke 
        style is a gradient or a pattern, it will be affected by the 
        current transform. The current path is left unchanged by 
        stroking; begin a new path to clear it. If the current 
        transform is not invertible, this does nothing.

        Note: to draw with a calligraphy-like angled brush effect, add 
              a non-uniform scale transform just before stroking.
    */
    void stroke() {
        path_to_lines(true);
        stroke_lines();
        render_main(current.stroke_brush);
    }

    /**
        Restrict the clip region by the current path.

        Intersects the current clip region with the interior of the 
        current path (the region that would be filled), and replaces 
        the current clip region with this intersection.  Subsequent 
        calls to clip can only reduce this further. When filling or 
        stroking, only pixels within the current clip region will 
        change. The current path is left unchanged by updating the 
        clip region; begin a new path to clear it.  Defaults to the 
        entire canvas.

        Tip: to be able to reset the current clip region, save the 
            canvas state first before clipping then restore the state 
            to reset it.
    */
    void clip() {
        path_to_lines(false);
        lines_to_runs(xy(0.0f, 0.0f), 0);
        size_t part = runs.length;
        runs.pushBack(current.mask);
        Vec!pixel_run* mask = &current.mask;
        mask.clearContents();
        int y = -1;
        float last = 0;
        float sum_1 = 0;
        float sum_2 = 0;
        size_t index_1 = 0;
        size_t index_2 = part;
        while (index_1 < part && index_2 < runs.length) {            
            bool which = comparePixelRuns(runs[index_1], 
                                          runs[index_2]) < 0;
            pixel_run next = (which != 0) ? runs[index_1] 
                                          : runs[index_2];
            if (next.y != y) {
                y = next.y;
                last = 0;
                sum_1 = 0;
                sum_2 = 0;
            }
            if ( which )
                sum_1 += runs[ index_1++ ].delta;
            else
                sum_2 += runs[ index_2++ ].delta;
            float visibility = ( fminf(fabsf(sum_1), 1.0f) *
                                 fminf(fabsf(sum_2), 1.0f) );
            if ( visibility == last )
                continue;
            size_t lastI = mask.length - 1;
            if ( (mask.length != 0) &&
                 (*mask)[lastI].x == next.x && (*mask)[lastI].y == next.y)
                (*mask)[lastI].delta += visibility - last;
            else {
                pixel_run piece;
                piece = pixel_run(next.x, next.y, visibility-last);
                mask.pushBack(piece);
            }
            last = visibility;
        }
    }

    /**
        Tests whether a point is in or on the current path.
       
        Interior areas are determined by the non-zero winding rule, 
        with all open subpaths treated as implicitly closed by a 
        straight line beforehand. Points exactly on the boundary are 
        also considered inside. The point to test is interpreted 
        without being affected by the current transform, nor is the 
        clip region considered. The current path is left unchanged by 
        this test.
       
        Params:
            x  Horizontal coordinate of the point to test.
            y  Vertical coordinate of the point to test.
        Returns: `true` if the point is in or on the current path.
    */       
    bool isPointInPath(float x, float y) {
        path_to_lines( false );
        int winding = 0;

        size_t subpath = 0;
        size_t beginning = 0;
        size_t ending = 0;

        xy[] points = lines.points[];
        for (size_t i = 0; i < points.length; ++i) {
            while ( i >= ending ) {
                beginning = ending;
                ending += lines.subpaths[subpath++].count;
            }
            xy A = points[i];
            xy B = points[i + 1 < ending ? i + 1 : beginning];

            if ( (A.y < y && y <= B.y) || (B.y < y && y <= A.y) ) {
                float side = dot(perpendicular(B - A), xy(x, y) - A);
                if (side == 0.0f)
                    return true;
                winding += side > 0.0f ? 1 : -1;
            }
            else if ( A.y == y && y == B.y &&
                  ( ( A.x <= x && x <= B.x ) ||
                    ( B.x <= x && x <= A.x ) ) )
                return true;
        }
        return winding != 0;
    }
    ///ditto
    bool isPointInPath(T)(T p) {
        return isPointInPath(p.x, p.y);
    }


    // ======== DRAWING RECTANGLES ========


    /**
        Clear a rectangular area back to transparent black.
       
        The clip region may limit the area cleared. The current path 
        is not affected by this clearing. The current transform at the 
        time that this is called will affect the given point and 
        rectangle. The width and/or the height may be negative or 
        zero. If either is zero, or the current transform is not 
        invertible, this does nothing.
       
        Params:
            x       Horizontal coordinate of rectangle corner.
            y       Vertical coordinate of rectangle corner.
            width   Width of the rectangle.
            height  Height of the rectangle.
    */       
    void clearRect(float x, float y, float width, float height) {

        CompositeOperation saved_operation = current.global_op;
        float saved_global_alpha           = current.global_alpha;
        float saved_alpha                  = current.shadow_color.a;
        paint_brush.types saved_type       = current.fill_brush.type;
        
        current.global_op       = CompositeOperation.destinationOut;
        current.global_alpha    = 1.0f;
        current.shadow_color.a  = 0.0f;
        current.fill_brush.type = paint_brush.types.color;

        fillRect(x, y, width, height);

        current.fill_brush.type = saved_type;
        current.shadow_color.a  = saved_alpha;
        current.global_alpha    = saved_global_alpha;
        current.global_op       = saved_operation;
    }


    /**
        Fill a rectangular area.

        This behaves as though the current path were reset to a single
        rectangle and then filled as usual. However, the current path 
        is not actually changed. The current transform at the time 
        that this is called will affect the given point and rectangle.  
        The width and/or the height may be negative but not zero.  
        If either is zero, or the current transform is not invertible, 
        this does nothing.
       
        Params:
            x   Horizontal coordinate of a rectangle corner.
            y   Vertical coordinate of a rectangle corner.
            w   Width of the rectangle.
            h   Height of the rectangle.
    */       
    void fillRect(float x, float y, float w, float h) {

        if (w == 0 || h == 0)
            return;

        Vec!xy* points = &lines.points;
        points.clearContents();
        lines.subpaths.clearContents();
        // PERF
        points.pushBack(forwardTransform(xy(x, y)));
        points.pushBack(forwardTransform(xy(x + w, y)));
        points.pushBack(forwardTransform(xy(x + w, y + h)));
        points.pushBack(forwardTransform(xy(x, y + h)));
        subpath_data entry = subpath_data(4, true);
        lines.subpaths.pushBack(entry);
        render_main(current.fill_brush);
    }


    /** 
        Stroke a rectangular area.
       
        This behaves as though the current path were reset to a single
        rectangle and then stroked as usual.  However, the current 
        path is not actually changed. The current transform at the 
        time that this is called will affect the given point and 
        rectangle. The width and/or the height may be negative or 
        zero. If both are zero, or the current transform is not 
        invertible, this does nothing. If only one is zero, this 
        behaves as though it strokes a single horizontal or vertical 
        line.
       
        Params:
            x  Horizontal coordinate of a rectangle corner.
            y  Vertical coordinate of a rectangle corner.
            w  Width of the rectangle.
            h  Height of the rectangle.
    */       
    void strokeRect(float x, float y, float w, float h) {
        if ( w == 0.0f && h == 0.0f )
            return;
        Vec!xy* points = &lines.points;
        points.clearContents();
        lines.subpaths.clearContents();
        if ( w == 0.0f || h == 0.0f ) {
            points.pushBack(forwardTransform(xy(  x, y  )));
            points.pushBack(forwardTransform(xy(x+w, y+h)));
            subpath_data entry = subpath_data(2, false);
            lines.subpaths.pushBack( entry );
        }
        else {
            points.pushBack(forwardTransform(xy(  x, y  )));
            points.pushBack(forwardTransform(xy(x+w, y  )));
            points.pushBack(forwardTransform(xy(x+w, y+h)));
            points.pushBack(forwardTransform(xy(  x, y+h)));
            points.pushBack(forwardTransform(xy(  x, y  )));
            subpath_data entry = { 5, true };
            lines.subpaths.pushBack(entry);
        }
        stroke_lines();
        render_main(current.stroke_brush);
    }


    // ======== DRAWING TEXT ========


    /** 
        Set the font to use for text drawing.

        The font must be a TrueType font (TTF) file which has been 
        loaded or mapped into memory.  Following some basic 
        validation, the relevant sections of the font file contents 
        are copied, and it is safe to change or destroy after this 
        call. As an optimization, calling this with either a null 
        pointer or zero for the number of bytes will allow for 
        changing the size of the previous font without recopying from
        the file.  Note that the font parsing is not meant to be 
        secure; only use this with trusted TTF files!
       
        Params:
            font   Contents of a TrueType font (TTF) file.
            bytes  Number of bytes in the font file.
            size   Size in pixels per em to draw at.

        Returns: 
            `true` if the font was set successfully.
    */       
    bool setFont(const(ubyte) *font, int bytes, float size) {

        if ( font && bytes ) {
            current.face.data.clearContents();
            current.face.cmap = 0;
            current.face.glyf = 0;
            current.face.head = 0;
            current.face.hhea = 0;
            current.face.hmtx = 0;
            current.face.loca = 0;
            current.face.maxp = 0;
            current.face.os_2 = 0;
            if ( bytes < 6 )
                return false;
            int version_ = ( font[ 0 ] << 24 | font[ 1 ] << 16 |
                            font[ 2 ] <<  8 | font[ 3 ] <<  0 );
            int tables = font[ 4 ] << 8 | font[ 5 ];
            if ( ( version_ != 0x00010000 && version_ != 0x74727565 ) 
                || bytes < tables * 16 + 12 )
                return false;

            foreach(ubyte b; font[0..tables*16+12])
                current.face.data.pushBack(b);

            //face.data.insert( face.data.end(), font, 
            //                  font + tables * 16 + 12 );
            for ( int index = 0; index < tables; ++index )
            {
                int tag = signed_32(current.face.data, index * 16 + 12);
                int ofs = signed_32(current.face.data, index * 16 + 20);
                int span = signed_32(current.face.data, index * 16 + 24);
                if ( bytes < ofs + span )
                {
                    current.face.data.clearContents();
                    return false;
                }
                int place = cast(int)( current.face.data.length() );
                if ( tag == 0x636d6170 )
                    current.face.cmap = place;
                else if ( tag == 0x676c7966 )
                    current.face.glyf = place;
                else if ( tag == 0x68656164 )
                    current.face.head = place;
                else if ( tag == 0x68686561 )
                    current.face.hhea = place;
                else if ( tag == 0x686d7478 )
                    current.face.hmtx = place;
                else if ( tag == 0x6c6f6361 )
                    current.face.loca = place;
                else if ( tag == 0x6d617870 )
                    current.face.maxp = place;
                else if ( tag == 0x4f532f32 )
                    current.face.os_2 = place;
                else
                    continue;
                foreach(ubyte b; font[ofs..ofs+span])
                    current.face.data.pushBack(b);
            }
            if ( !current.face.cmap || !current.face.glyf 
                 || !current.face.head || !current.face.hhea 
                 || !current.face.hmtx || !current.face.loca 
                 || !current.face.maxp || !current.face.os_2 )
            {
                current.face.data.clearContents();
                return false;
            }
        }
        if ( current.face.data.length == 0 )
            return false;
        int units_per_em = unsigned_16( current.face.data, 
                                        current.face.head + 18 );
        current.face.scale = size / cast(float)( units_per_em );
        return true;
    }


    /**
        Draw a line of text by filling its outline.
       
        This behaves as though the current path were reset to the 
        outline of the given text in the current font and size, 
        positioned relative to the given anchor point according to the 
        current alignment and baseline, and then filled as usual. 
        However, the current path is not actually changed. The current
        transform at the time that this is called will affect the 
        given anchor point and the text outline. However, the 
        comparison to the maximum width in pixels and the condensing 
        if needed is done before applying the current transform.
        The maximum width (if given) must be positive. 
        If it is not, or the text pointer is null, or the font has not 
        been set yet, or the last setting of it was unsuccessful, or 
        the current transform is not invertible, this does nothing.
       
        Params:
            text      Null-terminated UTF-8 string of text to fill.
            x         Horizontal coordinate of the anchor point.
            y         Vertical coordinate of the anchor point.
            maxWidth  Horizontal width to condense wider text to.
    */
    // TODO: take regular D string instead
    void fillText(const(char)* text, float x, float y, 
                  float maxWidth = 1.0e30f) {
        text_to_lines(text, xy(x, y), maxWidth, false);
        render_main(current.fill_brush);
    }

    /** 
        Draw a line of text by stroking its outline.

        This behaves as though the current path were reset to the 
        outline of the given text in the current font and size, 
        positioned relative to the given anchor point according to the 
        current alignment and baseline, and then stroked as usual. 
        However, the current path is not actually changed. The current
        transform at the time that this is called will affect the 
        given anchor point and the text outline. 
        However, the comparison to the maximum width in pixels and the
        condensing if needed is done before applying the current 
        transform. The maximum width (if given) must be positive. 
        If it is not, or the text pointer is null, or the font has not 
        been set yet, or the last setting of it was unsuccessful, or 
        the current transform is not invertible, this does nothing.
        
        Params:
            text      Null-terminated UTF-8 string to stroke.
            x         Horizontal coordinate of the anchor point.
            y         Vertical coordinate of the anchor point.
            maxWidth  Horizontal width to condense wider text to.
    */       
    void stroke_text(const(char)* text, 
                     float x, float y, 
                     float maxWidth = 1.0e30f) {
        text_to_lines(text, xy(x, y), maxWidth, true);
        stroke_lines();
        render_main(current.stroke_brush);
    }

    /**
        Measure the width in pixels of a line of text.

        The measured width is the advance width, which includes the 
        side bearings of the first and last glyphs.  However, text as 
        drawn may go outside this (e.g., due to glyphs that spill 
        beyond their nominal widths or stroked text with wide lines).  
        Measurements ignore the current transform.  If the text 
        pointer is null, or the font has not been set yet, or the last 
        setting of it was unsuccessful, this returns zero.

        Params:
            text  Null-terminated UTF-8 string to measure.

        Returns:
            Width of the text in pixels.
        FUTURE: more metrics, use a font API in another package
    */
    float measure_text(const(char)* text) {
        if ( (current.face.data.length == 0) || !text )
            return 0.0f;
        int hmetrics = unsigned_16(current.face.data, 
                                   current.face.hhea+34);
        int width = 0;
        for ( int index = 0; text[index]; ) {
            int glyph = character_to_glyph(text, index);
            int entry = min_int( glyph, hmetrics - 1 );
            width += unsigned_16(current.face.data, 
                                 current.face.hmtx+entry*4);
        }
        return cast(float)(width) * current.face.scale;
    }

    // ======== DRAWING IMAGES ========

    /** 
        Draw an image onto the canvas.
       
        The position of the rectangle that the image is drawn to is 
        affected by the current transform at the time of drawing, and 
        the image will be resampled as needed (with the filtering 
        always clamping to the edges of the image). The drawing is 
        also affected by the shadow, global alpha, global compositing 
        operation settings, and by the clip region. The current path 
        is not affected by drawing an image. The image data, which 
        should be in top to bottom rows of contiguous pixels from left 
        to right, is not retained and it is safe to change or destroy 
        it after this call. The width and height must both be positive 
        and the width and/or the height to scale to may be negative 
        but not zero. Otherwise, or if the image pointer is null, or 
        the current transform is not invertible, this does nothing.
       
        Note: to use a small piece of a larger image, reduce the width 
              and height, and offset the image pointer while keeping 
              the stride.
       
        Params:
            image      Unpremultiplied sRGB RGBA8 image data.
            width      Width of the image in pixels.
            height     Height of the image in pixels.
            stride     Bytes between the start of each image row.
            x          Horizontal coordinate to draw the corner at.
            y          Vertical coordinate to draw the corner at.
            to_width   Width to scale the image to.
            to_height  Height to scale the image to.
    */       
    void drawImage(const(ubyte)* image,
                   int width,
                   int height,
                   int stride,
                   float x,
                   float y,
                   float to_width,
                   float to_height) {
        if (!image || width <= 0 || height <= 0 ||
             to_width == 0.0f || to_height == 0.0f)
            return;
        swap_brush(current.fill_brush, image_brush, temp_brush);
        setPattern(brush_type.fill_style, image, width, height, 
                  stride, repetition_style.repeat);
        swap_brush(current.fill_brush, image_brush, temp_brush);
        Vec!xy* pts = &lines.points;
        pts.clearContents();
        lines.subpaths.clearContents();
        pts.pushBack(forwardTransform(xy(x, y )));
        pts.pushBack(forwardTransform(xy(x+to_width, y)));
        pts.pushBack(forwardTransform(xy(x+to_width, y+to_height)));
        pts.pushBack(forwardTransform(xy(x, y+to_height)));
        subpath_data entry = subpath_data(4, true);
        lines.subpaths.pushBack(entry);
        affine_matrix saved_forward = current.forward;
        affine_matrix saved_inverse = current.inverse;
        translate( x + fminf( 0.0f, to_width ),
                   y + fminf( 0.0f, to_height ) );
        scale( fabsf( to_width ) / cast(float)( width ),
               fabsf( to_height ) / cast(float)( height ) );
        render_main( image_brush );
        current.forward = saved_forward;
        current.inverse = saved_inverse;
    }


    // ======== PIXEL MANIPULATION ========

    // Note: in original canvas_ity, there is a getImageData call,
    // and putImageData call, because the buffer is internal. 
    // Dithering is applied on 
    // export using this as luminance offset (index by [y&3][x&3])
    // divided by 255.
    // But if we dither on each operation, the offset will 
    // accumulate?
    //
    // static immutable float[4][4] bayer = [
    //     [ 0.03125f, 0.53125f, 0.15625f, 0.65625f ],
    //     [ 0.78125f, 0.28125f, 0.90625f, 0.40625f ],
    //     [ 0.21875f, 0.71875f, 0.09375f, 0.59375f ],
    //     [ 0.96875f, 0.46875f, 0.84375f, 0.34375f ] 
    // ];

    // ======== CANVAS STATE ========

    // Maximum number of times you can call save() and have things restored.
    // If you exceed this limit, it will crash.
    enum maxSaveRestoreDepth = 15;

    /** 
        Save the current state as though to a stack.

        The full state of the canvas is saved, except for the pixels 
        in the canvas buffer, and the current path.

        TODO: this isn't strictly true, as the pattern image isn't 
              saved.
       
        Tip: to be able to reset the current clip region, save the 
             canvas state first before clipping then restore the state 
             to reset it.
    */       
    void save()
    {
        // PERF: state index into resources and just hold an index
        // to brushes/fonts/gradients.

        // PERF: states are still kept in the stack, so that their 
        // allocations are reused
        // First push a .init state without data
        int lastTop = _stateCount++;
        _state[lastTop + 1] = _state[lastTop];
        assert(_stateCount <= maxSaveRestoreDepth);
    }

    /**
        Restore a previously saved state as though from a stack.
    */
    void restore() {

        // too many restore() without corresponding save()
        if (_stateCount == 0)
            assert(false); 

        _stateCount--;
    }

    // non-copyable
    @disable this(this);

private:

    enum brush_type 
    { 
        fill_style, 
        stroke_style
    }

    int size_x;
    int size_y;

    xy forwardTransform(xy pt)
    {
        return matrix_mul_vec(current.forward, pt);
    }

    xy inverseTransform(xy pt)
    {
        return matrix_mul_vec(current.inverse, pt);
    }

    // Canvas state. It is store on a stack by `save`/`restore` calls.
    struct State 
    {
    nothrow @nogc:
        @disable this(this);
        CompositeOperation global_op = CompositeOperation.sourceOver;
        float shadow_offset_x        = 0.0f;
        float shadow_offset_y        = 0.0f;
        LineCap line_cap             = LineCap.butt;
        LineJoin line_join           = LineJoin.miter;
        float line_dash_offset       = 0.0f;
        align_style text_align       = align_style.start;
        baseline_style text_baseline = baseline_style.alphabetic;
        affine_matrix forward        = affine_matrix.identity;
        affine_matrix inverse        = affine_matrix.identity;
        float global_alpha           = 1.0f;
        rgba shadow_color            = rgba(0.0f, 0.0f, 0.0f, 0.0f);
        float shadow_blur            = 0.0f;
        float line_width             = 1.0f;
        float miter_limit            = 10.0f;
        Vec!float line_dash;
        paint_brush fill_brush;
        paint_brush stroke_brush;
        Vec!pixel_run mask;
        font_face face;

        // that assign ensures amortized allocation by reusing vectors
        void opAssign(ref const(State) other)
        {
            this.global_op        = other.global_op;
            this.shadow_offset_x  = other.shadow_offset_x;
            this.shadow_offset_y  = other.shadow_offset_y;
            this.line_cap         = other.line_cap;
            this.line_join        = other.line_join;
            this.line_dash_offset = other.line_dash_offset;
            this.text_align       = other.text_align;
            this.text_baseline    = other.text_baseline;
            this.forward          = other.forward;
            this.inverse          = other.inverse;
            this.global_alpha     = other.global_alpha;
            this.shadow_color     = other.shadow_color;
            this.shadow_blur      = other.shadow_blur;
            this.line_width       = other.line_width;
            this.miter_limit      = other.miter_limit;
            assign_vec!float(this.line_dash, other.line_dash);
            this.fill_brush       = other.fill_brush;
            this.stroke_brush     = other.stroke_brush;
            assign_vec!pixel_run(this.mask, other.mask);
            this.face = other.face;
        }
    }
    
    paint_brush image_brush; // Note: not sure why not in State
    paint_brush temp_brush;
    bezier_path path;
    line_path lines;
    line_path scratch;
    Vec!pixel_run runs;

    Image outBitmap;

    Vec!float shadow;
    Vec!ubyte scanBuf;
    PixelType interType;
    Vec!ubyte interBuf;

    // State stack.    
    // +1 to be able to call `save()` maxSaveRestoreDepth times.
    int _stateCount = 0;
    State* _state;
    CanvasOptions options;

    // ".current" state is the last element of that stack.
    // Holds current color, transforms, etc.
    State* current() pure {
        return _state + (_stateCount - 1);
    }

    void set_color(brush_type type, float red, float green, 
                                    float blue, float alpha )
    {
        paint_brush* brush = type == brush_type.fill_style ? 
                              &(current.fill_brush) 
                            : &(current.stroke_brush);
        brush.type = paint_brush.types.color;
        brush.colors.clearContents();

        rgba c = rgba(red, green, blue, alpha);
        c = clamped(c);
        fromGammaSpace((&c)[0..1], options.gammaCurve);
        brush.colors.pushBack( premultiplied(c) );
    }

    // Tessellate (at low-level) a cubic Bezier curve and add it to the polyline
    // data.  This recursively splits the curve until two criteria are met
    // (subject to a hard recursion depth limit).  First, the control points
    // must not be farther from the line between the endpoints than the tolerance.
    // By the Bezier convex hull property, this ensures that the distance between
    // the true curve and the polyline approximation will be no more than the
    // tolerance.  Secondly, it takes the cosine of an angular turn limit; the
    // curve will be split until it turns less than this amount.  This is used
    // for stroking, with the angular limit chosen such that the sagita of an arc
    // with that angle and a half-stroke radius will be equal to the tolerance.
    // This keeps expanded strokes approximately within tolerance.  Note that
    // in the base case, it adds the control points as well as the end points.
    // This way, stroke expansion infers the correct tangents from the ends of
    // the polylines.
    //
    void add_tessellation(xy point_1, xy control_1, xy control_2, xy point_2, float angular, int limit )
    {
        enum float tolerance = 0.125f;
        float flatness = tolerance * tolerance;
        xy edge_1 = control_1 - point_1;
        xy edge_2 = control_2 - control_1;
        xy edge_3 = point_2 - control_2;
        xy segment = point_2 - point_1;
        float squared_1 = dot( edge_1, edge_1 );
        float squared_2 = dot( edge_2, edge_2 );
        float squared_3 = dot( edge_3, edge_3 );
        enum float epsilon = 1.0e-4f;
        float length_squared = dot( segment, segment );
        if (length_squared < epsilon) length_squared = epsilon;
        float projection_1 = dot( edge_1, segment ) / length_squared;
        float projection_2 = dot( edge_3, segment ) / length_squared;
        float clamped_1 = projection_1;
        if (clamped_1 < 0) clamped_1 = 0;
        if (clamped_1 > 1) clamped_1 = 1;
        float clamped_2 = projection_2;
        if (clamped_2 < 0) clamped_2 = 0;
        if (clamped_2 > 1) clamped_2 = 1;
        xy to_line_1 = point_1 + clamped_1 * segment - control_1;
        xy to_line_2 = point_2 - clamped_2 * segment - control_2;
        float cosine = 1.0f;
        if ( angular > -1.0f )
        {
            if ( squared_1 * squared_3 != 0.0f )
                cosine = dot( edge_1, edge_3 ) / sqrtf( squared_1 * squared_3 );
            else if ( squared_1 * squared_2 != 0.0f )
                cosine = dot( edge_1, edge_2 ) / sqrtf( squared_1 * squared_2 );
            else if ( squared_2 * squared_3 != 0.0f )
                cosine = dot( edge_2, edge_3 ) / sqrtf( squared_2 * squared_3 );
        }
        if ( ( dot( to_line_1, to_line_1 ) <= flatness &&
               dot( to_line_2, to_line_2 ) <= flatness &&
              cosine >= angular ) ||
             !limit )
        {
            if ( angular > -1.0f && squared_1 != 0.0f )
                lines.points.pushBack( control_1 );
            if ( angular > -1.0f && squared_2 != 0.0f )
                lines.points.pushBack( control_2 );
            if ( angular == -1.0f || squared_3 != 0.0f )
                lines.points.pushBack( point_2 );
            return;
        }
        xy left_1 = lerp( point_1, control_1, 0.5f );
        xy middle = lerp( control_1, control_2, 0.5f );
        xy right_2 = lerp( control_2, point_2, 0.5f );
        xy left_2 = lerp( left_1, middle, 0.5f );
        xy right_1 = lerp( middle, right_2, 0.5f );
        xy split = lerp( left_2, right_1, 0.5f );
        add_tessellation( point_1, left_1, left_2, split, angular, limit - 1 );
        add_tessellation( split, right_1, right_2, point_2, angular, limit - 1 );
    }

    // Tessellate (at high-level) a cubic Bezier curve and add it to the polyline
    // data.  This solves both for the extreme in curvature and for the horizontal
    // and vertical extrema.  It then splits the curve into segments at these
    // points and passes them off to the lower-level recursive tessellation.
    // This preconditioning means the polyline exactly includes any cusps or
    // ends of tight loops without the flatness test needing to locate it via
    // bisection, and the angular limit test can use simple dot products without
    // fear of curves turning more than 90 degrees.
    //
    void add_bezier(xy point_1, xy control_1,
                            xy control_2,
                            xy point_2,
                            float angular )
    {
        xy edge_1 = control_1 - point_1;
        xy edge_2 = control_2 - control_1;
        xy edge_3 = point_2 - control_2;
        if ( dot( edge_1, edge_1 ) == 0.0f &&
             dot( edge_3, edge_3 ) == 0.0f )
        {
            lines.points.pushBack( point_2 );
            return;
        }
        float[7] at = [ 0.0f, 1.0f, 0, 0, 0, 0, 0 ];
        int cuts = 2;
        xy extrema_a = -9.0f * edge_2 + 3.0f * ( point_2 - point_1 );
        xy extrema_b = 6.0f * ( point_1 + control_2 ) - 12.0f * control_1;
        xy extrema_c = 3.0f * edge_1;
        enum float epsilon = 1.0e-4f;
        if ( fabsf( extrema_a.x ) > epsilon )
        {
            float discriminant =
                extrema_b.x * extrema_b.x - 4.0f * extrema_a.x * extrema_c.x;
            if ( discriminant >= 0.0f )
            {
                float sign = extrema_b.x > 0.0f ? 1.0f : -1.0f;
                float term = -extrema_b.x - sign * sqrtf( discriminant );
                float extremum_1 = term / ( 2.0f * extrema_a.x );
                at[ cuts++ ] = extremum_1;
                at[ cuts++ ] = extrema_c.x / ( extrema_a.x * extremum_1 );
            }
        }
        else if ( fabsf( extrema_b.x ) > epsilon )
            at[ cuts++ ] = -extrema_c.x / extrema_b.x;
        if ( fabsf( extrema_a.y ) > epsilon )
        {
            float discriminant =
                extrema_b.y * extrema_b.y - 4.0f * extrema_a.y * extrema_c.y;
            if ( discriminant >= 0.0f )
            {
                float sign = extrema_b.y > 0.0f ? 1.0f : -1.0f;
                float term = -extrema_b.y - sign * sqrtf( discriminant );
                float extremum_1 = term / ( 2.0f * extrema_a.y );
                at[ cuts++ ] = extremum_1;
                at[ cuts++ ] = extrema_c.y / ( extrema_a.y * extremum_1 );
            }
        }
        else if ( fabsf( extrema_b.y ) > epsilon )
            at[ cuts++ ] = -extrema_c.y / extrema_b.y;
        float determinant_1 = dot( perpendicular( edge_1 ), edge_2 );
        float determinant_2 = dot( perpendicular( edge_1 ), edge_3 );
        float determinant_3 = dot( perpendicular( edge_2 ), edge_3 );
        float curve_a = determinant_1 - determinant_2 + determinant_3;
        float curve_b = -2.0f * determinant_1 + determinant_2;
        if ( fabsf( curve_a ) > epsilon &&
             fabsf( curve_b ) > epsilon )
            at[ cuts++ ] = -0.5f * curve_b / curve_a;
        for ( int index = 1; index < cuts; ++index )
        {
            float value = at[ index ];
            int sorted = index - 1;
            for ( ; 0 <= sorted && value < at[ sorted ]; --sorted )
                at[ sorted + 1 ] = at[ sorted ];
            at[ sorted + 1 ] = value;
        }
        xy split_point_1 = point_1;
        for ( int index = 0; index < cuts - 1; ++index )
        {
            if ( !( 0.0f <= at[ index ] && at[ index + 1 ] <= 1.0f &&
                    at[ index ] != at[ index + 1 ] ) )
                continue;
            float ratio = at[ index ] / at[ index + 1 ];
            xy partial_1 = lerp( point_1, control_1, at[ index + 1 ] );
            xy partial_2 = lerp( control_1, control_2, at[ index + 1 ] );
            xy partial_3 = lerp( control_2, point_2, at[ index + 1 ] );
            xy partial_4 = lerp( partial_1, partial_2, at[ index + 1 ] );
            xy partial_5 = lerp( partial_2, partial_3, at[ index + 1 ] );
            xy partial_6 = lerp( partial_1, partial_4, ratio );
            xy split_point_2 = lerp( partial_4, partial_5, at[ index + 1 ] );
            xy split_control_2 = lerp( partial_4, split_point_2, ratio );
            xy split_control_1 = lerp( partial_6, split_control_2, ratio );
            add_tessellation( split_point_1, split_control_1,
                              split_control_2, split_point_2,
                             angular, 20 );
            split_point_1 = split_point_2;
        }
    }


    // Convert the current path to a set of polylines.  This walks over the
    // complete set of subpaths in the current path (stored as sets of cubic
    // Beziers) and converts each Bezier curve segment to a polyline while
    // preserving information about where subpaths begin and end and whether
    // they are closed or open.  This replaces the previous polyline data.
    //
    void path_to_lines(bool stroking )
    {
        enum float tolerance = 0.125f;
        float ratio = tolerance / fmaxf( 0.5f * current.line_width, tolerance );
        float angular = stroking ? ( ratio - 2.0f ) * ratio * 2.0f + 1.0f : -1.0f;
        lines.points.clearContents();
        lines.subpaths.clearContents();
        size_t index = 0;
        size_t ending = 0;
        for ( size_t subpath = 0; subpath < path.subpaths.length; ++subpath )
        {
            ending += path.subpaths[ subpath ].count;
            size_t first = lines.points.length;
            xy point_1 = path.points[ index++ ];
            lines.points.pushBack( point_1 );
            for ( ; index < ending; index += 3 )
            {
                xy control_1 = path.points[ index + 0 ];
                xy control_2 = path.points[ index + 1 ];
                xy point_2 = path.points[ index + 2 ];
                add_bezier( point_1, control_1, control_2, point_2, angular );
                point_1 = point_2;
            }
            subpath_data entry = subpath_data(
                lines.points.length - first,
                path.subpaths[ subpath ].closed );
                lines.subpaths.pushBack( entry );
        }
    }

    // Add a text glyph directly to the polylines.  Given a glyph index, this
    // parses the data for that glyph directly from the TTF glyph data table and
    // immediately tessellates it to a set of a polyline subpaths which it adds
    // to any subpaths already present.  It uses the current transform matrix to
    // transform from the glyph's vertices in font units to the proper size and
    // position on the canvas.
    //
    void add_glyph(
                           int glyph,
                           float angular )
    {
        int loc_format = unsigned_16( current.face.data, current.face.head + 50 );
        int offset = current.face.glyf + ( loc_format ?
                                   signed_32( current.face.data, current.face.loca + glyph * 4 ) :
                                  unsigned_16( current.face.data, current.face.loca + glyph * 2 ) * 2 );
        int next = current.face.glyf + ( loc_format ?
                                 signed_32( current.face.data, current.face.loca + glyph * 4 + 4 ) :
                                unsigned_16( current.face.data, current.face.loca + glyph * 2 + 2 ) * 2 );
        if ( offset == next )
            return;
        int contours = signed_16( current.face.data, offset );
        if ( contours < 0 )
        {
            offset += 10;
            for ( ; ; )
            {
                int flags = unsigned_16( current.face.data, offset );
                int component = unsigned_16( current.face.data, offset + 2 );
                if ( !( flags & 2 ) )
                    return; // Matching points are not supported
                float e = cast( float )( flags & 1 ?
                                                signed_16( current.face.data, offset + 4 ) :
                                               signed_8( current.face.data, offset + 4 ) );
                float f = cast( float )( flags & 1 ?
                                                signed_16( current.face.data, offset + 6 ) :
                                               signed_8( current.face.data, offset + 5 ) );
                offset += flags & 1 ? 8 : 6;
                float a = flags & 200 ? cast( float )(
                                                             signed_16( current.face.data, offset ) ) / 16384.0f : 1.0f;
                float b = flags & 128 ? cast( float )(
                                                             signed_16( current.face.data, offset + 2 ) ) / 16384.0f : 0.0f;
                float c = flags & 128 ? cast( float )(
                                                             signed_16( current.face.data, offset + 4 ) ) / 16384.0f : 0.0f;
                float d = flags & 8 ? a :
                flags & 64 ? cast(float)(
                                                  signed_16( current.face.data, offset + 2 ) ) / 16384.0f :
                flags & 128 ? cast(float)(
                                                   signed_16( current.face.data, offset + 6 ) ) / 16384.0f :
                1.0f;
                offset += flags & 8 ? 2 : flags & 64 ? 4 : flags & 128 ? 8 : 0;
                affine_matrix saved_forward = current.forward;
                affine_matrix saved_inverse = current.inverse;
                transform( a, b, c, d, e, f );
                add_glyph( component, angular );
                current.forward = saved_forward;
                current.inverse = saved_inverse;
                if ( !( flags & 32 ) )
                    return;
            }
        }
        int hmetrics = unsigned_16( current.face.data, current.face.hhea + 34 );
        int left_side_bearing = glyph < hmetrics ?
            signed_16( current.face.data, current.face.hmtx + glyph * 4 + 2 ) :
        signed_16( current.face.data, current.face.hmtx + hmetrics * 2 + glyph * 2 );
        int x_min = signed_16( current.face.data, offset + 2 );
        int points = unsigned_16( current.face.data, offset + 8 + contours * 2 ) + 1;
        int instructions = unsigned_16( current.face.data, offset + 10 + contours * 2 );
        int flags_array = offset + 12 + contours * 2 + instructions;
        int flags_size = 0;
        int x_size = 0;
        for ( int index = 0; index < points; )
        {
            int flags = unsigned_8( current.face.data, flags_array + flags_size++ );
            int repeated = flags & 8 ?
                unsigned_8( current.face.data, flags_array + flags_size++ ) + 1 : 1;
            x_size += repeated * ( flags & 2 ? 1 : flags & 16 ? 0 : 2 );
            index += repeated;
        }
        int x_array = flags_array + flags_size;
        int y_array = x_array + x_size;
        int x = left_side_bearing - x_min;
        int y = 0;
        int flags = 0;
        int repeated = 0;
        int index = 0;
        for ( int contour = 0; contour < contours; ++contour )
        {
            int beginning = index;
            int ending = unsigned_16( current.face.data, offset + 10 + contour * 2 );
            xy begin_point = xy( 0.0f, 0.0f );
            bool begin_on = false;
            xy end_point = xy( 0.0f, 0.0f );
            bool end_on = false;
            size_t first = lines.points.length;
            for ( ; index <= ending; ++index )
            {
                if ( repeated )
                    --repeated;
                else
                {
                    flags = unsigned_8( current.face.data, flags_array++ );
                    if ( flags & 8 )
                        repeated = unsigned_8( current.face.data, flags_array++ );
                }
                if ( flags & 2 )
                    x += ( unsigned_8( current.face.data, x_array ) *
                           ( flags & 16 ? 1 : -1 ) );
                else if ( !( flags & 16 ) )
                    x += signed_16( current.face.data, x_array );
                if ( flags & 4 )
                    y += ( unsigned_8( current.face.data, y_array ) *
                           ( flags & 32 ? 1 : -1 ) );
                else if ( !( flags & 32 ) )
                    y += signed_16( current.face.data, y_array );
                x_array += flags & 2 ? 1 : flags & 16 ? 0 : 2;
                y_array += flags & 4 ? 1 : flags & 32 ? 0 : 2;
                xy point = forwardTransform( xy( cast(float)( x ),
                                         cast(float)( y ) ) );
                int on_curve = flags & 1;
                if ( index == beginning )
                {
                    begin_point = point;
                    begin_on = on_curve != 0;
                    if ( on_curve )
                        lines.points.pushBack( point );
                }
                else
                {
                    xy point_2 = on_curve ? point :
                    lerp( end_point, point, 0.5f );
                    if ( lines.points.length == first ||
                         ( end_on && on_curve ) )
                        lines.points.pushBack( point_2 );
                    else if ( !end_on || on_curve )
                    {
                        xy point_1 = lines.points[$-1];
                        xy control_1 = lerp( point_1, end_point, 2.0f / 3.0f );
                        xy control_2 = lerp( point_2, end_point, 2.0f / 3.0f );
                        add_bezier( point_1, control_1, control_2, point_2,
                                    angular );
                    }
                }
                end_point = point;
                end_on = on_curve != 0;
            }
            if ( begin_on ^ end_on )
            {
                xy point_1 = lines.points[$-1];
                xy point_2 = lines.points[ first ];
                xy control = end_on ? begin_point : end_point;
                xy control_1 = lerp( point_1, control, 2.0f / 3.0f );
                xy control_2 = lerp( point_2, control, 2.0f / 3.0f );
                add_bezier( point_1, control_1, control_2, point_2, angular );
            }
            else if ( !begin_on && !end_on )
            {
                xy point_1 = lines.points[$-1];
                xy split = lerp( begin_point, end_point, 0.5f );
                xy point_2 = lines.points[ first ];
                xy left_1 = lerp( point_1, end_point, 2.0f / 3.0f );
                xy left_2 = lerp( split, end_point, 2.0f / 3.0f );
                xy right_1 = lerp( split, begin_point, 2.0f / 3.0f );
                xy right_2 = lerp( point_2, begin_point, 2.0f / 3.0f );
                add_bezier( point_1, left_1, left_2, split, angular );
                add_bezier( split, right_1, right_2, point_2, angular );
            }
            lines.points.pushBack( lines.points[ first ] );
            subpath_data entry = subpath_data(lines.points.length - first, true);
            lines.subpaths.pushBack( entry );
        }
    }

    // Decode the next codepoint from a null-terminated UTF-8 string to its glyph
    // index within the font.  The index to the next codepoint in the string
    // is advanced accordingly.  It checks for valid UTF-8 encoding, but not
    // for valid unicode codepoints.  Where it finds an invalid encoding, it
    // decodes it as the Unicode replacement character (U+FFFD) and advances to
    // the invalid byte, per Unicode recommendation.  It also replaces low-ASCII
    // whitespace characters with regular spaces.  After decoding the codepoint,
    // it looks up the corresponding glyph index from the current font's character
    // map table, returning a glyph index of 0 for the .notdef character (i.e.,
    // "tofu") if the font lacks a glyph for that codepoint.
    //
    int character_to_glyph(const(char)* text, ref int index )
    {
        int bytes = ( ( text[ index ] & 0x80 ) == 0x00 ? 1 :
                      ( text[ index ] & 0xe0 ) == 0xc0 ? 2 :
                     ( text[ index ] & 0xf0 ) == 0xe0 ? 3 :
                     ( text[ index ] & 0xf8 ) == 0xf0 ? 4 :
                     0 );
        const int[5] masks = [ 0x0, 0x7f, 0x1f, 0x0f, 0x07 ];
        int codepoint = bytes ? text[ index ] & masks[ bytes ] : 0xfffd;
        ++index;
        while ( --bytes > 0 )
            if ( ( text[ index ] & 0xc0 ) == 0x80 )
                codepoint = codepoint << 6 | ( text[ index++ ] & 0x3f );
            else
            {
                codepoint = 0xfffd;
                break;
            }
        if ( codepoint == '\t' || codepoint == '\v' || codepoint == '\f' ||
             codepoint == '\r' || codepoint == '\n' )
            codepoint = ' ';
        int tables = unsigned_16( current.face.data, current.face.cmap + 2 );
        int format_12 = 0;
        int format_4 = 0;
        int format_0 = 0;
        for ( int table = 0; table < tables; ++table )
        {
            int platform = unsigned_16( current.face.data, current.face.cmap + table * 8 + 4 );
            int encoding = unsigned_16( current.face.data, current.face.cmap + table * 8 + 6 );
            int offset = signed_32( current.face.data, current.face.cmap + table * 8 + 8 );
            int format = unsigned_16( current.face.data, current.face.cmap + offset );
            if ( platform == 3 && encoding == 10 && format == 12 )
                format_12 = current.face.cmap + offset;
            else if ( platform == 3 && encoding == 1 && format == 4 )
                format_4 = current.face.cmap + offset;
            else if ( format == 0 )
                format_0 = current.face.cmap + offset;
        }
        if ( format_12 )
        {
            int groups = signed_32( current.face.data, format_12 + 12 );
            for ( int group = 0; group < groups; ++group )
            {
                int start = signed_32( current.face.data, format_12 + 16 + group * 12 );
                int end = signed_32( current.face.data, format_12 + 20 + group * 12 );
                int glyph = signed_32( current.face.data, format_12 + 24 + group * 12 );
                if ( start <= codepoint && codepoint <= end )
                    return codepoint - start + glyph;
            }
        }
        else if ( format_4 )
        {
            int segments = unsigned_16( current.face.data, format_4 + 6 );
            int end_array = format_4 + 14;
            int start_array = end_array + 2 + segments;
            int delta_array = start_array + segments;
            int range_array = delta_array + segments;
            for ( int segment = 0; segment < segments; segment += 2 )
            {
                int start = unsigned_16( current.face.data, start_array + segment );
                int end = unsigned_16( current.face.data, end_array + segment );
                int delta = signed_16( current.face.data, delta_array + segment );
                int range = unsigned_16( current.face.data, range_array + segment );
                if ( start <= codepoint && codepoint <= end )
                    return range ?
                        unsigned_16( current.face.data, range_array + segment +
                                     ( codepoint - start ) * 2 + range ) :
                ( codepoint + delta ) & 0xffff;
            }
        }
        else if ( format_0 && 0 <= codepoint && codepoint < 256 )
            return unsigned_8( current.face.data, format_0 + 6 + codepoint );
        return 0;
    }

    // Convert a text string to a set of polylines.  This works out the placement
    // of the text string relative to the anchor position.  Then it walks through
    // the string, sizing and placing each character by temporarily changing the
    // current transform matrix to map from font units to canvas pixel coordinates
    // before adding the glyph to the polylines.  This replaces the previous
    // polyline data.
    //
    void text_to_lines(const(char)* text, xy position, float maximum_width, bool stroking )
    {
        enum float tolerance = 0.125f;
        float ratio = tolerance / fmaxf( 0.5f * current.line_width, tolerance );
        float angular = stroking ? ( ratio - 2.0f ) * ratio * 2.0f + 1.0f : -1.0f;
        lines.points.clearContents();
        lines.subpaths.clearContents();
        if ( (current.face.data.length == 0) || !text || maximum_width <= 0.0f )
            return;
        float width = maximum_width == 1.0e30f && current.text_align == align_style.leftward ? 0.0f :
        measure_text( text );
        float reduction = maximum_width / fmaxf( maximum_width, width );
        if ( current.text_align == align_style.rightward )
            position.x -= width * reduction;
        else if ( current.text_align == align_style.center )
            position.x -= 0.5f * width * reduction;
        xy scaling = current.face.scale * xy( reduction, 1.0f );
        float units_per_em = cast(float)(
                                         unsigned_16( current.face.data, current.face.head + 18 ) );
        float ascender = cast(float)(
                                     signed_16( current.face.data, current.face.os_2 + 68 ) );
        float descender = cast(float)(
                                      signed_16( current.face.data, current.face.os_2 + 70 ) );
        float normalize = current.face.scale * units_per_em / ( ascender - descender );
        if ( current.text_baseline == baseline_style.top )
            position.y += ascender * normalize;
        else if ( current.text_baseline == baseline_style.middle )
            position.y += ( ascender + descender ) * 0.5f * normalize;
        else if ( current.text_baseline == baseline_style.bottom )
            position.y += descender * normalize;
        else if ( current.text_baseline == baseline_style.hanging )
            position.y += 0.6f * current.face.scale * units_per_em;
        affine_matrix saved_forward = current.forward;
        affine_matrix saved_inverse = current.inverse;
        int hmetrics = unsigned_16( current.face.data, current.face.hhea + 34 );
        int place = 0;
        for ( int index = 0; text[ index ]; )
        {
            int glyph = character_to_glyph( text, index );
            current.forward = saved_forward;
            transform( scaling.x, 0.0f, 0.0f, -scaling.y,
                       position.x + cast(float)( place ) * scaling.x,
                      position.y );
            add_glyph( glyph, angular );
            int entry = min_int( glyph, hmetrics - 1 );
            place += unsigned_16( current.face.data, current.face.hmtx + entry * 4 );
        }
        current.forward = saved_forward;
        current.inverse = saved_inverse;
    }    


    // Break the polylines into smaller pieces according to the dash settings.
    // This walks along the polyline subpaths and dash pattern together, emitting
    // new points via lerping where dash segments begin and end.  Each dash
    // segment becomes a new open subpath in the polyline.  Some care is to
    // taken to handle two special cases of closed subpaths.  First, those that
    // are completely within the first dash segment should be emitted as-is and
    // remain closed.  Secondly, those that start and end within a dash should
    // have the two dashes merged together so that the lines join.  This replaces
    // the previous polyline data.
    //
    void dash_lines()
    {
        if ( current.line_dash.length == 0 )
            return;

        assign_vec!xy(scratch.points, lines.points);
        lines.points.clearContents();

        assign_vec!subpath_data(scratch.subpaths, lines.subpaths);
        lines.subpaths.clearContents();

        float total = 0;
        foreach(ld; current.line_dash[])
        {
            total += ld;
        }
        float offset = fmodf( current.line_dash_offset, total );
        if ( offset < 0.0f )
            offset += total;
        size_t start = 0;
        while ( offset >= current.line_dash[ start ] )
        {
            offset -= current.line_dash[ start ];
            start = start + 1 < current.line_dash.length ? start + 1 : 0;
        }
        size_t ending = 0;
        for ( size_t subpath = 0; subpath < scratch.subpaths.length; ++subpath )
        {
            size_t index = ending;
            ending += scratch.subpaths[ subpath ].count;
            size_t first = lines.points.length;
            size_t segment = start;
            bool emit = ~start & 1;
            size_t merge_point = lines.points.length;
            size_t merge_subpath = lines.subpaths.length;
            bool merge_emit = emit;
            float next = current.line_dash[ start ] - offset;
            for ( ; index + 1 < ending; ++index )
            {
                xy from = scratch.points[ index ];
                xy to = scratch.points[ index + 1 ];
                if ( emit )
                    lines.points.pushBack( from );
                float line = length( inverseTransform(to) - inverseTransform(from) );
                while ( next < line )
                {
                    lines.points.pushBack( lerp( from, to, next / line ) );
                    if ( emit )
                    {
                        subpath_data entry = {
                            lines.points.length - first, false };
                            lines.subpaths.pushBack( entry );
                            first = lines.points.length;
                    }
                    segment = segment + 1 < current.line_dash.length ? segment + 1 : 0;
                    emit = !emit;
                    next += current.line_dash[ segment ];
                }
                next -= line;
            }
            if ( emit )
            {
                lines.points.pushBack( scratch.points[ index ] );
                subpath_data entry = { lines.points.length - first, false };
                lines.subpaths.pushBack( entry );
                if ( scratch.subpaths[ subpath ].closed && merge_emit )
                {
                    if ( lines.subpaths.length == merge_subpath + 1 )
                        lines.subpaths[$-1].closed = true;
                    else
                    {
                        size_t count = lines.subpaths[$-1].count;
                        rotateArray!xy(lines.points[], merge_point, lines.points.length - count, lines.points.length);
                        lines.subpaths[ merge_subpath ].count += count;
                        lines.subpaths.popBack();
                    }
                }
            }
        }
    }

    // std::rotate translation
    // first  - the beginning of the original range
    // middle - the element that should appear at the beginning of the rotated range
    // last   - the end of the original range
    size_t rotateArray(T)(T[] arr, size_t first, size_t middle, size_t last)
    {
        if (first == middle)
            return last;

        if (middle == last)
            return first;

        size_t write = first;
        size_t next_read = first; // read position for when “read” hits “last”

        for (size_t read = middle; read != last; ++write, ++read)
        {
            if (write == next_read)
                next_read = read; // track where “first” went
            T tmp = arr[write];
            arr[write] = arr[read];
            arr[read] = tmp;
        }

        // rotate the remaining sequence into place
        rotateArray(arr, write, next_read, last);
        return write;
    }

    /*
        Set filling or stroking to draw with an image pattern.

        Initially, pixels in the pattern correspond exactly to pixels 
        on the canvas, with the pattern starting in the upper left. 
        The pattern is affected by the current transform at the time 
        of drawing, and the pattern will be resampled as needed (with 
        the filtering always wrapping regardless of the repetition 
        setting). The pattern can be repeated either horizontally, 
        vertically, both, or neither, relative to the source image. If
        the pattern is not repeated, then beyond it will be considered
        transparent black. The pattern image, which should be in top 
        to bottom rows of contiguous pixels from left to right, is 
        copied and it is safe to change or destroy it after this call.
        The width and height must both be positive. If either are not,
        or the image pointer is null, this does nothing.
       
        Tip: to use a small piece of a larger image, reduce the width 
             and height, and offset the image pointer while keeping 
             the stride.
       
        Params:
            type        Whether to set the fill_style or stroke_style.
            image       Unpremultiplied sRGB RGBA8 image data.
            width       Width of the pattern image in pixels.
            height      Height of the pattern image in pixels.
            stride      Bytes between the start of each image row.
            repetition  repeat, repeat_x, repeat_y, or no_repeat.
    */       
    void setPattern(brush_type type,
                     const(ubyte)* image,
                     int width,
                     int height,
                     int stride,
                     repetition_style repetition) {
        if ( !image || width <= 0 || height <= 0 )
            return;
        paint_brush* brush = type == brush_type.fill_style ? &current.fill_brush : &current.stroke_brush;
        brush.type = paint_brush.types.pattern;
        brush.colors.clearContents();
        for ( int y = 0; y < height; ++y )
            for ( int x = 0; x < width; ++x )
            {
                int index = y * stride + x * 4;
                rgba color = rgba(image[ index + 0 ] / 255.0f, image[ index + 1 ] / 255.0f,
                                  image[ index + 2 ] / 255.0f, image[ index + 3 ] / 255.0f );
                fromGammaSpace((&color)[0..1], options.gammaCurve);
                brush.colors.pushBack( premultiplied( color ) );
            }
        brush.width = width;
        brush.height = height;
        brush.repetition = repetition;
    }


    // Trace along a series of points from a subpath in the scratch polylines
    // and add new points to the main polylines with the stroke expansion on
    // one side.  Calling this again with the ends reversed adds the other
    // half of the stroke.  If the original subpath was closed, each pass
    // adds a complete closed loop, with one adding the inside and one adding
    // the outside.  The two will wind in opposite directions.  If the original
    // subpath was open, each pass ends with one of the line caps and the two
    // passes together form a single closed loop.  In either case, this handles
    // adding line joins, including inner joins.  Care is taken to fill tight
    // inside turns correctly by adding additional windings.  See Figure 10 of
    // "Converting Stroked Primitives to Filled Primitives" by Diego Nehab, for
    // the inspiration for these extra windings.
    //
    void add_half_stroke(size_t beginning, size_t ending, bool closed )
    {
        float half = current.line_width * 0.5f;
        float ratio = current.miter_limit * current.miter_limit * half * half;
        xy in_direction = xy( 0.0f, 0.0f );
        float in_length = 0.0f;
        xy point = inverseTransform(scratch.points[ beginning ]);
        size_t finish = beginning;
        size_t index = beginning;
        do
        {
            xy next = inverseTransform(scratch.points[ index ]);
            xy out_direction = normalized( next - point );
            float out_length = length( next - point );
            enum float epsilon = 1.0e-4f;
            if ( in_length != 0.0f && out_length >= epsilon )
            {
                if ( closed && finish == beginning )
                    finish = index;
                xy side_in = point + half * perpendicular( in_direction );
                xy side_out = point + half * perpendicular( out_direction );
                float turn = dot( perpendicular( in_direction ), out_direction );
                if ( fabsf( turn ) < epsilon )
                    turn = 0.0f;
                xy offset = turn == 0.0f ? xy( 0.0f, 0.0f ) :
                half / turn * ( out_direction - in_direction );
                bool tight = ( dot( offset, in_direction ) < -in_length &&
                               dot( offset, out_direction ) > out_length );
                if ( turn > 0.0f && tight )
                {
                    swap_xy(side_in, side_out );
                    swap_xy( in_direction, out_direction );
                    // PERF
                    lines.points.pushBack( forwardTransform(side_out) );
                    lines.points.pushBack( forwardTransform(point) );
                    lines.points.pushBack( forwardTransform(side_in) );
                }
                if ( ( turn > 0.0f && !tight ) ||
                     ( turn != 0.0f && current.line_join == LineJoin.miter &&
                       dot( offset, offset ) <= ratio ) )
                    lines.points.pushBack( forwardTransform( point + offset ) );
                else if ( current.line_join == LineJoin.round )
                {
                    float cosine = dot( in_direction, out_direction );
                    float angle = acosf(fminf( fmaxf( cosine, -1.0f ), 1.0f ) );
                    float alpha = 4.0f / 3.0f * tanf( 0.25f * angle );
                    lines.points.pushBack( forwardTransform(side_in ));
                    add_bezier(
                               forwardTransform(side_in),
                               forwardTransform(( side_in + alpha * half * in_direction )),
                               forwardTransform(( side_out - alpha * half * out_direction )),
                               forwardTransform(side_out),
                               -1.0f );
                }
                else
                {
                    lines.points.pushBack( forwardTransform(side_in ));
                    lines.points.pushBack( forwardTransform(side_out ));
                }
                if ( turn > 0.0f && tight )
                {
                    lines.points.pushBack( forwardTransform(side_out ));
                    lines.points.pushBack( forwardTransform(point ));
                    lines.points.pushBack( forwardTransform(side_in ));
                    swap_xy( in_direction, out_direction );
                }
            }
            if ( out_length >= epsilon )
            {
                in_direction = out_direction;
                in_length = out_length;
                point = next;
            }
            index = ( index == ending ? beginning :
                      ending > beginning ? index + 1 :
                     index - 1 );
        } while ( index != finish );
        if ( closed || in_length == 0.0f )
            return;
        xy ahead = half * in_direction;
        xy side = perpendicular( ahead );
        if ( current.line_cap == LineCap.butt )
        {
            lines.points.pushBack( forwardTransform(( point + side ) ));
            lines.points.pushBack( forwardTransform(( point - side ) ));
        }
        else if ( current.line_cap == LineCap.square )
        {
            lines.points.pushBack( forwardTransform(( point + ahead + side ) ));
            lines.points.pushBack( forwardTransform(( point + ahead - side ) ));
        }
        else if ( current.line_cap == LineCap.circle )
        {
            enum float alpha = 0.55228475f; // 4/3*tan(pi/8)
            lines.points.pushBack( forwardTransform(( point + side ) ));
            add_bezier( forwardTransform( point + side ),
                        forwardTransform( point + side + alpha * ahead ),
                       forwardTransform( point + ahead + alpha * side ),
                       forwardTransform( point + ahead ),
                       -1.0f );
            add_bezier( forwardTransform( point + ahead ),
                        forwardTransform( point + ahead - alpha * side ),
                       forwardTransform( point - side + alpha * ahead ),
                       forwardTransform( point - side ),
                       -1.0f );
        }
    }

    // Perform stroke expansion on the polylines.  After first breaking them up
    // according to the dash pattern (if any), it then moves the polyline data to
    // the scratch space.  Each subpath is then traced both forwards and backwards
    // to add the points for a half stroke, which together create the points for
    // one (if the original subpath was open) or two (if it was closed) new closed
    // subpaths which, when filled, will draw the stroked lines.  While the lower
    // level code this calls only adds the points of the half strokes, this
    // adds subpath information for the strokes.  This replaces the previous
    // polyline data.
    //
    void stroke_lines()
    {
        affine_matrix fwd = current.forward;
        if ( fwd.a * fwd.d - fwd.b * fwd.c == 0.0f )
            return;
        dash_lines();
        
        assign_vec!xy(scratch.points, lines.points);
        lines.points.clearContents();

        assign_vec!subpath_data(scratch.subpaths, lines.subpaths);
        lines.subpaths.clearContents();

        size_t ending = 0;
        for ( size_t subpath = 0; subpath < scratch.subpaths.length; ++subpath )
        {
            size_t beginning = ending;
            ending += scratch.subpaths[ subpath ].count;
            if ( ending - beginning < 2 )
                continue;
            size_t first = lines.points.length;
            add_half_stroke( beginning, ending - 1,
                             scratch.subpaths[ subpath ].closed );
            if ( scratch.subpaths[ subpath ].closed )
            {
                subpath_data entry = { lines.points.length - first, true };
                lines.subpaths.pushBack( entry );
                first = lines.points.length;
            }
            add_half_stroke( ending - 1, beginning,
                             scratch.subpaths[ subpath ].closed );
            subpath_data entry = { lines.points.length - first, true };
            lines.subpaths.pushBack( entry );
        }
    }

    // Scan-convert a single polyline segment.  This walks along the pixels that
    // the segment touches in left-to-right order, using signed trapezoidal area
    // to accumulate a list of changes in signed coverage at each visible pixel
    // when processing them from left to right.  Each run of horizontal pixels
    // ends with one final update to the right of the last pixel to bring the
    // total up to date.  Note that this does not clip to the screen boundary.
    //
    void add_runs(xy from, xy to )
    {
        enum float epsilon = 2.0e-5f;
        if ( fabsf( to.y - from.y ) < epsilon)
            return;
        float sign = to.y > from.y ? 1.0f : -1.0f;
        if ( from.x > to.x )
            swap_xy( from, to );
        xy now = from;
        xy pixel = xy( floorf( now.x ), floorf( now.y ) );
        xy corner = pixel + xy( 1.0f, to.y > from.y ? 1.0f : 0.0f );
        xy slope = xy( ( to.x - from.x ) / ( to.y - from.y ),
                       ( to.y - from.y ) / ( to.x - from.x ) );
        xy next_x = ( to.x - from.x < epsilon ) ? to :
        xy( corner.x, now.y + ( corner.x - now.x ) * slope.y );
        xy next_y = xy( now.x + ( corner.y - now.y ) * slope.x, corner.y );
        if ( ( from.y < to.y && to.y < next_y.y ) ||
             ( from.y > to.y && to.y > next_y.y ) )
            next_y = to;
        float y_step = to.y > from.y ? 1.0f : -1.0f;
        do
        {
            float carry = 0.0f;
            while ( next_x.x < next_y.x )
            {
                float strip = fminf( fmaxf( ( next_x.y - now.y ) * y_step,
                                                  0.0f ), 1.0f );
                float mid = ( next_x.x + now.x ) * 0.5f;
                float area = ( mid - pixel.x ) * strip;
                pixel_run piece = pixel_run(cast(ushort)pixel.x,
                                            cast(ushort)pixel.y,
                                            ( carry + strip - area ) * sign );
                runs.pushBack( piece );
                carry = area;
                now = next_x;
                next_x.x += 1.0f;
                next_x.y = ( next_x.x - from.x ) * slope.y + from.y;
                pixel.x += 1.0f;
            }
            float strip = fminf( fmaxf( ( next_y.y - now.y ) * y_step,
                                              0.0f ), 1.0f );
            float mid = ( next_y.x + now.x ) * 0.5f;
            float area = ( mid - pixel.x ) * strip;
            pixel_run piece_1 = pixel_run( cast(ushort)pixel.x, cast(ushort)pixel.y, ( carry + strip - area ) * sign );
            pixel_run piece_2 = pixel_run( cast(ushort)(pixel.x + 1.0f ),cast(ushort)pixel.y, area * sign );
            runs.pushBack( piece_1 );
            runs.pushBack( piece_2 );
            now = next_y;
            next_y.y += y_step;
            next_y.x = ( next_y.y - from.y ) * slope.x + from.x;
            pixel.y += y_step;
            if ( ( from.y < to.y && to.y < next_y.y ) ||
                 ( from.y > to.y && to.y > next_y.y ) )
                next_y = to;
        } while ( now.y != to.y );
    }

    // Scan-convert the polylines to prepare them for antialiased rendering.
    // For each of the polyline loops, it first clips them to the screen.
    // See "Reentrant Polygon Clipping" by Sutherland and Hodgman for details.
    // Then it walks the polyline loop and scan-converts each line segment to
    // produce a list of changes in signed pixel coverage when processed in
    // left-to-right, top-to-bottom order.  The list of changes is then sorted
    // into that order, and multiple changes to the same pixel are coalesced
    // by summation.  The result is a sparse, run-length encoded description
    // of the coverage of each pixel to be drawn.
    //
    void lines_to_runs(xy offset, int padding )
    {
        runs.clearContents();
        float width = cast(float)( size_x + padding );
        float height = cast(float)( size_y + padding );
        size_t ending = 0;
        for ( size_t subpath = 0; subpath < lines.subpaths.length; ++subpath )
        {
            size_t beginning = ending;
            ending += lines.subpaths[ subpath ].count;
            scratch.points.clearContents();
            for ( size_t index = beginning; index < ending; ++index )
                scratch.points.pushBack( offset + lines.points[ index ] );
            for ( int edge = 0; edge < 4; ++edge )
            {
                xy normal = xy( edge == 0 ? 1.0f : edge == 2 ? -1.0f : 0.0f,
                                edge == 1 ? 1.0f : edge == 3 ? -1.0f : 0.0f );
                float place = edge == 2 ? width : edge == 3 ? height : 0.0f;
                size_t first = scratch.points.length;
                for ( size_t index = 0; index < first; ++index )
                {
                    xy from = scratch.points[ ( index ? index : first ) - 1 ];
                    xy to = scratch.points[ index ];
                    float from_side = dot( from, normal ) + place;
                    float to_side = dot( to, normal ) + place;
                    if ( from_side * to_side < 0.0f )
                        scratch.points.pushBack( lerp( from, to,
                                                        from_side / ( from_side - to_side ) ) );
                    if ( to_side >= 0.0f )
                        scratch.points.pushBack( to );
                }

                scratch.points.removeAndShiftRestOfArray(0, first);
            }
            size_t last = scratch.points.length;
            for ( size_t index = 0; index < last; ++index )
            {
                xy from = scratch.points[ ( index ? index : last ) - 1 ];
                xy to = scratch.points[ index ];
                add_runs( xy( fminf( fmaxf( from.x, 0.0f ), width ),
                              fminf( fmaxf( from.y, 0.0f ), height ) ),
                          xy( fminf( fmaxf( to.x, 0.0f ), width ),
                              fminf( fmaxf( to.y, 0.0f ), height ) ) );
            }
        }
        if ( runs.isEmpty)
            return;

        // copied here for the sake of being a delegate
        int comparePixelRuns(in pixel_run a, in pixel_run b )
        {
            if (a.y != b.y)
                return a.y - b.y;
            if (a.x != b.x)
                return a.x - b.x;

            float diff = fabsf(a.delta ) - fabsf( b.delta );
            if (diff < 0)
                return -1;
            if (diff > 0)
                return 1;
            return 0;
        }

        timSort!pixel_run(runs[], timsortBuf, &comparePixelRuns); 

        // PERF: why push the pixel runs with delta 0.0f or -0.0f? Sounds
        // like missed opportunity to sort and remove them later.

        size_t to = 0;
        for ( size_t from = 1; from < runs.length; ++from )
        {
            if ( runs[ from ].x == runs[ to ].x && runs[ from ].y == runs[ to ].y )
                runs[ to ].delta += runs[ from ].delta;
            else if ( runs[ from ].delta != 0.0f )
                runs[ ++to ] = runs[ from ];
        }

        to += 1;
        runs.resize(to);
    }

    import dplug.core.vec: Vec;
    private Vec!pixel_run timsortBuf; // used as temp space

    // Paint a pixel according to its point location and a paint style to produce
    // a premultiplied, linearized RGBA color.  This handles all supported paint
    // styles: solid colors, linear gradients, radial gradients, and patterns.
    // For gradients and patterns, it takes into account the current transform.
    // Patterns are resampled using a separable bicubic convolution filter,
    // with edges handled according to the wrap mode.  See "Cubic Convolution
    // Interpolation for Digital Image Processing" by Keys.  This filter is best
    // known for magnification, but also works well for antialiased minification,
    // since it's actually a Catmull-Rom spline approximation of Lanczos-2.
    //
    rgba paint_pixel(xy point, ref const(paint_brush) brush )
    {
        if ( brush.colors.isEmpty() )
            return rgba( 0.0f, 0.0f, 0.0f, 0.0f );
        if ( brush.type == paint_brush.types.color )
            return brush.colors[0];
        point = inverseTransform(point);
        affine_matrix inverse = current.inverse;
        if ( brush.type == paint_brush.types.pattern )
        {
            float width = cast(float)( brush.width );
            float height = cast(float)( brush.height );
            if ( ( ( brush.repetition & 2 ) &&
                   ( point.x < 0.0f || width <= point.x ) ) ||
                 ( ( brush.repetition & 1 ) &&
                   ( point.y < 0.0f || height <= point.y ) ) )
                return rgba( 0.0f, 0.0f, 0.0f, 0.0f );
            float scale_x = fabsf( inverse.a ) + fabsf( inverse.c );
            float scale_y = fabsf( inverse.b ) + fabsf( inverse.d );
            scale_x = fmaxf( 1.0f, fminf( scale_x, width * 0.25f ) );
            scale_y = fmaxf( 1.0f, fminf( scale_y, height * 0.25f ) );
            float reciprocal_x = 1.0f / scale_x;
            float reciprocal_y = 1.0f / scale_y;
            point = point - xy( 0.5f, 0.5f );
            int left = cast(int)( ceilf( point.x - scale_x * 2.0f ) );
            int top = cast(int)( ceilf( point.y - scale_y * 2.0f ) );
            int right = cast(int)( ceilf( point.x + scale_x * 2.0f ) );
            int bottom = cast(int)( ceilf( point.y + scale_y * 2.0f ) );
            rgba total_color = rgba( 0.0f, 0.0f, 0.0f, 0.0f );
            float total_weight = 0.0f;
            for ( int pattern_y = top; pattern_y < bottom; ++pattern_y )
            {
                float y = fabsf( reciprocal_y *
                                 ( cast(float)( pattern_y ) - point.y ) );
                float weight_y = ( y < 1.0f ?
                                   (    1.5f * y - 2.5f ) * y          * y + 1.0f :
                                  ( ( -0.5f * y + 2.5f ) * y - 4.0f ) * y + 2.0f );
                int wrapped_y = pattern_y % brush.height;
                if ( wrapped_y < 0 )
                    wrapped_y += brush.height;
                if ( &brush == &image_brush )
                    wrapped_y = min_int( max_int( pattern_y, 0 ),
                                          brush.height - 1 );
                for ( int pattern_x = left; pattern_x < right; ++pattern_x )
                {
                    float x = fabsf( reciprocal_x *
                                     ( cast(float)( pattern_x ) - point.x ) );
                    float weight_x = ( x < 1.0f ?
                                       (    1.5f * x - 2.5f ) * x          * x + 1.0f :
                                      ( ( -0.5f * x + 2.5f ) * x - 4.0f ) * x + 2.0f );
                    int wrapped_x = pattern_x % brush.width;
                    if ( wrapped_x < 0 )
                        wrapped_x += brush.width;
                    if ( &brush == &image_brush )
                        wrapped_x = min_int( max_int( pattern_x, 0 ),
                                              brush.width - 1 );
                    float weight = weight_x * weight_y;
                    size_t index = cast(size_t)(wrapped_y * brush.width + wrapped_x );
                    total_color = total_color + (weight * brush.colors[ index ]);
                    total_weight += weight;
                }
            }
            return ( 1.0f / total_weight ) * total_color;
        }
        float offset;
        xy relative = point - brush.start;
        xy line = brush.end - brush.start;
        float gradient = dot( relative, line );
        float span = dot( line, line );
        if ( brush.type == paint_brush.types.linear )
        {
            if ( span == 0.0f )
                return rgba( 0.0f, 0.0f, 0.0f, 0.0f );
            offset = gradient / span;
        }
        else
        {
            float initial = brush.start_radius;
            float change = brush.end_radius - initial;
            float a = span - change * change;
            float b = -2.0f * ( gradient + initial * change );
            float c = dot( relative, relative ) - initial * initial;
            float discriminant = b * b - 4.0f * a * c;
            if ( discriminant < 0.0f ||
                 ( span == 0.0f && change == 0.0f ) )
                return rgba( 0.0f, 0.0f, 0.0f, 0.0f );
            float root = sqrtf( discriminant );
            float reciprocal = 1.0f / ( 2.0f * a );
            float offset_1 = ( -b - root ) * reciprocal;
            float offset_2 = ( -b + root ) * reciprocal;
            float radius_1 = initial + change * offset_1;
            float radius_2 = initial + change * offset_2;
            if ( radius_2 >= 0.0f )
                offset = offset_2;
            else if ( radius_1 >= 0.0f )
                offset = offset_1;
            else
                return rgba( 0.0f, 0.0f, 0.0f, 0.0f );
        }

        // Finds the first element in stop that is greater than offset.
        size_t index = brush.stops.length;
        for (size_t i = 0; i < brush.stops.length; ++i)
        {
            if ( brush.stops[i] > offset)
            {
                index = i;
                break;
            }
        }

        if ( index == 0 )
            return premultiplied( brush.colors[0] );
        if ( index == brush.stops.length )
            return premultiplied( brush.colors[$-1] );
        float mix = ( ( offset - brush.stops[ index - 1 ] ) /
                      ( brush.stops[ index ] - brush.stops[ index - 1 ] ) );
        rgba delta = brush.colors[ index ] - brush.colors[ index - 1 ];
        return premultiplied( brush.colors[ index - 1 ] + mix * delta );
    }

    // Render the shadow of the polylines into the pixel buffer if needed.  After
    // computing the border as the maximum distance that one pixel can affect
    // another via the blur, it scan-converts the lines to runs with the shadow
    // offset and that extra amount of border padding.  Then it bounds the scan
    // converted shape, pads this with border, clips that to the extended canvas
    // size, and rasterizes to fill a working area with the alpha.  Next, a fast
    // approximation of a Gaussian blur is done using three passes of box blurs
    // each in the rows and columns.  Note that these box blurs have a small extra
    // weight on the tails to allow for fractional widths.  See "Theoretical
    // Foundations of Gaussian Convolution by Extended Box Filtering" by Gwosdek
    // et al. for details.  Finally, it colors the blurred alpha image with
    // the shadow color and blends this into the pixel buffer according to the
    // compositing settings and clip mask.  Note that it does not bother clearing
    // outside the area of the alpha image when the compositing settings require
    // clearing; that will be done on the subsequent main rendering pass.
    //
    void render_shadow(ref const(paint_brush) brush )
    {
        if ( current.shadow_color.a == 0.0f || ( current.shadow_blur == 0.0f &&
                                         current.shadow_offset_x == 0.0f &&
                                        current.shadow_offset_y == 0.0f ) )
            return;
        float sigma_squared = 0.25f * current.shadow_blur * current.shadow_blur;
        size_t radius = cast(size_t)(
                                              0.5f * sqrtf( 4.0f * sigma_squared + 1.0f ) - 0.5f );
        int border = 3 * ( cast(int)( radius ) + 1 );
        xy offset = xy( cast(float)( border ) + current.shadow_offset_x,
                        cast(float)( border ) + current.shadow_offset_y );
        lines_to_runs( offset, 2 * border );
        int left = size_x + 2 * border;
        int right = 0;
        int top = size_y + 2 * border;
        int bottom = 0;
        for ( size_t index = 0; index < runs.length; ++index )
        {
            left = min_int( left, cast(int)( runs[ index ].x ) );
            right = max_int( right, cast(int)( runs[ index ].x ) );
            top = min_int( top, cast(int)( runs[ index ].y ) );
            bottom = max_int( bottom, cast(int)( runs[ index ].y ) );
        }
        left = max_int( left - border, 0 );
        right = min_int( right + border, size_x + 2 * border ) + 1;
        top = max_int( top - border, 0 );
        bottom = min_int( bottom + border, size_y + 2 * border );
        size_t width = cast(size_t)( max_int( right - left, 0 ) );
        size_t height = cast(size_t)( max_int( bottom - top, 0 ) );
        size_t working = width * height;
        shadow.clearContents();
        shadow.resize( working + max_size_t( width, height ) );
        memset(shadow.ptr, 0, float.sizeof * shadow.length);
        enum float threshold = 1.0f / 8160.0f;
        {
            int x = -1;
            int y = -1;
            float sum = 0.0f;
            for ( size_t index = 0; index < runs.length; ++index )
            {
                pixel_run next = runs[ index ];
                float coverage = fminf( fabsf( sum ), 1.0f );
                int to = next.y == y ? next.x : x + 1;
                if ( coverage >= threshold )
                    for ( ; x < to; ++x )
                        shadow[ cast(size_t)( y - top ) * width +
                                cast(size_t)( x - left ) ] = coverage *
                        paint_pixel( xy( cast(float)( x ) + 0.5f,
                                         cast(float)( y ) + 0.5f ) -
                                     offset, brush ).a;
                if ( next.y != y )
                    sum = 0.0f;
                x = next.x;
                y = next.y;
                sum += next.delta;
            }
        }
        float alpha = cast(float)( 2 * radius + 1 ) *
            ( cast(float)( radius * ( radius + 1 ) ) - sigma_squared ) /
            ( 2.0f * sigma_squared -
              cast(float)( 6 * ( radius + 1 ) * ( radius + 1 ) ) );
        float divisor = 2.0f * ( alpha + cast(float)( radius ) ) + 1.0f;
        float weight_1 = alpha / divisor;
        float weight_2 = ( 1.0f - alpha ) / divisor;
        for ( size_t y = 0; y < height; ++y )
            for ( int pass = 0; pass < 3; ++pass )
            {
                for ( size_t x = 0; x < width; ++x )
                    shadow[ working + x ] = shadow[ y * width + x ];
                float running = weight_1 * shadow[ working + radius + 1 ];
                for ( size_t x = 0; x <= radius; ++x )
                    running += ( weight_1 + weight_2 ) * shadow[ working + x ];
                shadow[ y * width ] = running;
                for ( size_t x = 1; x < width; ++x )
                {
                    if ( x >= radius + 1 )
                        running -= weight_2 * shadow[ working + x - radius - 1 ];
                    if ( x >= radius + 2 )
                        running -= weight_1 * shadow[ working + x - radius - 2 ];
                    if ( x + radius < width )
                        running += weight_2 * shadow[ working + x + radius ];
                    if ( x + radius + 1 < width )
                        running += weight_1 * shadow[ working + x + radius + 1 ];
                    shadow[ y * width + x ] = running;
                }
            }
        for ( size_t x = 0; x < width; ++x )
            for ( int pass = 0; pass < 3; ++pass )
            {
                for ( size_t y = 0; y < height; ++y )
                    shadow[ working + y ] = shadow[ y * width + x ];
                float running = weight_1 * shadow[ working + radius + 1 ];
                for ( size_t y = 0; y <= radius; ++y )
                    running += ( weight_1 + weight_2 ) * shadow[ working + y ];
                shadow[ x ] = running;
                for ( size_t y = 1; y < height; ++y )
                {
                    if ( y >= radius + 1 )
                        running -= weight_2 * shadow[ working + y - radius - 1 ];
                    if ( y >= radius + 2 )
                        running -= weight_1 * shadow[ working + y - radius - 2 ];
                    if ( y + radius < height )
                        running += weight_2 * shadow[ working + y + radius ];
                    if ( y + radius + 1 < height )
                        running += weight_1 * shadow[ working + y + radius + 1 ];
                    shadow[ y * width + x ] = running;
                }
            }
        int operation = current.global_op;
        int x = -1;
        int y = -1;
        float sum = 0.0f;
        for ( size_t index = 0; index < current.mask.length; ++index )
        {
            pixel_run next = current.mask[ index ];
            float visibility = fminf( fabsf( sum ), 1.0f );
            int to = min_int( next.y == y ? next.x : x + 1, right - border );
            if ( visibility >= threshold &&
                 top <= y + border && y + border < bottom ) {

                int x_offset = pixelTypeSize(outBitmap.type()) * x;

                // How many pixels to do at once?
                int scanWidth = to - x;

                // 1. Convert pixels [x..to] to rgbaf32
                scanlinesConvert(outBitmap.type(), 
                                 cast(ubyte*)(outBitmap.scanptr(y)) + x_offset,
                                 outBitmap.pitchInBytes(),
                                 PixelType.rgbaf32,
                                 scanBuf.ptr,
                                 0,
                                 scanWidth,
                                 1,
                                 interType,
                                 interBuf.ptr);

                // 2. Background is made delinearized then premultiplied
                rgba* scan = cast(rgba*) scanBuf.ptr;
                fromGammaSpace(scan[0..scanWidth], options.gammaCurve);
                for(int n = 0; n < scanWidth; ++n)
                {
                    scan[n] = premultiplied(scan[n]);
                }

                // 3. Render shadow
                for(int n = 0; n < scanWidth; ++n)
                {
                    rgba back = scan[n];
                    rgba fore = current.global_alpha *
                        shadow[
                            cast(size_t)( y + border - top ) * width +
                            cast(size_t)( x + n + border - left ) ] *
                        current.shadow_color;
                    float mix_fore = operation & 1 ? back.a : 0.0f;
                    if ( operation & 2 )
                        mix_fore = 1.0f - mix_fore;
                    float mix_back = operation & 4 ? fore.a : 0.0f;
                    if ( operation & 8 )
                        mix_back = 1.0f - mix_back;
                    rgba blend = mix_fore * fore + mix_back * back;
                    blend.a = fminf( blend.a, 1.0f );
                    rgba colout = visibility * blend 
                                + ( 1.0f - visibility ) * back;
                    scan[n] = colout;
                }

                // 4. Unpremultiply and put back in gamma-space.
                for(int n = 0; n < scanWidth; ++n)
                {
                    scan[n] = unpremultiplied(scan[n]);
                }
                toGammaSpace(scan[0..scanWidth], options.gammaCurve);

                // 5. Convert pixels [x..to] to rgbaf32
                scanlinesConvert(PixelType.rgbaf32,
                                 scanBuf.ptr,
                                 0,
                                 outBitmap.type(), 
                                 cast(ubyte*)(outBitmap.scanptr(y)) + x_offset,
                                 outBitmap.pitchInBytes(),

                                 scanWidth,
                                 1,
                                 interType,
                                 interBuf.ptr);

            }

            if ( next.y != y )
                sum = 0.0f;
            x = max_int( cast(int)( next.x ), left - border );
            y = next.y;
            sum += next.delta;
        }
    }

    // Render the polylines into the pixel buffer.  It scan-converts the lines
    // to runs which represent changes to the signed fractional coverage when
    // read from left-to-right, top-to-bottom.  It scans through these to
    // determine spans of pixels that need to be drawn, paints those pixels
    // according to the brush, and then blends them into the buffer according
    // to the current compositing settings.  This is slightly more complicated
    // because it interleaves this with a simultaneous scan through a similar
    // set of runs representing the current clip mask to determine which pixels
    // it can composite into.  Note that shadows are always drawn first.
    //
    void render_main(ref const(paint_brush) brush )
    {
        if ( ! current.forward.isInvertible)
            return;

        render_shadow( brush );
        lines_to_runs( xy( 0.0f, 0.0f ), 0 );
        int operation = current.global_op;
        int x = -1;
        int y = -1;
        float path_sum = 0.0f;
        float clip_sum = 0.0f;
        size_t path_index = 0;
        size_t clip_index = 0;
        while ( clip_index < current.mask.length )
        {
            bool which = ( path_index < runs.length) &&
                           (comparePixelRuns(runs[ path_index ], current.mask[ clip_index ] ) < 0);
            pixel_run next = which ? runs[ path_index ] : current.mask[ clip_index ];
            float coverage = fminf( fabsf( path_sum ), 1.0f );
            float visibility = fminf( fabsf( clip_sum ), 1.0f );
            int to = next.y == y ? next.x : x + 1;
            enum float threshold = 1.0f / 8160.0f;
            if ( ( coverage >= threshold || ~operation & 8 ) &&
                 visibility >= threshold ) {

                int x_offset = pixelTypeSize(outBitmap.type()) * x;

                // How many pixels to do at once?
                int scanWidth = to - x;

                // 1. Convert pixels [x..to] to rgbaf32
                scanlinesConvert(outBitmap.type(), 
                                    cast(ubyte*)(outBitmap.scanptr(y)) + x_offset,
                                    outBitmap.pitchInBytes(),
                                    PixelType.rgbaf32,
                                    scanBuf.ptr,
                                    0,
                                    scanWidth,
                                    1,
                                    interType,
                                    interBuf.ptr);

                // 2. Background is made delinearized then premultiplied
                rgba* scan = cast(rgba*) scanBuf.ptr;
                fromGammaSpace(scan[0..scanWidth], options.gammaCurve);
                for(int n = 0; n < scanWidth; ++n)
                {
                    scan[n] = premultiplied(scan[n]);
                }

                // 3. Render main
                for(int n = 0; n < scanWidth; ++n)
                {
                    rgba back = scan[n];

                    rgba fore = coverage * current.global_alpha *
                        paint_pixel( xy( cast(float)( x ) + 0.5f,
                                            cast(float)( y ) + 0.5f ),
                                        brush );
                    float mix_fore = operation & 1 ? back.a : 0.0f;
                    if ( operation & 2 )
                        mix_fore = 1.0f - mix_fore;
                    float mix_back = operation & 4 ? fore.a : 0.0f;
                    if ( operation & 8 )
                        mix_back = 1.0f - mix_back;
                    rgba blend = mix_fore * fore + mix_back * back;
                    blend.a = fminf( blend.a, 1.0f );

                    rgba colout = visibility * blend 
                        + ( 1.0f - visibility ) * back;
                    scan[n] = colout;
                }

                // 4. Unpremultiply and put back in gamma-space.
                for(int n = 0; n < scanWidth; ++n)
                {
                    scan[n] = unpremultiplied(scan[n]);
                }
                toGammaSpace(scan[0..scanWidth], options.gammaCurve);

                // 5. Convert pixels [x..to] to rgbaf32
                scanlinesConvert(PixelType.rgbaf32,
                                    scanBuf.ptr,
                                    0,
                                    outBitmap.type(), 
                                    cast(ubyte*)(outBitmap.scanptr(y)) + x_offset,
                                    outBitmap.pitchInBytes(),

                                    scanWidth,
                                    1,
                                    interType,
                                    interBuf.ptr);
            }
            x = next.x;
            if ( next.y != y )
            {
                y = next.y;
                path_sum = 0.0f;
                clip_sum = 0.0f;
            }
            if ( which )
                path_sum += runs[ path_index++ ].delta;
            else
                clip_sum += current.mask[ clip_index++ ].delta;
        }
    }
}

// ======== IMPLEMENTATION ========
//
// The general internal data flow (albeit not control flow!) for rendering
// a shape onto the canvas is as follows:
//
// 1. Construct a set of polybeziers representing the current path via the
//      public path building API (move_to, line_to, bezier_curve_to, etc.).
// 2. Adaptively tessellate the polybeziers into polylines (path_to_lines).
// 3. Maybe break the polylines into shorter polylines according to the dash
//      pattern (dash_lines).
// 4. Maybe stroke expand the polylines into new polylines that can be filled
//      to show the lines with width, joins, and caps (stroke_lines).
// 5. Scan-convert the polylines into a sparse representation of fractional
//      pixel coverage (lines_to_runs).
// 6. Maybe paint the covered pixel span alphas "offscreen", blur, color,
//      and blend them onto the canvas where not clipped (render_shadow).
// 7. Paint the covered pixel spans and blend them onto the canvas where not
//      clipped (render_main).



// Helpers for TTF file parsing
int unsigned_8(ref Vec!ubyte data, int index ) 
{
    return data[ cast(size_t)index ]; 
}

int signed_8( ref Vec!ubyte data, int index ) 
{
    size_t place = cast(size_t)( index );
    return cast(byte)(data[ place ]); 
}

int unsigned_16( ref Vec!ubyte data, int index ) {
    size_t place = cast(size_t)( index );
    return data[ place ] << 8 | data[ place + 1 ]; 
}

int signed_16( ref Vec!ubyte data, int index ) 
{
    size_t place = cast(size_t)( index );
    return cast(short)( data[ place ] << 8 | data[ place + 1 ] ); 
}

int signed_32( ref Vec!ubyte data, int index ) 
{
    size_t place = cast(size_t)( index );
    return ( data[ place + 0 ] << 24 | data[ place + 1 ] << 16 |
             data[ place + 2 ] <<  8 | data[ place + 3 ] <<  0 ); 
}

int comparePixelRuns(in pixel_run a, in pixel_run b )
{
    if (a.y != b.y)
        return a.y - b.y;
    if (a.x != b.x)
        return a.x - b.x;

    float diff = fabsf(a.delta ) - fabsf( b.delta );
    if (diff < 0)
        return -1;
    if (diff > 0)
        return 1;
    return 0;
}

// Implementation details
private
{
    template isLikeRGBA8(T)
    {
        enum isLikeRGBA8 = 
              !is(T==RGBA8)
            && T.sizeof == 4 
            && __traits(hasMember, T, "r")
            && __traits(hasMember, T, "g")
            && __traits(hasMember, T, "b")
            && __traits(hasMember, T, "a");
    }

    float fabsf(float a)
    {
        return a >= 0 ? a : -a;
    }
    struct xy
    {
        pure nothrow @nogc @safe:
        float x, y; // nothing seems to rely on .init

        xy opBinary(string op)(float t) const if (op == "*")
        {
            xy r;
            r.x = x * t;
            r.y = y * t;
            return r;
        }

        xy opBinaryRight(string op)(float t) const if (op == "*")
        {
            xy r;
            r.x = x * t;
            r.y = y * t;
            return r;
        }

        xy opBinary(string op)(xy o) const if (op == "+")
        {
            xy r;
            r.x = x + o.x;
            r.y = y + o.y;
            return r;
        }

        xy opBinary(string op)(xy o) const if (op == "-")
        {
            xy r;
            r.x = x - o.x;
            r.y = y - o.y;
            return r;
        }
    }

    xy matrix_mul_vec(const(affine_matrix) left, xy right)
    {
        return xy( left.a * right.x + left.c * right.y + left.e,
                   left.b * right.x + left.d * right.y + left.f );
    }

    float dot(xy left, xy right ) 
    {
        return left.x * right.x + left.y * right.y; 
    }

    float length( xy that ) 
    {
        return sqrtf( dot( that, that ) ); 
    }

    float direction( xy that ) 
    {
        return atan2f( that.y, that.x ); 
    }

    xy normalized( xy that ) 
    {
        float len = length( that );
        float m = fmaxf(len, 1.0e-6f);
        return that * (1.0f / m); 
    }

    xy perpendicular( xy that ) 
    {
        return xy( -that.y, that.x ); 
    }

    xy lerp( xy from, xy to, float ratio ) 
    {
        return from + ( to - from ) * ratio; 
    }

    struct rgba
    {
        pure nothrow @nogc @safe:
        float r, g, b, a;

        rgba opBinary(string op)(float t) const if (op == "*")
        {
            rgba c;
            c.r = r * t;
            c.g = g * t;
            c.b = b * t;
            c.a = a * t;
            return c;
        }

        rgba opBinaryRight(string op)(float t) const if (op == "*")
        {
            rgba c;
            c.r = r * t;
            c.g = g * t;
            c.b = b * t;
            c.a = a * t;
            return c;
        }

        rgba opBinary(string op)(rgba o) const if (op == "+")
        {
            rgba c;
            c.r = r + o.r;
            c.g = g + o.g;
            c.b = b + o.b;
            c.a = a + o.a;
            return c;
        }

        rgba opBinary(string op)(rgba o) const if (op == "-")
        {
            rgba c;
            c.r = r - o.r;
            c.g = g - o.g;
            c.b = b - o.b;
            c.a = a - o.a;
            return c;
        }
    }

/*    float linearized( float value ) 
    {
        return value < 0.04045f ? value / 12.92f :
            _mm_pow_ss( ( value + 0.055f ) / 1.055f, 2.4f ); 
    }

    float delinearized( float value ) 
    {
        return value < 0.0031308f ? 12.92f * value 
            : 1.055f * _mm_pow_ss(value, 1.0f/2.4f) 
            - 0.055f; 
    }
*/
    void fromGammaSpace(rgba[] arr, GammaCurve gammaCurve)
    {
        // Convert sRGB 0 to 1 to linear space 0 to 1
        static rgba linearized( rgba col ) 
        {
            __m128 c = _mm_loadu_ps(cast(float*)&col);
            __m128 top = _mm_pow_ps( _mm_add_ps(c,_mm_set1_ps(0.055f)) * _mm_set1_ps(0.94786729857), _mm_set1_ps(2.4f));
            __m128 bottom = _mm_set1_ps(0.0773993808f) * c;
            __m128 mask = _mm_cmplt_ps(c, _mm_set1_ps(0.04045f));
            c = _mm_or_ps(_mm_and_ps(mask, bottom), _mm_andnot_ps(mask, top));
            c.ptr[3] = col.a;
            _mm_storeu_ps(cast(float*)&col, c);
            return col;
        }


        final switch(gammaCurve)
        {
            case GammaCurve.linear:
                foreach(ref col; arr)
                    col = linearized(col);
                break;
            case GammaCurve.pow2:
                foreach(ref col; arr) {
                    col.r = col.r * col.r;
                    col.g = col.g * col.g;
                    col.b = col.b * col.b;
                }
                break;
            case GammaCurve.none:
                break;
        }
    }

    void toGammaSpace(rgba[] arr, GammaCurve gammaCurve)
    {
        static rgba delinearized(rgba col) 
        {
            __m128 c = _mm_loadu_ps(cast(float*)&col);
            __m128 top = _mm_pow_ps(c, _mm_set1_ps(0.41666666666f)) * _mm_set1_ps(1.055f) - _mm_set1_ps(0.055f);
            __m128 bottom = _mm_set1_ps(12.92f) * c;
            __m128 mask = _mm_cmplt_ps(c, _mm_set1_ps(0.0031308f));
            c = _mm_or_ps(_mm_and_ps(mask, bottom), _mm_andnot_ps(mask, top));
            c.ptr[3] = col.a;
            _mm_storeu_ps(cast(float*)&col, c);
            return col;
        }

        final switch(gammaCurve)
        {
            case GammaCurve.linear:
                foreach(ref col; arr)
                    col = delinearized(col);
                break;
            case GammaCurve.pow2:
                foreach(ref col; arr) {
                    __m128 c = _mm_loadu_ps(cast(float*)&col);
                    c = _mm_sqrt_ps(c);
                    c.ptr[3] = col.a;
                    _mm_storeu_ps(cast(float*)&col, c);
                }
                break;
            case GammaCurve.none:
                break;
        }
    }

    rgba premultiplied( rgba col ) 
    {
        return rgba(col.r*col.a, col.g*col.a, col.b*col.a, col.a); 
    }

    rgba unpremultiplied( rgba that ) 
    {
        enum float threshold = 1.0f / 8160.0f;
        return that.a < threshold ? rgba( 0.0f, 0.0f, 0.0f, 0.0f ) :
        rgba( 1.0f / that.a * that.r, 1.0f / that.a * that.g,
              1.0f / that.a * that.b, that.a ); 
    }

    rgba clamped(rgba that) pure
    {
        if (that.r < 0) that.r = 0;
        if (that.r > 1) that.r = 1;
        if (that.g < 0) that.g = 0;
        if (that.g > 1) that.g = 1;
        if (that.b < 0) that.b = 0;
        if (that.b > 1) that.b = 1;
        if (that.a < 0) that.a = 0;
        if (that.a > 1) that.a = 1;
        return that;
    }

    struct affine_matrix 
    { 
    pure nothrow @nogc @safe:
        float a, b, c, d, e, f; 

        enum identity = affine_matrix(1, 0, 0, 1, 0, 0);

        bool isInvertible() {
            return (a * d - b * c) != 0.0f;
        }
    }

    struct paint_brush 
    {
    nothrow @nogc:
        enum types 
        { 
            color, 
            linear, 
            radial, 
            pattern 
        }
        types type;

        @disable this(this); // copying Vec doesn't work like in C++!

        Vec!rgba colors;
        Vec!float stops;
        xy start = xy(0.0f, 0.0f);
        xy end = xy(0.0f, 0.0f);
        float start_radius, end_radius;
        int width, height; 
        repetition_style repetition;

        void opAssign(ref const(paint_brush) other)
        {
            this.type = other.type;
            colors.clearContents();
            colors.pushBack(cast(Vec!rgba)other.colors);
            stops.clearContents();
            stops.pushBack(cast(Vec!float)other.stops);
            this.start = other.start;
            this.end = other.end;
            this.start_radius = other.start_radius;
            this.end_radius = other.end_radius;
            this.width = other.width;
            this.height = other.height;
            this.repetition = other.repetition;
        }

    }

    void swap_scalar(T)(ref T a, ref T b)
    {
        T c = a;
        a = b;
        b = c;
    }

    alias swap_xy = swap_scalar!xy;

    // a = b;
    void assign_vec(T)(ref Vec!T a, ref const(Vec!T) b)
    {
        a.clearContents();
        a.pushBack(cast(Vec!T) b);
    }

    void swap_brush(ref paint_brush a, 
                    ref paint_brush b, 
                    ref paint_brush tmp)
    {
        tmp = a;
        a = b;
        b = tmp;
    }

    struct font_face 
    { 
    nothrow @nogc:
        @disable this(this);
        Vec!ubyte data;
        int cmap, glyf, head, hhea, hmtx, loca, maxp, os_2;
        float scale;

        void opAssign(ref const(font_face) other)
        {
            data.clearContents();
            data.pushBack(cast(Vec!ubyte) other.data);
            this.cmap = other.cmap;
            this.glyf = other.glyf;
            this.head = other.head;
            this.hhea = other.hhea;
            this.hmtx = other.hmtx;
            this.loca = other.loca;
            this.maxp = other.maxp;
            this.os_2 = other.os_2;
            this.scale = other.scale;
        }
    }

    struct subpath_data 
    { 
        size_t count; 
        bool closed; 
    }

    struct bezier_path 
    { 
        @disable this(this); // copying Vec doesn't work like in C++!
        Vec!xy points;
        Vec!subpath_data subpaths; 
    }

    struct line_path 
    { 
        @disable this(this); // copying Vec doesn't work like in C++!
        Vec!xy points;
        Vec!subpath_data subpaths;
    }

    struct pixel_run 
    { 
        ushort x, y; 
        float delta; 
    }

    float fminf(float a, float b) pure
    {
        return a < b ? a : b;
    }

    float fmaxf(float a, float b) pure
    {
        return a > b ? a : b;
    }

    int min_int(int a, int b) pure
    {
        return a < b ? a : b;
    }

    int max_int(int a, int b) pure
    {
        return a > b ? a : b;
    }

    size_t max_size_t(size_t a, size_t b) pure
    {
        return a > b ? a : b;
    }

    // FUTURE: move into dplug.core
    void vec_insert(T)(ref Vec!T v, size_t index, T value)
    {
        v.pushBack(T.init);
        size_t last = v.length - 1;
        for (int i = last; i > index; --i)
        {
            v[i] = v[i-1];
        }
        v[index] = value;
    }
}
