#!/bin/bash
# Build the FoldCast Android APK without Gradle/AGP — pure SDK build-tools.
# Produces android/foldcast.apk and (optionally) installs it.
set -euo pipefail
cd "$(dirname "$0")"

# d8/R8 8.2.2 (build-tools 34) misbehaves on JDK 21 — pin a JDK 17 if present.
for j in "$HOME/.local/share/mise/installs/java/temurin-17" \
         "$HOME/.local/share/mise/installs/java/zulu-17" \
         "$(/usr/libexec/java_home -v 17 2>/dev/null)"; do
  if [ -n "$j" ] && [ -x "$j/bin/javac" ]; then
    export JAVA_HOME="$j"; export PATH="$j/bin:$PATH"; break
  fi
done
echo "▸ JDK: $(java -version 2>&1 | head -1)"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/34.0.0"
AJAR="$SDK/platforms/android-34/android.jar"
PT="$SDK/platform-tools"
KS="$HOME/.android/debug.keystore"

[ -f "$AJAR" ] || { echo "android.jar not found: $AJAR"; exit 1; }
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -alias androiddebugkey \
    -storepass android -keypass android -dname "CN=Android Debug" \
    -keyalg RSA -keysize 2048 -validity 10000
fi

rm -rf build && mkdir -p build/compiled build/classes build/dex

echo "▸ aapt2 compile resources"
"$BT/aapt2" compile --dir res -o build/compiled/res.zip

echo "▸ aapt2 link"
"$BT/aapt2" link \
  -o build/base.apk \
  -I "$AJAR" \
  --manifest AndroidManifest.xml \
  --java build/gen \
  --min-sdk-version 24 --target-sdk-version 34 \
  build/compiled/res.zip

echo "▸ javac"
find src -name '*.java' > build/sources.txt
# d8 in build-tools 34 (R8 8.2.2) reliably handles up to Java 11 bytecode.
javac --release 11 -classpath "$AJAR" \
  -d build/classes @build/sources.txt

echo "▸ jar + d8 -> dex"
jar --create --file build/classes.jar -C build/classes .
"$BT/d8" --lib "$AJAR" --min-api 24 \
  --output build/dex build/classes.jar

echo "▸ assemble apk"
cp build/base.apk build/unsigned.apk
( cd build/dex && zip -q -u ../unsigned.apk classes.dex )

echo "▸ zipalign + sign"
"$BT/zipalign" -p -f 4 build/unsigned.apk build/aligned.apk
"$BT/apksigner" sign --ks "$KS" \
  --ks-pass pass:android --key-pass pass:android \
  --out foldcast.apk build/aligned.apk
"$BT/apksigner" verify foldcast.apk && echo "  signature OK"

echo "▸ built $(pwd)/foldcast.apk"

if [ "${1:-}" = "--install" ]; then
  echo "▸ adb install"
  "$PT/adb" install -r foldcast.apk
  "$PT/adb" shell am start -n com.kentaro.foldcast/.MainActivity
  echo "  launched on device"
fi
