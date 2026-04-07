/* canvas_ity test suite and harness v1.00 -- ISC license
 * Copyright (c) 2022 Andrew Kensler
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 * D port of the C89 test suite.
 */
import canvasity;
import gamut;
import std.stdio;
import std.conv;




void usage()
{
    writeln("Usage: tests [options...]\n" ~
                   "Options:\n" ~
                   "  --subset <str> : Only run tests with names globbing <str>\n" ~
                   "  --table        : Regenerate the code for table of tests\n" ~
                   "  --pngs         : Write PNG images showing output of tests\n" ~
                   "  --suffix <str> : Append <str> to the filenames of PNGs\n" ~
                   "  --fails        : Generate output only for failures\n" ~
                   "  --bench <int>  : Run each test <int> times, show fastest\n");
}

// FUTURE: restore benchmarking
// FUTURE: restore fonts?
int main(string[] args)
{
    int argc = cast(int)args.length;

    string subset = "";
    int do_table = 0;
    int pngs = 0;
    string suffix = "";
    int fails = 0;
    int bench = 1;

    for (int index = 1; index < args.length; ++index)
    {
        string option = args[index];

        if (option == "--subset" && index < argc - 1)
            subset = args[++index]; 
        else if (option == "--table")
            do_table = 1;
        else if (option == "--pngs")
            pngs = 1;
        else if (option == "--suffix" && index < argc - 1)
            suffix = args[++index]; 
        else if (option == "--fails")
            fails = 1;
        else if (option == "--bench" && index < argc - 1)
        {
            int val = to!int(args[++index]);
            bench = val > 1 ? val : 1;
        }
        else
        {
           usage();
           return 1;
        }
    }    

    int count = cast(int) tests.length;
  
    int failed = 0, done = 0;

    for (int index = 0; index < count; ++index)
    {
        test_entry entry = tests[index];
        writef("*** Test %s", entry.name);


        int W = entry.width;
        int H = entry.height;        

        for (int run = 0; run < bench; ++run)
        {
            Image image;
            image.create(W, H, PixelType.rgba8); // rgba8        

            Canvasity context = Canvasity(image);

            entry.call(&context, W, H);

            if (run == 0)
                image.saveToFile("output/" ~ entry.name ~ ".png");
        }

        writeln(" [OK]");
    }
    return 0;
}

struct test_entry
{
    uint hash;
    int width, height;
    void function(Canvasity*, float, float) call;
    string name;
}

static immutable test_entry[] tests = 
[
    test_entry( 0xc99ddee7, 256, 256, &scale_uniform, "scale_uniform" ),
    test_entry( 0x05a0e377, 256, 256, &test_rotate, "rotate" ),

    /+
    test_entry( 0xe93d3c6f, 256, 256, &scale_non_uniform, "scale_non_uniform" ),
    test_entry( 0x05a0e377, 256, 256, &test_rotate, "rotate" ),
    test_entry( 0x36e7fa56, 256, 256, &test_translate, "translate" ),
    test_entry( 0xcfae3e4f, 256, 256, &test_transform, "transform" ),
    test_entry( 0x98f5594a, 256, 256, &transform_fill, "transform_fill" ),
    test_entry( 0x822964b0, 256, 256, &transform_stroke, "transform_stroke" ),
    test_entry( 0xb7056a3a, 256, 256, &test_set_transform, "set_transform" ),
    test_entry( 0x8f6dd6c3, 256, 256, &test_global_alpha, "global_alpha" ),
    test_entry( 0x98a0609d, 256, 256, &test_global_composite_operation, "global_composite_operation" ),
    test_entry( 0x9def5b00, 256, 256, &shadow_color, "shadow_color" ),
    test_entry( 0x8294edd8, 256, 256, &shadow_offset, "shadow_offset" ),
    test_entry( 0xcdeba51c, 256, 256, &shadow_offset_offscreen, "shadow_offset_offscreen" ),
    test_entry( 0x5b542224, 256, 256, &shadow_blur, "shadow_blur" ),
    test_entry( 0xd6c150e6, 256, 256, &shadow_blur_offscreen, "shadow_blur_offscreen" ),
    test_entry( 0x5affc092, 256, 256, &shadow_blur_composite, "shadow_blur_composite" ),
    test_entry( 0x1720e9b2, 256, 256, &test_line_width, "line_width" ),
    test_entry( 0xf8d2bb0d, 256, 256, &line_width_angular, "line_width_angular" ),
    test_entry( 0x7bda8673, 256, 256, &test_line_cap, "line_cap" ),
    test_entry( 0x53639198, 256, 256, &line_cap_offscreen, "line_cap_offscreen" ),
    test_entry( 0x8f49c41d, 256, 256, &test_line_join, "line_join" ),
    test_entry( 0xca27ce8c, 256, 256, &line_join_offscreen, "line_join_offscreen" ),
    test_entry( 0xe68273e2, 256, 256, &test_miter_limit, "miter_limit" ),
    test_entry( 0x27c38a8a, 256, 256, &line_dash_offset, "line_dash_offset" ),
    test_entry( 0x129f9595, 256, 256, &test_line_dash, "line_dash" ),
    test_entry( 0x88a74152, 256, 256, &line_dash_closed, "line_dash_closed" ),
    test_entry( 0x064f194d, 256, 256, &line_dash_overlap, "line_dash_overlap" ),
    test_entry( 0xf7259c0f, 256, 256, &line_dash_offscreen, "line_dash_offscreen" ),
    test_entry( 0xeb4338e8, 256, 256, &test_color, "color" ),
    test_entry( 0x6dc35a07, 256, 256, &test_linear_gradient, "linear_gradient" ),
    test_entry( 0x418fe678, 256, 256, &test_radial_gradient, "radial_gradient" ),
    test_entry( 0xd5dc2c85, 256, 256, &test_conic_gradient, "conic_gradient" ),
    test_entry( 0x3eda353a, 256, 256, &conic_gradient_rect, "conic_gradient_rect" ),
    test_entry( 0x67aada11, 256, 256, &test_color_stop, "color_stop" ),
    test_entry( 0xc6c721d6, 256, 256, &test_pattern, "pattern" ),
    test_entry( 0xb0b391cd, 256, 256, &test_begin_path, "begin_path" ),
    test_entry( 0xf79ed394, 256, 256, &test_move_to, "move_to" ),
    test_entry( 0xe9602309, 256, 256, &test_close_path, "close_path" ),
    test_entry( 0x3160ace7, 256, 256, &test_line_to, "line_to" ),
    test_entry( 0xb6176812, 256, 256, &test_quadratic_curve_to, "quadratic_curve_to" ),
    test_entry( 0x5f523029, 256, 256, &test_bezier_curve_to, "bezier_curve_to" ),
    test_entry( 0x1f847aaf, 256, 256, &test_arc_to, "arc_to" ),
    test_entry( 0x26457553, 256, 256, &test_arc, "arc" ),
    test_entry( 0x5f042c5d, 256, 256, &test_ellipse, "ellipse" ),
    test_entry( 0x3c8a0970, 256, 256, &test_ellipse_rotated, "ellipse_rotated" ),
    test_entry( 0x7520990c, 256, 256, &test_rectangle, "rectangle" ),
    test_entry( 0x7290ed64, 256, 256, &test_round_rect, "round_rect" ),
    test_entry( 0x407aa93b, 256, 256, &test_round_rect_clamped, "round_rect_clamped" ),
    test_entry( 0xf1d774dc, 256, 256, &test_fill, "fill" ),
    test_entry( 0x5e6e6b75, 256, 256, &fill_rounding, "fill_rounding" ),
    test_entry( 0xf0cf6566, 256, 256, &fill_converging, "fill_converging" ),
    test_entry( 0x3692d10e, 256, 256, &fill_zone_plate, "fill_zone_plate" ),
    test_entry( 0x2003f926, 256, 256, &test_stroke, "stroke" ),
    test_entry( 0xc44fc157, 256, 256, &stroke_wide, "stroke_wide" ),
    test_entry( 0x691cfe49, 256, 256, &stroke_inner_join, "stroke_inner_join" ),
    test_entry( 0xc0bd9324, 256, 256, &stroke_spiral, "stroke_spiral" ),
    test_entry( 0x3b2dae15, 256, 256, &stroke_long, "stroke_long" ),
    test_entry( 0xa7e06559, 256, 256, &test_clip, "clip" ),
    test_entry( 0x31e6112b, 256, 256, &clip_winding, "clip_winding" ),
    test_entry( 0xc2188d67, 256, 256, &test_is_point_in_path, "is_point_in_path" ),
    test_entry( 0x6505bdc9, 256, 256, &is_point_in_path_offscreen, "is_point_in_path_offscreen" ),
    test_entry( 0x3a3803eb, 256, 256, &fill_evenodd, "fill_evenodd" ),
    test_entry( 0x130d5578, 256, 256, &fill_evenodd_star, "fill_evenodd_star" ),
    test_entry( 0x64454d62, 256, 256, &clip_evenodd, "clip_evenodd" ),
    test_entry( 0xec607e9e, 256, 256, &is_point_in_path_evenodd, "is_point_in_path_evenodd" ),
    test_entry( 0x5e792c96, 256, 256, &test_clear_rectangle, "clear_rectangle" ),
    test_entry( 0x286e96fa, 256, 256, &test_fill_rectangle, "fill_rectangle" ),
    test_entry( 0xc2b0803d, 256, 256, &test_stroke_rectangle, "stroke_rectangle" ),
    //test_entry( 0xe6c4d9c7, 256, 256, &test_text_align, "text_align" ),
    //test_entry( 0x72cb6b06, 256, 256, &test_text_baseline, "text_baseline" ),
    //test_entry( 0x4d41daa2, 256, 256, &test_font, "font" ),
    //test_entry( 0x70e3232d, 256, 256, &test_fill_text, "fill_text" ),
    //test_entry( 0xed6477c8, 256, 256, &test_stroke_text, "stroke_text" ),
    //test_entry( 0x32d1ee3b, 256, 256, &test_measure_text, "measure_text" ),
    //test_entry( 0x2c895307, 256, 256, &test_text_kerning, "text_kerning" ),
    //test_entry( 0xd9969c18, 256, 256, &test_text_kerning_measure, "text_kerning_measure" ),
    //test_entry( 0x2c895307, 256, 256, &test_text_kerning_aat, "text_kerning_aat" ),
    //test_entry( 0xd9969c18, 256, 256, &test_text_kerning_aat_measure, "text_kerning_aat_measure" ),
    //test_entry( 0x2c895307, 256, 256, &test_text_kerning_gpos_fmt1, "text_kerning_gpos_fmt1" ),
    //test_entry( 0x2c895307, 256, 256, &test_text_kerning_gpos_fmt2, "text_kerning_gpos_fmt2" ),
    test_entry( 0x78cb460c, 256, 256, &test_draw_image, "draw_image" ),
    test_entry( 0xb530077b, 256, 256, &draw_image_matted, "draw_image_matted" ),
    test_entry( 0xaf04e7a2, 256, 256, &test_get_image_data, "get_image_data" ),
    test_entry( 0x5acae0b6, 256, 256, &test_put_image_data, "put_image_data" ),
    test_entry( 0xb6e854b1, 256, 256, &test_save_restore, "save_restore" ),
    test_entry( 0x62bc9606, 256, 256, &example_button, "example_button" ),
    test_entry( 0x92731a7b, 256, 256, &example_smiley, "example_smiley" ),
    test_entry( 0xe2f1e1de, 256, 256, &example_knot, "example_knot" ),
    test_entry( 0xc02d01ea, 256, 256, &example_icon, "example_icon" ),
    test_entry( 0xa1607c4a, 256, 256, &example_illusion, "example_illusion" ),
    test_entry( 0x7c861f87, 256, 256, &example_star, "example_star" ),
    test_entry( 0x429ca194, 256, 256, &example_neon, "example_neon") +/
];

float CI_MINF(float a, float b)
{
    return a < b ? a : b;
}

float CI_MAXF(float a, float b)
{
    return a > b ? a : b;
}

static void test_rotate(Canvasity *ctx, float width, float height)
{
    ctx.strokeStyle = "rgba(0, 0, 0, 1)";
    for (int step = 0; step < 64; ++step)
    {
        ctx.rotate(3.14159265f / 2.0f / 64.0f);
        ctx.strokeRect(0.0f, 0.0f, width, height);
    }
}

static void scale_uniform(Canvasity *ctx, float width, float height)
{
    float size;
    float[1] segments;
    segments[0] = 1.0f;
    ctx.strokeStyle = "rgba(0.0, 0.0, 0.0, 1.0)";
    ctx.setLineDash(segments);
    ctx.lineCap = "circle";
    for (size = 8.0f; size < CI_MINF(width, height); size *= 2.0f)
    {
        ctx.scale(2.0f, 2.0f);
        ctx.strokeRect(0.0f, 0.0f, 8.0f, 8.0f);
    }
}