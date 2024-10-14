import canvasity;
import gamut;

void main()
{
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