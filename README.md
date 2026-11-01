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

The iOS implementation keeps the JavaScript API, arguments, callbacks and error objects. Its ESC/POS output is a Swift port of DantSu 3.2.1, the library the Android side uses. [Tests](#tests) lists what is compared with it and how.

- **Bluetooth printers must support Bluetooth Low Energy.** iOS apps reach Bluetooth accessories through [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth). Printers that only offer classic Bluetooth's Serial Port Profile (what Android uses) need Apple's [MFi program](https://mfi.apple.com) and the [External Accessory framework](https://developer.apple.com/documentation/externalaccessory), so iOS cannot reach them.
- Add `NSBluetoothAlwaysUsageDescription` to `Info.plist` ([reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)). Cordova fills it from the `BLUETOOTH_USAGE_DESCRIPTION` variable. Capacitor only prints a warning, so add it yourself.
- TCP printing to a printer on the local network needs `NSLocalNetworkUsageDescription` ([reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)). While iOS asks for local network access, a connection waits up to 60 seconds instead of 5 ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
- The plugin remembers the printers it connected to in `Library/Application Support/ThermalPrinter/known-bluetooth-printers.json`. It calls none of Apple's [required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), so it needs no privacy manifest. Capacitor compiles Cordova plugin sources into its generated `CordovaPlugins.framework`, which has no resources of its own, so the plugin could not place a manifest there.
- A success callback means every byte was handed to the Bluetooth or TCP connection. Bluetooth writes without response have [no delivery guarantee](https://developer.apple.com/documentation/corebluetooth/cbperipheral/writevalue(_:for:type:)), so success does not prove that paper came out. The same holds for Android's RFCOMM stream.
- If the printer disconnects during a job, the call fails once with `{error: "Unable to send data to device."}` (or `"Bluetooth device disconnected."`). The rest of the job is dropped and the next call reconnects.
- USB printers are not supported: `listPrinters({type: 'usb'})` returns `[]`.
- Plain Cordova projects need Swift support (cordova-ios 6 or newer). Capacitor supports Swift Cordova plugins out of the box.

How the Bluetooth calls behave on iOS:

| Call | Android | iOS |
| --- | --- | --- |
| `requestBTPermissions` | Requests the Bluetooth runtime permissions | Shows the iOS Bluetooth prompt the first time; success `{granted: true}`, error `{granted: false}` |
| `listPrinters({type: 'bluetooth'})` | Paired devices | See the listing rule below. `address` is the iOS peripheral identifier (a UUID), `type` is `2` (LE) |
| `id` / `address` | MAC address or name | Peripheral identifier or name; `'first'` picks the first known printer that connects |
| Writes | RFCOMM stream | One GATT characteristic (see below), in chunks of `maximumWriteValueLength`, waiting for `canSendWriteWithoutResponse` |

`listPrinters` returns:

1. Devices this app has connected to before, and devices already connected to iOS that expose a known printer service.
2. Devices found in a 3-second scan that advertise a known printer service, or whose name looks like a printer: it contains `print`, `thermal` or `receipt`, or starts with `MPT`, `MTP`, `RPP`, `XP-`, `PT-`, `ZJ-`, `POS`, `Goojprt` or `PeriPage`. The name rule covers printers that advertise only a name. A device that advertises a printer service but no name is listed as `BLE Printer` plus the first 4 characters of its identifier. Other devices, such as headphones, TVs and watches, are not listed.

A printer that advertises neither a known service nor a printer-like name is not listed. Check each printer model you support from a fresh install.

Known printer services are `18F0`, `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2`, `49535343-FE7D-4AE5-8FA9-9FAFD205E455`, `FF00`, `FFE0` and `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, the GATT services that BLE ESC/POS printer modules commonly expose.

The bytes go to:

1. A known printer characteristic (`2AF1`, `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F`, `49535343-8841-43F4-A8D4-ECBE34729BB3`, `FF02`, `FFE1`, `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`).
2. Otherwise, a writable characteristic inside a known printer service.
3. Otherwise, the only writable characteristic outside the standard services (`1800`, `1801`, `180A`, `180F`). If there is more than one, connecting fails instead of guessing.

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

`tests/android-reference/generate.sh` runs the Android formatter (DantSu 3.2.1) on the JVM over `tests/android-reference/cases.json`. Images are read with Java ImageIO and passed to DantSu through an `android.graphics.Bitmap` stub, not Android's decoder. The expected output is stored in `src/ios/Tests/ThermalPrinterTests/Fixtures/android-reference.json`.

How the 47 reference cases are compared:

| Cases | Comparison |
| --- | --- |
| 25 printouts | Every byte and every send boundary. Includes the app's 72 mm and 48 mm image receipts and one QR code |
| 12 errors | The error message and the bytes sent before it |
| 4 images | The hex string |
| 2 encodings | The `getEncoding` result |
| 2 scaled images | Header and length only: Core Graphics and Skia resample differently |
| 2 QR codes | Number of sends, and both the iOS and the Android raster scan back to the payload |

The other Swift tests cover:

- Bluetooth transport, through a fake link: chunks of `maximumWriteValueLength`; flow control, including a missing readiness callback; acknowledged writes; write errors and stalls, after which the buffer is cleared, the link is dropped and a retry sends only its own bytes; connection and discovery timeouts; devices without a printer characteristic; disconnects during a send and between receipt segments; the app receipt sent over Bluetooth with the reference bytes.
- Late callbacks. Every connection attempt, discovery and acknowledged write carries its own token. The fake link follows Core Bluetooth's rule that no peripheral callbacks arrive after `didDisconnect`; some tests turn that rule off to check the tokens on their own. Tested: an acknowledgement from a cancelled write that arrives before its disconnect callback, or (with the rule off) after the reconnect, does not complete the newer write. A connection or discovery result from a cancelled attempt does not complete the next attempt. A cancelled link's disconnect does not end the new connection.
- The Core Bluetooth adapter starts the next connection only after the cancelled one ends with `didDisconnect` or `didFailToConnect`, or after 2 seconds if neither arrives. This is tested through the adapter class with a stubbed peripheral: connect, cancel, connect, then the old `didConnect` and `didDisconnect`; a cancelled pending connection ending in `didFailToConnect`; adopting during a cancellation; a missing terminal callback; and a full reconnect through the connection. Core Bluetooth itself is not exercised; a real printer has to qualify that.
- Discovery through the real scan path, with a fake central manager: devices with a printer service and no name, printer-like names, and unrelated or non-connectable devices.
- Bluetooth permission and state: prompt allowed, denied or unanswered; restricted access without a prompt; powered off, unsupported and unauthorized errors; waiting for Bluetooth to power on.
- The plugin API: a disconnect between receipt segments, before the feed or before the cut reports exactly one error.
- Memory: the parser, its lines, columns and images are released after printing, and 25 long receipts grow the footprint by less than 20 MB. With a strong column back-reference the same test grows it by about 58 MB.
- TCP, against an in-process fake printer: the reference bytes, a refused port, an unreachable address, and reconnecting after the printer closes the socket. With a scripted connection: waiting for local network permission and then connecting, the permission wait timing out and cleaning up, other waiting reasons failing at once, the connect timeout, and the printer closing the socket.
- The remembered-printer file.
- The Bluetooth listing and characteristic rules above.

Run them on a simulator:

    $ cd src/ios
    $ xcodebuild test -scheme ThermalPrinter -destination 'platform=iOS Simulator,name=iPhone 17'

`tests/mutation/run.py` puts back, one at a time, each defect these tests guard against and checks that the tests catch it: `python3 tests/mutation/run.py <repo> <scratch dir> <log dir> <simulator id>`. It exits 1 if a mutation survives (`MISSED`) or its tests do not run, for example because the build fails (`INFRA`). `MUTATIONS_MODULE=selftest_mutations` runs one example of each.

Only a real device can show printing on a BLE printer, the local network prompt and Android's own image decoding.

Known differences from Android:

- `<qrcode>` uses Core Image's [QR code generator](https://developer.apple.com/documentation/coreimage/ciqrcodegenerator) instead of ZXing. Some payloads produce the same symbol; others encode with a different version or mask and still scan.
- Images wider than the paper or taller than 256 dots are scaled with Core Graphics, not Skia, so their pixels can differ. Images that already fit are compared byte for byte.
- TCP connections wait up to 5 seconds (Android: 30 ms) and reconnect after the printer closes the socket.
- A disconnect during a job fails the call. Android's DantSu skips the remaining commands when its connection reports disconnected.
