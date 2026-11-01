#!/usr/bin/env bash
# Regenerates src/ios/Tests/ThermalPrinterTests/Fixtures/android-reference.json by running the
# DantSu ESC/POS library version the Android plugin uses (3.2.1) on the JVM with Bitmap stubs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
fixtures="$root/src/ios/Tests/ThermalPrinterTests/Fixtures"
work="${WORK_DIR:-$(mktemp -d)}"

dantsu_version="3.2.1"
zxing_url="https://repo1.maven.org/maven2/com/google/zxing/core/3.4.0/core-3.4.0.jar"
zxing_sha1="5264296c46634347890ec9250bc65f14b7362bf8"
json_url="https://repo1.maven.org/maven2/org/json/json/20231013/json-20231013.jar"
json_sha1="e22e0c040fe16f04ffdb85d851d77b07fc05ea52"

fetch() {
  local url="$1" sha1="$2" target="$3"
  [ -f "$target" ] || curl -sSfL "$url" -o "$target"
  echo "$sha1  $target" | sha1sum -c --quiet -
}

mkdir -p "$work/classes" "$fixtures/images"
fetch "$zxing_url" "$zxing_sha1" "$work/zxing-core.jar"
fetch "$json_url" "$json_sha1" "$work/json.jar"
[ -d "$work/dantsu" ] || git clone -q --depth 1 --branch "$dantsu_version" https://github.com/DantSu/ESCPOS-ThermalPrinter-Android.git "$work/dantsu"

library="$work/dantsu/escposprinter/src/main/java/com/dantsu/escposprinter"
sources=$(find "$library" -name '*.java' ! -path '*/connection/bluetooth/*' ! -path '*/connection/usb/*')
classpath="$work/zxing-core.jar:$work/json.jar"

javac -nowarn -encoding UTF-8 -d "$work/classes" -cp "$classpath" \
  $(find "$here/stubs" -name '*.java') $sources "$here/src/FixtureImages.java" "$here/src/ReferenceGenerator.java"

if [ ! -f "$fixtures/images/receipt-72mm-0.png" ]; then
  java -cp "$work/classes:$classpath" FixtureImages "$fixtures/images"
fi

java -cp "$work/classes:$classpath" ReferenceGenerator "$here/cases.json" "$fixtures/images" "$fixtures/android-reference.json"
echo "wrote $fixtures/android-reference.json"
