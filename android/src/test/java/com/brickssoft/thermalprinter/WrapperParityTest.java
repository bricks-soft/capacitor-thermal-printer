package com.brickssoft.thermalprinter;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import com.dantsu.escposprinter.connection.DeviceConnection;
import com.getcapacitor.JSObject;
import com.getcapacitor.PluginCall;
import de.paystory.thermal_printer.ThermalPrinterCordovaPlugin;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.GraphicsMode;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
public class WrapperParityTest {
    private final Path fixtures = Path.of("../ios/Tests/ThermalPrinterTests/Fixtures");

    static class Capture extends DeviceConnection {
        final ByteArrayOutputStream captured = new ByteArrayOutputStream();
        Capture() { outputStream = captured; }
        @Override public Capture connect() { outputStream = captured; return this; }
        @Override public Capture disconnect() { outputStream = null; return this; }
        @Override public void send(int wait) {
            captured.write(data, 0, data.length);
            data = new byte[0];
        }
    }

    static class Answer {
        final CountDownLatch done = new CountDownLatch(1);
        Object value;
        String error;
        void success(Object value) { this.value = value; done.countDown(); }
        void failure(Object value) { error = String.valueOf(value); done.countDown(); }
        Object await() throws Exception {
            assertTrue("Wrapper did not complete", done.await(20, TimeUnit.SECONDS));
            assertNull(error, error);
            return value;
        }
    }

    @SuppressWarnings("unchecked")
    private void inject(Object plugin, JSONObject data, Capture capture) throws Exception {
        capture.connect();
        Field f = plugin.getClass().getDeclaredField("connections");
        f.setAccessible(true);
        ((HashMap<String, DeviceConnection>) f.get(plugin)).put(data.getString("type") + "-" + data.getString("id"), capture);
    }

    private Object invoke(boolean legacy, String action, JSONObject data, Capture capture) throws Exception {
        Answer answer = new Answer();
        if (legacy) {
            ThermalPrinterCordovaPlugin plugin = new ThermalPrinterCordovaPlugin();
            CordovaInterface cordova = mock(CordovaInterface.class);
            java.util.concurrent.ExecutorService pool = Executors.newSingleThreadExecutor();
            when(cordova.getThreadPool()).thenReturn(pool);
            plugin.cordova = cordova;
            inject(plugin, data, capture);
            CallbackContext callback = mock(CallbackContext.class);
            doAnswer(i -> { answer.success(i.getArgument(0)); return null; }).when(callback).success(any(String.class));
            doAnswer(i -> { answer.success(i.getArgument(0)); return null; }).when(callback).success(any(JSONObject.class));
            doAnswer(i -> { answer.success(i.getArgument(0)); return null; }).when(callback).success(any(JSONArray.class));
            doAnswer(i -> { answer.success(null); return null; }).when(callback).success();
            doAnswer(i -> { answer.failure(i.getArgument(0)); return null; }).when(callback).error(any(String.class));
            doAnswer(i -> { answer.failure(i.getArgument(0)); return null; }).when(callback).error(any(JSONObject.class));
            try {
                plugin.execute(action, new JSONArray().put(new JSONObject(data.toString())), callback);
                return answer.await();
            } finally { pool.shutdownNow(); }
        }
        ThermalPrinterPlugin plugin = new ThermalPrinterPlugin();
        inject(plugin, data, capture);
        PluginCall call = mock(PluginCall.class);
        when(call.getData()).thenReturn(new JSObject(data.toString()));
        doAnswer(i -> { answer.success(((JSObject) i.getArgument(0)).opt("value")); return null; }).when(call).resolve(any(JSObject.class));
        doAnswer(i -> { answer.failure(i.getArgument(0)); return null; }).when(call).reject(any(String.class));
        doAnswer(i -> { answer.failure(i.getArgument(0)); return null; }).when(call).reject(any(String.class), any(JSObject.class));
        try {
            plugin.getClass().getMethod(action, PluginCall.class).invoke(plugin, call);
            return answer.await();
        } finally {
            plugin.handleOnDestroy();
            Field executor = ThermalPrinterPlugin.class.getDeclaredField("executor");
            executor.setAccessible(true);
            assertTrue("Plugin cleanup did not complete", ((java.util.concurrent.ExecutorService) executor.get(plugin)).awaitTermination(20, TimeUnit.SECONDS));
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder();
        for (byte b : bytes) text.append(String.format("%02X", b));
        return text.toString();
    }

    private JSONArray cases() throws Exception {
        return new JSONArray(new String(Files.readAllBytes(fixtures.resolve("android-reference.json")), java.nio.charset.StandardCharsets.UTF_8));
    }

    private void receipt(int width) throws Exception {
        org.robolectric.Shadows.shadowOf(android.bluetooth.BluetoothAdapter.getDefaultAdapter()).setEnabled(true);
        JSONObject test = null;
        JSONArray cases = cases();
        for (int i = 0; i < cases.length(); i++) {
            JSONObject item = cases.getJSONObject(i);
            if (item.getString("action").equals("receipt") && item.getJSONObject("data").getInt("printerWidthMM") == width) test = item;
        }
        assertNotNull(test);
        byte[][] results = new byte[2][];
        for (int mode = 0; mode < 2; mode++) {
            boolean legacy = mode == 0;
            JSONObject data = new JSONObject(test.getJSONObject("data").toString());
            Capture capture = new Capture();
            StringBuilder text = new StringBuilder();
            JSONArray images = test.getJSONArray("images");
            for (int i = 0; i < images.length(); i++) {
                JSONObject image = new JSONObject(data.toString());
                image.put("base64", "data:image/png;base64," + java.util.Base64.getEncoder().encodeToString(Files.readAllBytes(fixtures.resolve("images").resolve(images.getString(i)))));
                text.append("[C]<img>").append(invoke(legacy, "bitmapToHexadecimalString", image, capture)).append("</img>");
                if (i < images.length() - 1) text.append('\n');
            }
            data.put("text", text.append("\n\n\n\n").toString());
            invoke(legacy, "printFormattedText", data, capture);
            results[mode] = capture.captured.toByteArray();
            assertEquals(test.getString("name"), test.getJSONObject("expected").getString("bytes").toUpperCase(), hex(results[mode]));
        }
        assertArrayEquals(results[0], results[1]);
    }

    @Test public void appReceipt48mmMatchesLegacyAndGolden() throws Exception { receipt(48); }
    @Test public void appReceipt72mmMatchesLegacyAndGolden() throws Exception { receipt(72); }

    @Test public void goldenPrintCommandsMatchBothWrappers() throws Exception {
        JSONArray cases = cases();
        int compared = 0;
        for (int i = 0; i < cases.length(); i++) {
            JSONObject test = cases.getJSONObject(i);
            if (!test.getString("action").startsWith("printFormattedText") || test.getJSONObject("expected").has("error")) continue;
            for (boolean legacy : new boolean[] {true, false}) {
                Capture capture = new Capture();
                invoke(legacy, test.getString("action"), test.getJSONObject("data"), capture);
                assertEquals(test.getString("name"), test.getJSONObject("expected").getString("bytes").toUpperCase(), hex(capture.captured.toByteArray()));
            }
            compared++;
        }
        assertTrue(compared >= 20);
        System.out.println("Golden print cases: " + compared);
    }

    @Test public void encodedImageBytesMatchBase64() throws Exception {
        JSONObject data = new JSONObject().put("type", "tcp").put("id", "capture");
        byte[] bytes = Files.readAllBytes(fixtures.resolve("images/receipt-48mm-0.png"));
        JSONArray array = new JSONArray();
        for (byte b : bytes) array.put(b & 255);
        data.put("bytes", array);
        Object actual = invoke(false, "bytesToHexadecimalString", data, new Capture());
        data.put("base64", java.util.Base64.getEncoder().encodeToString(bytes));
        assertEquals(invoke(true, "bitmapToHexadecimalString", data, new Capture()), actual);
    }

    private void rejection(JSONObject payload) throws Exception {
        PluginCall call = mock(PluginCall.class);
        Class<?> type = Class.forName("com.brickssoft.thermalprinter.ThermalPrinterPlugin$Result");
        java.lang.reflect.Constructor<?> constructor = type.getDeclaredConstructor(PluginCall.class);
        constructor.setAccessible(true);
        Object result = constructor.newInstance(call);
        java.lang.reflect.Method error = type.getDeclaredMethod("error", Object.class);
        error.setAccessible(true);
        error.invoke(result, payload);
        org.mockito.ArgumentCaptor<JSObject> captured = org.mockito.ArgumentCaptor.forClass(JSObject.class);
        verify(call).reject(anyString(), captured.capture());
        java.util.Iterator<String> keys = payload.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            assertEquals(payload.get(key), captured.getValue().get(key));
        }
    }

    @Test public void bluetoothOffRejectionRetainsError() throws Exception {
        rejection(new JSONObject().put("error", "Device not enabled Bluetooth!"));
    }
    @Test public void missingPrinterRejectionRetainsIdentity() throws Exception {
        rejection(new JSONObject().put("error", "Device not found or not connected!").put("type", "bluetooth").put("id", "missing"));
    }
    @Test public void usbDenialRejectionRetainsGranted() throws Exception {
        rejection(new JSONObject().put("granted", false));
    }
}
