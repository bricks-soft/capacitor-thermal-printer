import java.awt.BasicStroke;
import java.awt.Color;
import java.awt.Font;
import java.awt.GradientPaint;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import javax.imageio.ImageIO;

public class FixtureImages {
    public static void main(String[] args) throws IOException {
        File directory = new File(args[0]);
        directory.mkdirs();
        writeSegments(directory, "receipt-72mm", receipt(575, 980));
        writeSegments(directory, "receipt-48mm", receipt(384, 700));
        write(directory, "logo-alpha.png", logo());
        write(directory, "gray-gradient.png", grayGradient());
        write(directory, "wide.png", banner(900, 120));
        write(directory, "tall.png", banner(100, 400));
    }

    private static void write(File directory, String name, BufferedImage image) throws IOException {
        ImageIO.write(image, "png", new File(directory, name));
    }

    private static void writeSegments(File directory, String prefix, BufferedImage image) throws IOException {
        int maxSegmentHeight = 256;
        int cuts = (int) Math.ceil(image.getHeight() / (double) maxSegmentHeight);
        for (int index = 0; index < cuts; index++) {
            int height = index == cuts - 1 ? image.getHeight() - index * maxSegmentHeight : maxSegmentHeight;
            BufferedImage segment = new BufferedImage(image.getWidth(), height, BufferedImage.TYPE_INT_RGB);
            Graphics2D graphics = segment.createGraphics();
            graphics.drawImage(image.getSubimage(0, index * maxSegmentHeight, image.getWidth(), height), 0, 0, null);
            graphics.dispose();
            write(directory, prefix + "-" + index + ".png", segment);
        }
    }

    private static BufferedImage receipt(int width, int height) {
        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        Graphics2D graphics = image.createGraphics();
        graphics.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        graphics.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        graphics.setColor(Color.WHITE);
        graphics.fillRect(0, 0, width, height);
        graphics.setColor(Color.BLACK);

        Font title = new Font("FreeSerif", Font.BOLD, 32);
        Font body = new Font("FreeSerif", Font.BOLD, 24);
        int margin = 16;
        int y = 48;

        graphics.setFont(title);
        drawCentered(graphics, "فاتورة مبيعات", width, y);
        y += 40;
        drawCentered(graphics, "Sales order SO-1042", width, y);
        y += 24;
        graphics.setStroke(new BasicStroke(8));
        graphics.setColor(Color.GRAY);
        graphics.drawLine(margin, y, width - margin, y);
        graphics.setColor(Color.BLACK);
        y += 40;

        graphics.setFont(body);
        List<String[]> rows = new ArrayList<>();
        rows.add(new String[] {"العميل:", "صيدلية التحرير"});
        rows.add(new String[] {"Customer:", "Tahrir Pharmacy"});
        rows.add(new String[] {"التاريخ:", "2026-11-01 21:30"});
        rows.add(new String[] {"Paracetamol 500mg × 3", "45.00"});
        rows.add(new String[] {"باراسيتامول ٥٠٠ مجم × ٣", "٤٥٫٠٠"});
        rows.add(new String[] {"Vitamin C 1000 × 2", "120.50"});
        rows.add(new String[] {"Subtotal", "165.50"});
        rows.add(new String[] {"VAT 14%", "23.17"});
        for (String[] row : rows) {
            graphics.drawString(row[0], margin, y);
            int valueWidth = graphics.getFontMetrics().stringWidth(row[1]);
            graphics.drawString(row[1], width - margin - valueWidth, y);
            y += 36;
        }

        graphics.setPaint(new GradientPaint(margin, 0, Color.WHITE, width - margin, 0, Color.BLACK));
        graphics.fillRect(margin, y, width - 2 * margin, 40);
        graphics.setPaint(Color.BLACK);
        y += 72;

        graphics.setFont(title);
        drawCentered(graphics, "الإجمالي 188.67 ج.م", width, y);
        y += 48;

        int cell = 6;
        int qrSize = 25;
        int left = (width - cell * qrSize) / 2;
        long seed = 42;
        for (int row = 0; row < qrSize; row++) {
            for (int column = 0; column < qrSize; column++) {
                seed = (seed * 6364136223846793005L + 1442695040888963407L);
                if (((seed >>> 33) & 1) == 1) {
                    graphics.fillRect(left + column * cell, y + row * cell, cell, cell);
                }
            }
        }
        graphics.dispose();
        return image;
    }

    private static void drawCentered(Graphics2D graphics, String text, int width, int y) {
        int textWidth = graphics.getFontMetrics().stringWidth(text);
        graphics.drawString(text, (width - textWidth) / 2, y);
    }

    private static BufferedImage logo() {
        BufferedImage image = new BufferedImage(150, 60, BufferedImage.TYPE_INT_ARGB);
        Graphics2D graphics = image.createGraphics();
        graphics.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_OFF);
        graphics.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_OFF);
        graphics.setColor(new Color(255, 255, 255, 0));
        graphics.fillRect(0, 0, 150, 60);
        graphics.setColor(new Color(30, 30, 30, 255));
        graphics.fillOval(4, 4, 52, 52);
        graphics.setColor(new Color(200, 200, 200, 255));
        graphics.fillRect(64, 12, 80, 36);
        graphics.dispose();
        return image;
    }

    private static BufferedImage grayGradient() {
        BufferedImage image = new BufferedImage(200, 50, BufferedImage.TYPE_BYTE_GRAY);
        for (int y = 0; y < 50; y++) {
            for (int x = 0; x < 200; x++) {
                image.getRaster().setSample(x, y, 0, (x * 255) / 199);
            }
        }
        return image;
    }

    private static BufferedImage banner(int width, int height) {
        BufferedImage image = new BufferedImage(width, height, BufferedImage.TYPE_INT_RGB);
        Graphics2D graphics = image.createGraphics();
        graphics.setColor(Color.WHITE);
        graphics.fillRect(0, 0, width, height);
        graphics.setColor(Color.BLACK);
        for (int x = 0; x < width; x += 20) {
            graphics.fillRect(x, 0, 10, height);
        }
        graphics.dispose();
        return image;
    }
}
