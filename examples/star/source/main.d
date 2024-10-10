import canvasity;
import gamut;

void main()
{
    // Showcase rendering the same image, 
    // with different backing buffers.
    render(PixelType.la8,     PixelType.rgba8, "output-la8.png");
    render(PixelType.rgba8,   PixelType.rgba8, "output-rgba8.png");
    render(PixelType.rgba16,  PixelType.rgba16, "output-rgba16.png");
    render(PixelType.rgbaf32, PixelType.rgba16, "output-rgba32.png");
}

void render(PixelType type, PixelType beforeWrite, string filepath)
{
    // Construct the canvas.
    enum int width = 256, height = 256;

    Image image;
    image.createNoInit(width, height, type); // rgba8

    // Note: this does NOT clear the image, which is externally owned.
    // If you reuse the same Canvasity struct, all allocations will 
    // be reused eventually, leading to zero allocation per frame.
    Canvasity context = Canvasity(image);

    // Build a star path.
    context.moveTo( 128.0f,  28.0f ); context.lineTo( 157.0f,  87.0f );
    context.lineTo( 223.0f,  97.0f ); context.lineTo( 175.0f, 143.0f );
    context.lineTo( 186.0f, 208.0f ); context.lineTo( 128.0f, 178.0f );
    context.lineTo(  69.0f, 208.0f ); context.lineTo(  80.0f, 143.0f );
    context.lineTo(  32.0f,  97.0f ); context.lineTo(  98.0f,  87.0f );
    context.closePath();

    // Set up the drop shadow.
    context.shadowBlur = 8.0f;
    context.shadowOffsetY = 4.0f;
    context.shadowColor(0.0f, 0.0f, 0.0f, 0.5f);

    // Fill the star with yellow.
    context.fillStyle(1.0f, 1.0f, 0.0f, 1.0f );
    context.fill();

    // Draw the star with a thick red stroke and rounded points.
    context.lineJoin = "round";
    context.lineWidth = 12.0f;
    context.strokeStyle(0.9f, 0.0f, 0.5f, 1.0f);
    context.stroke();

    // Draw the star again with a dashed thinner orange stroke.
    float[8] segments = [ 21.0f, 9.0f, 1.0f, 9.0f, 7.0f, 9.0f, 1.0f, 9.0f ];
    context.setLineDash( segments.ptr, 8 );
    context.lineDashOffset = 10.0f;
    context.lineCap = "circle";
    context.lineWidth = 6.0f;
    context.strokeStyle(0.95f, 0.65f, 0.15f, 1.0f );
    context.stroke();

    // Turn off the drop shadow.
    context.shadowColor( 0.0f, 0.0f, 0.0f, 0.0f );


    /*   // Add a shine layer over the star.
    context.set_linear_gradient( brush_type.fill_style, 64.0f, 0.0f, 192.0f, 256.0f );
    context.add_color_stop( brush_type.fill_style, 0.30f, 1.0f, 1.0f, 1.0f, 0.0f );
    context.add_color_stop( brush_type.fill_style, 0.35f, 1.0f, 1.0f, 1.0f, 0.8f );
    context.add_color_stop( brush_type.fill_style, 0.45f, 1.0f, 1.0f, 1.0f, 0.8f );
    context.add_color_stop( brush_type.fill_style, 0.50f, 1.0f, 1.0f, 1.0f, 0.0f );

    context.global_composite_operation = composite_operation.source_atop;
    context.fill_rectangle( 0.0f, 0.0f, 256.0f, 256.0f ); */

    // Convert to a format that can output a .png
    image.convertTo(beforeWrite);
    image.saveToFile(filepath);
}