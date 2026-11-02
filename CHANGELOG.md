# Changelog

The major version follows Capacitor. Versions within it follow [Semantic Versioning](https://semver.org/).

## [8.0.1] - 2026-11-02

First version published by CI through npm trusted publishing, with a provenance statement. No code changes.

## [8.0.0] - 2026-11-02

First release as a Capacitor 8 plugin, replacing the Cordova plugin `thermal-printer-cordova-plugin`.

- Native Capacitor wrappers for Android and iOS with a typed Promise API. Method names and success and error payloads match the Cordova plugin.
- Android keeps the DantSu ESC/POS 3.2.1 code; output is byte-identical to the Cordova plugin.
- iOS support: a Swift port of the same encoder over Bluetooth LE and TCP. It produces the same receipt bytes as Android.
- Swift Package Manager and CocoaPods; iOS 15+, Android API 24+.
