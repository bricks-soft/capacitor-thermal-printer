import android.graphics.Bitmap;
import com.dantsu.escposprinter.EscPosCharsetEncoding;
import com.dantsu.escposprinter.EscPosPrinter;
import com.dantsu.escposprinter.connection.DeviceConnection;
import com.dantsu.escposprinter.exceptions.EscPosConnectionException;
import com.dantsu.escposprinter.textparser.PrinterTextParserImg;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import javax.imageio.ImageIO;
import org.json.JSONArray;
import org.json.JSONObject;

public class ReferenceGenerator {
    static final class CaptureConnection extends DeviceConnection {
        final JSONArray sends = new JSONArray();
        final ByteArrayOutputStream all = new ByteArrayOutputStream();

        @Override
        public CaptureConnection connect() {
            this.outputStream = new ByteArrayOutputStream();
            this.data = new byte[0];
            return this;
        }

        @Override
        public CaptureConnection disconnect() {
            this.data = new byte[0];
            this.outputStream = null;
            return this;
        }

        @Override
        public void send(int addWaitingTime) throws EscPosConnectionException {
            if (!this.isConnected()) {
                throw new EscPosConnectionException("Unable to send data to device.");
            }
            JSONObject send = new JSONObject();
            send.put("hex", hex(this.data));
            send.put("wait", addWaitingTime + this.data.length / 16);
            this.sends.put(send);
            this.all.write(this.data, 0, this.data.length);
            this.data = new byte[0];
        }

        byte[] pending() {
            return this.data;
        }
    }

    public static void main(String[] args) throws Exception {
        String casesPath = args[0];
        File imagesDirectory = new File(args[1]);
        String outputPath = args[2];

        JSONArray cases = new JSONArray(new String(Files.readAllBytes(Paths.get(casesPath)), StandardCharsets.UTF_8));
        JSONArray output = new JSONArray();
        for (int index = 0; index < cases.length(); index++) {
            JSONObject testCase = cases.getJSONObject(index);
            JSONObject result = new JSONObject();
            result.put("name", testCase.getString("name"));
            result.put("action", testCase.getString("action"));
            result.put("compare", testCase.optString("compare", "bytes"));
            result.put("data", testCase.getJSONObject("data"));
            if (testCase.has("images")) {
                result.put("images", testCase.getJSONArray("images"));
            }
            if (testCase.has("image")) {
                result.put("image", testCase.getString("image"));
            }
            result.put("expected", run(testCase, imagesDirectory));
            output.put(result);
        }
        Files.write(Paths.get(outputPath), (output.toString(1) + "\n").getBytes(StandardCharsets.UTF_8));
    }

    static JSONObject run(JSONObject testCase, File imagesDirectory) throws IOException {
        String action = testCase.getString("action");
        JSONObject data = new JSONObject(testCase.getJSONObject("data").toString());
        CaptureConnection connection = new CaptureConnection();
        JSONObject expected = new JSONObject();
        EscPosPrinter printer;
        try {
            printer = getPrinter(connection, data);
        } catch (Exception exception) {
            expected.put("error", errorObject(exception));
            return expected;
        }

        try {
            switch (action) {
                case "bitmapToHexadecimalString": {
                    Bitmap bitmap = new Bitmap(ImageIO.read(new File(imagesDirectory, testCase.getString("image"))));
                    expected.put("result", PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap));
                    return expected;
                }
                case "getEncoding": {
                    EscPosCharsetEncoding encoding = printer.getEncoding();
                    JSONObject value = new JSONObject();
                    value.put("name", encoding.getName());
                    JSONArray command = new JSONArray();
                    for (byte b : encoding.getCommand()) {
                        command.put((int) b);
                    }
                    value.put("command", command);
                    expected.put("result", value);
                    return expected;
                }
                case "receipt": {
                    JSONArray images = testCase.getJSONArray("images");
                    List<String> lines = new ArrayList<>();
                    for (int index = 0; index < images.length(); index++) {
                        Bitmap bitmap = new Bitmap(ImageIO.read(new File(imagesDirectory, images.getString(index))));
                        lines.add("[C]<img>" + PrinterTextParserImg.bitmapToHexadecimalString(printer, bitmap) + "</img>");
                    }
                    String text = String.join("\n", lines) + "\n\n\n\n";
                    printer.printFormattedText(text, data.optInt("dotsFeedPaper", 20));
                    break;
                }
                default: {
                    int dotsFeedPaper = data.has("mmFeedPaper")
                        ? printer.mmToPx((float) data.getDouble("mmFeedPaper"))
                        : data.optInt("dotsFeedPaper", 20);
                    if (action.endsWith("Cut")) {
                        printer.printFormattedTextAndCut(data.getString("text"), dotsFeedPaper);
                    } else {
                        printer.printFormattedText(data.getString("text"), dotsFeedPaper);
                    }
                    break;
                }
            }
        } catch (Exception exception) {
            expected.put("error", errorObject(exception));
        }
        expected.put("sends", connection.sends);
        expected.put("bytes", hex(connection.all.toByteArray()));
        expected.put("pending", hex(connection.pending()));
        return expected;
    }

    static EscPosPrinter getPrinter(DeviceConnection connection, JSONObject data) throws Exception {
        EscPosCharsetEncoding charsetEncoding = null;
        if (data.optJSONObject("charsetEncoding") != null) {
            JSONObject charsetEncodingData = data.optJSONObject("charsetEncoding");
            charsetEncoding = new EscPosCharsetEncoding(
                charsetEncodingData.optString("charsetName", "windows-1252"),
                charsetEncodingData.optInt("charsetId", 16)
            );
        }
        return new EscPosPrinter(
            connection,
            data.optInt("printerDpi", 203),
            (float) data.optDouble("printerWidthMM", 48f),
            data.optInt("printerNbrCharactersPerLine", 32),
            charsetEncoding
        );
    }

    static JSONObject errorObject(Exception exception) {
        JSONObject error = new JSONObject();
        error.put("error", String.valueOf(exception.getMessage()));
        error.put("exception", exception.getClass().getSimpleName());
        return error;
    }

    static String hex(byte[] bytes) {
        StringBuilder builder = new StringBuilder();
        for (byte b : bytes) {
            builder.append(String.format("%02x", b & 0xFF));
        }
        return builder.toString();
    }
}
