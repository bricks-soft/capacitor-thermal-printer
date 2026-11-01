## Cordova Plugin for Thermal Printer's
[![npm version](https://img.shields.io/npm/v/thermal-printer-cordova-plugin.svg)](https://www.npmjs.com/package/thermal-printer-cordova-plugin) [![npm downloads](https://img.shields.io/npm/dm/thermal-printer-cordova-plugin.svg)](https://www.npmjs.com/package/thermal-printer-cordova-plugin)

---

This plugin is a wrapper for the [Android library for ESC/POS Thermal Printer](https://github.com/DantSu/ESCPOS-ThermalPrinter-Android).

### Install

#### Cordova

    $ cordova plugin add thermal-printer-cordova-plugin

#### Ionic

    $ ionic cordova plugin add thermal-printer-cordova-plugin

#### Capacitor

    $ npm install thermal-printer-cordova-plugin
    $ npx cap sync

Don't forget to add BLUETOOTH and INTERNET (for TCP) permissions and for USB printers the `android.hardware.usb.host` feature to the `AndroidManifest.xml`.

```xml
<uses-feature android:name="android.hardware.usb.host" />
<uses-permission android:maxSdkVersion="30" android:name="android.permission.BLUETOOTH" />
<uses-permission android:maxSdkVersion="30" android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
```

#### iOS

The iOS implementation keeps the same JavaScript API, arguments, callbacks and error objects. Its ESC/POS output is a Swift port of DantSu 3.2.1 (the library the Android side uses) and is checked byte for byte against that library (see [Tests](#tests)).

- **Bluetooth printers must support Bluetooth Low Energy.** iOS apps reach Bluetooth printers through [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth). Classic Bluetooth printers that only offer the Serial Port Profile (what Android uses) need Apple's [MFi program](https://mfi.apple.com) and the [External Accessory framework](https://developer.apple.com/documentation/externalaccessory), so iOS cannot reach them. Many printers are dual-mode and also offer BLE.
- Add `NSBluetoothAlwaysUsageDescription` to `Info.plist` ([reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)). Cordova fills it from the `BLUETOOTH_USAGE_DESCRIPTION` variable. Capacitor only prints a warning, so add it yourself.
- TCP printing to a printer on the local network needs `NSLocalNetworkUsageDescription` ([reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)).
- USB printers are not supported: `listPrinters({type: 'usb'})` returns `[]`.
- Plain Cordova projects need Swift support (cordova-ios 6 or newer). Capacitor supports Swift Cordova plugins out of the box.

How the Bluetooth calls behave on iOS:

| Call | Android | iOS |
| --- | --- | --- |
| `requestBTPermissions` | Requests the Bluetooth runtime permissions | Shows the iOS Bluetooth prompt the first time; success `{granted: true}`, error `{granted: false}` |
| `listPrinters({type: 'bluetooth'})` | Paired devices | Printers this app connected to before, plus BLE devices found in a 3-second scan. `address` is the iOS peripheral identifier (a UUID), `type` is `2` (LE) |
| `id` / `address` | MAC address or name | Peripheral identifier or name; `'first'` picks the first known printer that connects |
| Writes | RFCOMM stream | The printer's writable GATT characteristic, in chunks of `maximumWriteValueLength`, with iOS flow control |

Run this for getting Bluetooth access permission if needed

```javascript
ThermalPrinter.requestBTPermissions({type: 'bluetooth'}, function(result){ console.log(result) }, function(error){ console.log(error) });
```

### Examples

#### Notice for TypeScript-Developers

You can easily import and use the ThermalPrinter plugin in your TypeScript-Projects.

```typescript
import { ThermalPrinterPlugin } from 'thermal-printer-cordova-plugin/src';

declare let ThermalPrinter: ThermalPrinterPlugin;
```

And then use the following examples in your code.

#### Print via Bluetooth

Printing via Bluetooth is as easy as possible.

```javascript
ThermalPrinter.printFormattedText({
    type: 'bluetooth',
    id: 'first', // You can also use the identifier directly i. e. 00:11:22:33:44:55 (address) or name
    text: '[C]<u><font size='big'>Hello World</font></u>' // new lines with "\n"
}, function() {
    console.log('Successfully printed!');
}, function(error) {
    console.error('Printing error', error);
});
```

**Notice:** If not working please ensure that you have the printer connected. (Settings -> Bluetooth -> Pairing)
If you have other issues maybe you have not granted the `android.permission.BLUETOOTH` permission.

#### Print via TCP

Printing via TCP is as easy as possible.

```javascript
ThermalPrinter.printFormattedText({
    type: 'tcp',
    address: '192.168.1.123',
    port: 9100,
    id: 'tcp-printer-001', // Use an unique identifier for each printer i. e. address:port or name
    text: '[C]<u><font size='big'>Hello World</font></u>' // new lines with "\n"
}, function() {
    console.log('Successfully printed!');
}, function(error) {
    console.error('Printing error', error);
});
```

**Notice:** If not working please ensure that your device can ping the printer. And the printer must be a POSPrinter!
Also ensure that you're using the correct port. 9100 is default for the thermal printers.

#### Print via USB (incl. listPrinters and requestPermissions)

1. First we get our printer because we don't know the printer's ID.
2. Then we request permissions for printing. This is needed because Android will not allow us to access all devices.
3. And finally we can print with our device.

```javascript
ThermalPrinter.listPrinters({type: 'usb'}, function(printers) {
    if (printers.length > 0) {
        var printer = printers[0];
        ThermalPrinter.requestPermissions(printer, function() {
            // Permission granted - We can print!
            ThermalPrinter.printFormattedText({
                type: 'usb',
                id: printer.id,
                text: '[C]<u><font size='big'>Hello World</font></u>' // new lines with "\n"
            }, function() {
                console.log('Successfully printed!');
            }, function(error) {
                console.error('Printing error', error);
            });
        }, function(error) {
            console.error('Permission denied - We can\'t print!');
        });
    } else {
        console.error('No printers found!');
    }
}, function(error) {
    console.error('Ups, we cant list the printers!', error);
});
```

### listPrinters(data, successCallback, errorCallback)
List available printers

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Object</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;usb&quot;</code> | Type of list: bluetooth or usb |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="printFormattedText"></a>

### printFormattedText(data, successCallback, errorCallback)
Print a formatted text and feed paper

**See**: https://github.com/DantSu/ESCPOS-ThermalPrinter-Android#formatted-text--syntax-guide  

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;tcp&quot;</code> \| <code>&quot;usb&quot;</code> | List all bluetooth or usb printers |
| [data.id] | <code>string</code> \| <code>number</code> | ID of printer to find (Bluetooth: address, TCP: Use address + port instead, USB: deviceId) |
| [data.address] | <code>string</code> | If type is "tcp" then the IP Address of the printer |
| [data.port] | <code>number</code> | If type is "tcp" then the Port of the printer |
| [data.mmFeedPaper] | <code>number</code><code>optional</code> | Millimeter distance feed paper at the end |
| [data.dotsFeedPaper] | <code>number</code><code>optional</code> | Distance feed paper at the end |
| [data.printerDpi] | <code>number</code><code>optional</code> | Printer DPI |
| [data.printerWidthMM] | <code>number</code><code>optional</code> | Paper Width in mm |
| [data.printerNbrCharactersPerLine] | <code>number</code><code>optional</code> | Number of characters per line |
| data.text | <code>string</code> | Formatted text to be printed |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="printFormattedTextAndCut"></a>

### printFormattedTextAndCut(data, successCallback, errorCallback)
Print a formatted text, feed paper and cut the paper

**See**: https://github.com/DantSu/ESCPOS-ThermalPrinter-Android#formatted-text--syntax-guide  

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;tcp&quot;</code> \| <code>&quot;usb&quot;</code> | List all bluetooth or usb printers |
| [data.id] | <code>string</code> \| <code>number</code> | ID of printer to find (Bluetooth: address, TCP: Use address + port instead, USB: deviceId) |
| [data.address] | <code>string</code> | If type is "tcp" then the IP Address of the printer |
| [data.port] | <code>number</code> | If type is "tcp" then the Port of the printer |
| [data.mmFeedPaper] | <code>number</code><code>optional</code> | Millimeter distance feed paper at the end |
| [data.dotsFeedPaper] | <code>number</code><code>optional</code> | Distance feed paper at the end |
| [data.printerDpi] | <code>number</code><code>optional</code> | Printer DPI |
| [data.printerWidthMM] | <code>number</code><code>optional</code> | Paper Width in mm |
| [data.printerNbrCharactersPerLine] | <code>number</code><code>optional</code> | Number of characters per line |
| data.text | <code>string</code> | Formatted text to be printed |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="getEncoding"></a>

### getEncoding(data, successCallback, errorCallback)
Get the printer encoding when available

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;tcp&quot;</code> \| <code>&quot;usb&quot;</code> | List all bluetooth or usb printers |
| [data.id] | <code>string</code> \| <code>number</code> | ID of printer to find (Bluetooth: address, TCP: Use address + port instead, USB: deviceId) |
| [data.address] | <code>string</code> | If type is "tcp" then the IP Address of the printer |
| [data.port] | <code>number</code> | If type is "tcp" then the Port of the printer |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="disconnectPrinter"></a>

### disconnectPrinter(data, successCallback, errorCallback)
Close the connection with the printer

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;tcp&quot;</code> \| <code>&quot;usb&quot;</code> | List all bluetooth or usb printers |
| [data.id] | <code>string</code> \| <code>number</code> | ID of printer to find (Bluetooth: address, TCP: Use address + port instead, USB: deviceId) |
| [data.address] | <code>string</code> | If type is "tcp" then the IP Address of the printer |
| [data.port] | <code>number</code> | If type is "tcp" then the Port of the printer |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="requestPermissions"></a>

### requestPermissions(data, successCallback, errorCallback)
Request permissions for USB printers

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;tcp&quot;</code> \| <code>&quot;usb&quot;</code> | List all bluetooth or usb printers |
| [data.id] | <code>string</code> \| <code>number</code> | ID of printer to find (Bluetooth: address, TCP: Use address + port instead, USB: deviceId) |
| [data.address] | <code>string</code> | If type is "tcp" then the IP Address of the printer |
| [data.port] | <code>number</code> | If type is "tcp" then the Port of the printer |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |


<a name="requestBTPermissions"></a>

### requestBTPermissions(data, successCallback, errorCallback)
Request permissions for bluetooth

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> | List all bluetooth or usb printers |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="bitmapToHexadecimalString"></a>

### bitmapToHexadecimalString(data, successCallback, errorCallback)
Convert Drawable instance to a hexadecimal string of the image data

| Param | Type | Description |
| --- | --- | --- |
| data | <code>Array.&lt;Object&gt;</code> | Data object |
| data.type | <code>&quot;bluetooth&quot;</code> \| <code>&quot;tcp&quot;</code> \| <code>&quot;usb&quot;</code> | List all bluetooth or usb printers |
| [data.id] | <code>string</code> \| <code>number</code> | ID of printer to find (Bluetooth: address, TCP: Use address + port instead, USB: deviceId) |
| [data.address] | <code>string</code> | If type is "tcp" then the IP Address of the printer |
| [data.port] | <code>number</code> | If type is "tcp" then the Port of the printer |
| [data.mmFeedPaper] | <code>number</code><code>optional</code> | Millimeter distance feed paper at the end |
| [data.dotsFeedPaper] | <code>number</code><code>optional</code> | Distance feed paper at the end |
| [data.printerDpi] | <code>number</code><code>optional</code> | Printer DPI |
| [data.printerWidthMM] | <code>number</code><code>optional</code> | Paper Width in mm |
| data.base64 | <code>string</code> | Base64 encoded picture string to convert |
| successCallback | <code>function</code> | Result on success |
| errorCallback | <code>function</code> | Result on failure |

<a name="tests"></a>

### Tests

`tests/android-reference/generate.sh` runs DantSu 3.2.1 on the JVM (with `android.graphics.Bitmap` stubs) over `tests/android-reference/cases.json` and writes the expected bytes to `src/ios/Tests/ThermalPrinterTests/Fixtures/android-reference.json`. The iOS tests compare the Swift output with that file and print over TCP to an in-process fake printer:

    $ cd src/ios
    $ xcodebuild test -scheme ThermalPrinter -destination 'platform=iOS Simulator,name=iPhone 17'

Known differences from Android:

- `<qrcode>` uses Core Image's [QR code generator](https://developer.apple.com/documentation/coreimage/ciqrcodegenerator) instead of ZXing. Short alphanumeric payloads produce the same symbol; other payloads can encode with a different version or mask (still scannable).
- Images larger than the paper width or 256 dots are scaled with Core Graphics, not Skia, so their pixels can differ. Images that already fit (the usual case) are byte-identical.
- TCP connections wait up to 5 seconds (Android: 30 ms) and are reopened after the printer closes the socket.
