package com.brickssoft.thermalprinter;


import android.Manifest;
import android.app.PendingIntent;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.util.Base64;

import com.dantsu.escposprinter.EscPosCharsetEncoding;
import com.dantsu.escposprinter.EscPosPrinter;
import com.dantsu.escposprinter.connection.DeviceConnection;
import com.dantsu.escposprinter.connection.bluetooth.BluetoothConnection;
import com.dantsu.escposprinter.connection.bluetooth.BluetoothConnections;
import com.dantsu.escposprinter.connection.bluetooth.BluetoothPrintersConnections;
import com.dantsu.escposprinter.connection.tcp.TcpConnection;
import com.dantsu.escposprinter.connection.usb.UsbConnection;
import com.dantsu.escposprinter.connection.usb.UsbConnections;
import com.dantsu.escposprinter.exceptions.EscPosConnectionException;
import com.dantsu.escposprinter.textparser.PrinterTextParserImg;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Objects;

import android.os.Build;
import android.content.pm.PackageManager;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.PermissionState;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

@CapacitorPlugin(name = "ThermalPrinter", permissions = {
    @Permission(alias = "bluetooth", strings = { Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN }),
    @Permission(alias = "bluetoothLegacy", strings = { Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN })
})
public class ThermalPrinterPlugin extends Plugin {
    private final HashMap<String, DeviceConnection> connections = new HashMap<>();
    private final ExecutorService executor = Executors.newSingleThreadExecutor();

    private static final class Result {
        private final PluginCall call;
        private boolean completed;
        Result(PluginCall call) { this.call = call; }
        synchronized void success() { success(null); }
        synchronized void success(Object value) {
            if (completed) return;
            completed = true;
            call.resolve(new JSObject().put("value", value));
        }
        synchronized void error(Object value) {
            if (completed) return;
            completed = true;
            String message = value instanceof JSONObject ? ((JSONObject) value).optString("error", value.toString()) : String.valueOf(value);
            JSObject data = new JSObject();
            if (value instanceof JSONObject) {
                JSONObject object = (JSONObject) value;
                java.util.Iterator<String> keys = object.keys();
                while (keys.hasNext()) {
                    String key = keys.next();
                    data.put(key, object.opt(key));
                }
            }
            call.reject(message, data);
        }
    }

    private void run(String action, PluginCall call) {
        executor.execute(() -> {
            Result result = new Result(call);
            JSONObject data = call.getData();
            try {
                switch (action) {
                    case "listPrinters": listPrinters(result, data); break;
                    case "printFormattedText":
                    case "printFormattedTextAndCut": printFormattedText(result, action, data); break;
                    case "getEncoding": getEncoding(result, data); break;
                    case "disconnectPrinter": disconnectPrinter(result, data); break;
                    case "requestUSBPermissions": requestUSBPermissions(result, data); break;
                    case "bitmapToHexadecimalString": bitmapToHexadecimalString(result, data); break;
                    case "bytesToHexadecimalString":
                        JSONArray bytes = data.getJSONArray("bytes");
                        byte[] decoded = new byte[bytes.length()];
                        for (int i = 0; i < decoded.length; i++) {
                            int value = bytes.getInt(i);
                            if (value < 0 || value > 255) throw new JSONException("Invalid image byte");
                            decoded[i] = (byte) value;
                        }
                        data.put("bytes", decoded);
                        bytesToHexadecimalString(result, data);
                        break;
                    default: result.error("Invalid action");
                }
            } catch (Exception e) {
                result.error(e.getMessage());
            }
        });
    }

    @PluginMethod
    public void listPrinters(PluginCall call) { run("listPrinters", call); }

    @PluginMethod
    public void printFormattedText(PluginCall call) { run("printFormattedText", call); }

    @PluginMethod
    public void printFormattedTextAndCut(PluginCall call) { run("printFormattedTextAndCut", call); }

    @PluginMethod
    public void getEncoding(PluginCall call) { run("getEncoding", call); }

    @PluginMethod
    public void disconnectPrinter(PluginCall call) { run("disconnectPrinter", call); }

    @Override @PluginMethod
    public void requestPermissions(PluginCall call) { run("requestUSBPermissions", call); }

    @PluginMethod
    public void requestUSBPermissions(PluginCall call) { run("requestUSBPermissions", call); }

    @PluginMethod
    public void bitmapToHexadecimalString(PluginCall call) { run("bitmapToHexadecimalString", call); }

    @PluginMethod
    public void bytesToHexadecimalString(PluginCall call) { run("bytesToHexadecimalString", call); }

    @PluginMethod
    public void requestBTPermissions(PluginCall call) {
        String alias = Build.VERSION.SDK_INT >= 31 ? "bluetooth" : "bluetoothLegacy";
        if (getPermissionState(alias) == PermissionState.GRANTED) {
            bluetoothPermissionResult(call);
        } else {
            requestPermissionForAlias(alias, call, "bluetoothPermissionResult");
        }
    }

    @PermissionCallback
    private void bluetoothPermissionResult(PluginCall call) {
        boolean granted = getPermissionState(Build.VERSION.SDK_INT >= 31 ? "bluetooth" : "bluetoothLegacy") == PermissionState.GRANTED;
        JSObject result = new JSObject().put("granted", granted);
        for (String name : new String[] { "BLUETOOTH", "BLUETOOTH_ADMIN", "BLUETOOTH_CONNECT", "BLUETOOTH_SCAN" }) {
            result.put(name, getActivity().checkSelfPermission("android.permission." + name) == PackageManager.PERMISSION_GRANTED);
        }
        call.resolve(new JSObject().put("value", result));
    }

    @Override
    protected void handleOnDestroy() {
        executor.execute(() -> {
            for (DeviceConnection connection : connections.values()) {
                if (connection != null) connection.disconnect();
            }
            connections.clear();
        });
        executor.shutdown();
    }

    private void bitmapToHexadecimalString(Result callbackContext, JSONObject data) throws JSONException {
        String encodedString = data.getString("base64");
        byte[] decodedString = Base64.decode(encodedString.contains(",")
            ? encodedString.substring(encodedString.indexOf(",") + 1) : encodedString, Base64.DEFAULT);
        data.put("bytes", decodedString);
        this.bytesToHexadecimalString(callbackContext, data);
    }

    private void bytesToHexadecimalString(Result callbackContext, JSONObject data) throws JSONException {
        EscPosPrinter printer = this.getPrinter(callbackContext, data);
        try {
            byte[] bytes = (byte[]) data.get("bytes");
            Bitmap decodedByte = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
            callbackContext.success(PrinterTextParserImg.bitmapToHexadecimalString(printer, decodedByte));
        } catch (Exception e) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", e.getMessage());
            }}));
        }
    }

    private void requestUSBPermissions(Result callbackContext, JSONObject data) throws JSONException {
        DeviceConnection connection = ThermalPrinterPlugin.this.getPrinterConnection(callbackContext, data);
        if (!(connection instanceof UsbConnection)) {
            throw new JSONException("USB printer required");
        }
        if (connection != null) {
            String intentName = "thermalPrinterUSBRequest" + ((UsbConnection) connection).getDevice().getDeviceId();

            PendingIntent permissionIntent = PendingIntent.getBroadcast(
                getActivity().getBaseContext(),
                0,
                new Intent(intentName).setPackage(getActivity().getPackageName()),
                Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0
            );

            ArrayList<BroadcastReceiver> broadcastReceiverArrayList = new ArrayList<>();
            BroadcastReceiver broadcastReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    String action = intent.getAction();
                    if (action != null && action.equals(intentName)) {
                        for (BroadcastReceiver br : broadcastReceiverArrayList) {
                            if (br != null) {
                                getActivity().unregisterReceiver(br);
                            }
                        }
                        synchronized (this) {
                            UsbManager usbManager = (UsbManager) ThermalPrinterPlugin.this.getActivity().getSystemService(Context.USB_SERVICE);
                            UsbDevice usbDevice = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
                            if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                                if (usbManager != null && usbDevice != null) {
                                    callbackContext.success(new JSONObject(new HashMap<String, Object>() {{
                                        put("granted", true);
                                    }}));
                                    return;
                                }
                            }
                            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                                put("granted", false);
                            }}));
                        }
                    }
                }
            };

            IntentFilter filter = new IntentFilter(intentName);
            if (Build.VERSION.SDK_INT >= 33) {
                getActivity().registerReceiver(broadcastReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
            } else {
                getActivity().registerReceiver(broadcastReceiver, filter);
            }
            broadcastReceiverArrayList.add(broadcastReceiver);

            UsbManager usbManager = (UsbManager) getActivity().getSystemService(Context.USB_SERVICE);
            if (usbManager != null) {
                usbManager.requestPermission(((UsbConnection) connection).getDevice(), permissionIntent);
            }
        }
    }

    private void listPrinters(Result callbackContext, JSONObject data) throws JSONException {
        JSONArray printers = new JSONArray();

        String type = data.getString("type");
        if (type.equals("bluetooth")) {
            if (!this.checkBluetooth(callbackContext)) {
                return;
            }
            try {
                BluetoothConnections printerConnections = new BluetoothConnections();
                for (BluetoothConnection bluetoothConnection : printerConnections.getList()) {
                    BluetoothDevice bluetoothDevice = bluetoothConnection.getDevice();
                    JSONObject printerObj = new JSONObject();
                    try { printerObj.put("address", bluetoothDevice.getAddress()); } catch (Exception ignored) {}
                    try { printerObj.put("bondState", bluetoothDevice.getBondState()); } catch (Exception ignored) {}
                    try { printerObj.put("name", bluetoothDevice.getName()); } catch (Exception ignored) {}
                    try { printerObj.put("type", bluetoothDevice.getType()); } catch (Exception ignored) {}
                    try { printerObj.put("features", bluetoothDevice.getUuids()); } catch (Exception ignored) {}
                    try { printerObj.put("deviceClass", bluetoothDevice.getBluetoothClass().getDeviceClass()); } catch (Exception ignored) {}
                    try { printerObj.put("majorDeviceClass", bluetoothDevice.getBluetoothClass().getMajorDeviceClass()); } catch (Exception ignored) {}
                    printers.put(printerObj);
                }
            } catch (Exception e) {
                callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                    put("error", e.getMessage());
                }}));
            }
        } else {
            UsbConnections printerConnections = new UsbConnections(getActivity());
            for (UsbConnection usbConnection : printerConnections.getList()) {
                UsbDevice usbDevice = usbConnection.getDevice();
                JSONObject printerObj = new JSONObject();
                try { printerObj.put("productName", Objects.requireNonNull(usbDevice.getProductName()).trim()); } catch (Exception ignored) {}
                try { printerObj.put("manufacturerName", usbDevice.getManufacturerName()); } catch (Exception ignored) {}
                try { printerObj.put("deviceId", usbDevice.getDeviceId()); } catch (Exception ignored) {}
                try { printerObj.put("serialNumber", usbDevice.getSerialNumber()); } catch (Exception ignored) {}
                try { printerObj.put("vendorId", usbDevice.getVendorId()); } catch (Exception ignored) {}
                printers.put(printerObj);
            }
        }

        callbackContext.success(printers);
    }

    private void printFormattedText(Result callbackContext, String action, JSONObject data) throws JSONException {
        EscPosPrinter printer = this.getPrinter(callbackContext, data);
        try {
            int dotsFeedPaper = data.has("mmFeedPaper")
                ? printer.mmToPx((float) data.getDouble("mmFeedPaper"))
                : data.optInt("dotsFeedPaper", 20);
            if (action.endsWith("Cut")) {
                printer.printFormattedTextAndCut(data.getString("text"), dotsFeedPaper);
            } else {
                printer.printFormattedText(data.getString("text"), dotsFeedPaper);
            }
            callbackContext.success();
        } catch (EscPosConnectionException e) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", e.getMessage());
            }}));
        } catch (Exception e) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", e.getMessage());
            }}));
        }
    }

    private void getEncoding(Result callbackContext, JSONObject data) throws JSONException {
        EscPosPrinter printer = this.getPrinter(callbackContext, data);
        EscPosCharsetEncoding encoding = printer.getEncoding();
        if (encoding == null) {
            callbackContext.success("null");
        } else {
            JSONArray command = new JSONArray();
            for (byte value : encoding.getCommand()) command.put((int) value);
            callbackContext.success(new JSONObject().put("name", encoding.getName()).put("command", command));
        }
    }

    private void disconnectPrinter(Result callbackContext, JSONObject data) throws JSONException {
        EscPosPrinter printer = this.getPrinter(callbackContext, data);
        printer.disconnectPrinter();
        callbackContext.success();
    }

    private DeviceConnection getDevice(Result callbackContext, String type, String id, String address, int port) {
        String hashKey = type + "-" + id;
        if (this.connections.containsKey(hashKey)) {
            DeviceConnection connection = this.connections.get(hashKey);
            if (connection != null) {
                if (connection.isConnected()) {
                    return connection;
                } else {
                    this.connections.remove(hashKey);
                }
            }
        }

        if (type.equals("bluetooth")) {
            if (!this.checkBluetooth(callbackContext)) {
                return null;
            }
            if (id.equals("first")) {
                return BluetoothPrintersConnections.selectFirstPaired();
            }
            BluetoothConnections printerConnections = new BluetoothConnections();
            for (BluetoothConnection bluetoothConnection : printerConnections.getList()) {
                BluetoothDevice bluetoothDevice = bluetoothConnection.getDevice();
                try { if (bluetoothDevice.getAddress().equals(id)) { return bluetoothConnection; } } catch (Exception ignored) {}
                try { if (bluetoothDevice.getName().equals(id)) { return bluetoothConnection; } } catch (Exception ignored) {}
            }
        } else if (type.equals("tcp")) {
            return new TcpConnection(address, port);
        } else {
            UsbConnections printerConnections = new UsbConnections(getActivity());
            for (UsbConnection usbConnection : printerConnections.getList()) {
                UsbDevice usbDevice = usbConnection.getDevice();
                try { if (usbDevice.getDeviceId() == Integer.parseInt(id)) { return usbConnection; } } catch (Exception ignored) {}
                try { if (Objects.requireNonNull(usbDevice.getProductName()).trim().equals(id)) { return usbConnection; } } catch (Exception ignored) {}
            }
        }

        return null;
    }

    private EscPosPrinter getPrinter(Result callbackContext, JSONObject data) throws JSONException {
        DeviceConnection deviceConnection = this.getPrinterConnection(callbackContext, data);
        if (deviceConnection == null) {
            throw new JSONException("Device not found");
        }

        EscPosCharsetEncoding charsetEncoding = null;
        try {
            if (data.optJSONObject("charsetEncoding") != null) {
                JSONObject charsetEncodingData = data.optJSONObject("charsetEncoding");
                if (charsetEncodingData == null) {
                    charsetEncodingData = new JSONObject();
                }
                charsetEncoding = new EscPosCharsetEncoding(
                    charsetEncodingData.optString("charsetName", "windows-1252"),
                    charsetEncodingData.optInt("charsetId", 16)
                );
            }
        } catch (Exception exception) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", exception.getMessage());
            }}));
            throw new JSONException(exception.getMessage());
        }

        try {
            return new EscPosPrinter(
                deviceConnection,
                data.optInt("printerDpi", 203),
                (float) data.optDouble("printerWidthMM", 48f),
                data.optInt("printerNbrCharactersPerLine", 32),
                charsetEncoding
            );
        } catch (Exception e) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", e.getMessage());
            }}));
            throw new JSONException(e.getMessage());
        }
    }

    private DeviceConnection getPrinterConnection(Result callbackContext, JSONObject data) throws JSONException {
        String type = data.getString("type");
        String id = data.getString("id");
        String hashKey = type + "-" + id;
        DeviceConnection deviceConnection = this.getDevice(
            callbackContext,
            data.getString("type"),
            data.optString("id"),
            data.optString("address"),
            data.optInt("port", 9100)
        );
        if (deviceConnection == null) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", "Device not found or not connected!");
                put("type", type);
                put("id", id);
            }}));
        }
        if (!this.connections.containsKey(hashKey)) {
            this.connections.put(hashKey, deviceConnection);
        }
        return deviceConnection;
    }

    private boolean checkBluetooth(Result callbackContext) {
        BluetoothAdapter mBluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
        if (mBluetoothAdapter == null) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", "Device doesn't support Bluetooth!");
            }}));
            return false;
        } else if (!mBluetoothAdapter.isEnabled()) {
            callbackContext.error(new JSONObject(new HashMap<String, Object>() {{
                put("error", "Device not enabled Bluetooth!");
            }}));
            return false;
        }
        return true;
    }
}
