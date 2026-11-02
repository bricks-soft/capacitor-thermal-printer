# Capacitor Thermal Printer

ESC/POS printing for Capacitor 8. Android retains DantSu 3.2.1; iOS uses the matching Swift encoder.

## Install

```sh
npm install @bricks-soft/capacitor-thermal-printer
npx cap sync
```

Until 1.0.0 is on npm, install from GitHub pinned to a commit on `main`: `git+https://github.com/bricks-soft/capacitor-thermal-printer.git#<commit>`.

Add `NSBluetoothAlwaysUsageDescription` to the iOS app's Info.plist. For TCP printers, also add `NSLocalNetworkUsageDescription`. CocoaPods and Swift Package Manager are supported. Minimums: iOS 15, Android API 24, Java 21.

## API

```ts
import { ThermalPrinter } from '@bricks-soft/capacitor-thermal-printer';

const permission = await ThermalPrinter.requestBTPermissions({ type: 'bluetooth' });
if (!permission.granted) throw new Error('Bluetooth permission denied');
const printers = await ThermalPrinter.listPrinters({ type: 'bluetooth' });
const printer = { type: 'bluetooth' as const, id: printers[0].address!, printerWidthMM: 48 };
const hex = await ThermalPrinter.bitmapToHexadecimalString({ ...printer, base64: receiptPng });
await ThermalPrinter.printFormattedText({ ...printer, text: `[C]<img>${hex}</img>\n`, dotsFeedPaper: 1 });
await ThermalPrinter.disconnectPrinter(printer);
```

All methods return Promises and reject on failure. `listPrinters` returns a printer array; `bitmapToHexadecimalString` and `bytesToHexadecimalString` return an ESC/POS image hex string. The latter accepts an array of PNG/JPEG file bytes, not raw pixels. Split tall receipt images into strips of at most 256 pixels before conversion.

`printFormattedTextAndCut` adds the cut command. `getEncoding` returns `{ name, command }` (signed command bytes), or the string `"null"` when unavailable. Print options retain the DantSu names and defaults: `printerDpi: 203`, `printerWidthMM: 48`, `printerNbrCharactersPerLine: 32`, `dotsFeedPaper: 20`; `mmFeedPaper` overrides dots. See [DantSu markup](https://github.com/DantSu/ESCPOS-ThermalPrinter-Android#formatted-text--syntax-guide).

`requestPermissions` retains the USB permission operation; `requestUSBPermissions` is its explicit alias. Bluetooth uses `requestBTPermissions`. Permissions resolve `{ granted }`; denial resolves `false`, while native errors reject.

| Platform | Connections | Permissions and limits |
| --- | --- | --- |
| Android | Paired classic Bluetooth SPP, TCP, USB | Android 12+ requests CONNECT and SCAN together. Legacy BLUETOOTH/ADMIN permissions apply through API 30. The manifest declares them; USB asks the system for the selected device. Bluetooth IDs remain paired names or MAC addresses. |
| iOS | BLE, TCP | BLE discovery and known printers; IDs are peripheral UUIDs or names. Classic SPP and USB are unavailable. `listPrinters({ type: 'usb' })` returns an empty array; USB permission requests reject. |
| Web | Unavailable | Every operation rejects with `UNAVAILABLE`. |

TCP options use `type: 'tcp'`, a stable `id`, `address`, and `port` (default 9100). Printing requires a compatible ESC/POS printer. Image receipts preserve Arabic glyphs; direct text depends on printer charset support.

## Verify

```sh
npm ci
npm test
npm ci --prefix example
cd example && npx cap sync android
cd android && ./gradlew :bricks-soft-capacitor-thermal-printer:testDebugUnitTest assembleDebug
```

The Android tests drive the frozen old wrapper in `tests/android-parity/legacy` and the Capacitor wrapper against the same receipt images and golden bytes. The legacy wrapper is test-only and excluded from the npm package.

On macOS run `xcodebuild test -scheme BricksSoftCapacitorThermalPrinter -destination 'platform=iOS Simulator,name=YOUR_SIMULATOR'`. Run `python3 tests/mutation/run.py REPO SCRATCH OUTPUT SIMULATOR_UDID` for the mutation checks. `tests/android-reference/generate.sh` regenerates golden fixtures from DantSu 3.2.1.

The example sends both reference receipts to a TCP capture at the `host` and `port` URL parameters (defaults `100.84.156.107:19100`), then checks paired Bluetooth listing. It does not exercise Bluetooth SPP printing or physical paper output.

## Publish

Releases are tagged on `main`. With the `NODE_AUTH_TOKEN` repository secret set, push a tag `v<version>` matching package.json (`v1.0.0` for the first release). The publish workflow checks the tag, runs `npm ci` and `npm test`, and publishes the public package.
