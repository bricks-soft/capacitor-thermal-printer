package android.graphics;

import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.awt.Graphics2D;

public class Bitmap {
    private final BufferedImage image;

    public Bitmap(BufferedImage image) {
        this.image = image;
    }

    public int getWidth() {
        return image.getWidth();
    }

    public int getHeight() {
        return image.getHeight();
    }

    public int getPixel(int x, int y) {
        if (image.getType() == BufferedImage.TYPE_BYTE_GRAY) {
            int level = image.getRaster().getSample(x, y, 0);
            return 0xFF000000 | level << 16 | level << 8 | level;
        }
        int argb = image.getRGB(x, y);
        if ((argb >>> 24) == 0) {
            return 0;
        }
        return argb;
    }

    public static Bitmap createScaledBitmap(Bitmap source, int width, int height, boolean filter) {
        BufferedImage scaled = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = scaled.createGraphics();
        graphics.setRenderingHint(RenderingHints.KEY_INTERPOLATION, filter ? RenderingHints.VALUE_INTERPOLATION_BILINEAR : RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
        graphics.drawImage(source.image, 0, 0, width, height, null);
        graphics.dispose();
        return new Bitmap(scaled);
    }
}
