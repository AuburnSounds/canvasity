import canvasity;
import gamut;

void main()
{
    Image image;
    image.createNoInit(300, 300);

    Canvasity context = Canvasity(image);

    context.fillStyle("blue");
    context.fillRect(50, 50, 200, 100);

    image.saveToFile("output-rectangle.png");
}