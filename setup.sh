#!/usr/bin/env bash
# One-time setup: generates the android/ folder and applies the needed settings.
set -e
cd "$(dirname "$0")"

if ! command -v flutter >/dev/null 2>&1; then
  echo "ERROR: flutter command nahi mili. Pehle Flutter SDK install karo."
  exit 1
fi

# keep our own files safe while flutter create runs
mkdir -p .keep
cp lib/main.dart .keep/main.dart
cp pubspec.yaml .keep/pubspec.yaml

flutter create --org com.rizwan --project-name voice_image_sync --platforms=android .

cp .keep/main.dart lib/main.dart
cp .keep/pubspec.yaml pubspec.yaml
rm -rf .keep test

patch_file() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }

# FFmpegKit needs minSdk 24
for f in android/app/build.gradle android/app/build.gradle.kts; do
  if [ -f "$f" ]; then
    patch_file 's/minSdkVersion flutter\.minSdkVersion/minSdkVersion 24/' "$f"
    patch_file 's/minSdkVersion = flutter\.minSdkVersion/minSdkVersion = 24/' "$f"
    patch_file 's/minSdk = flutter\.minSdkVersion/minSdk = 24/' "$f"
    echo "--- minSdk lines in $f:"
    grep -n "minSdk" "$f" || true
  fi
done

# Android 9 and older need this to save into the gallery
M=android/app/src/main/AndroidManifest.xml
if ! grep -q WRITE_EXTERNAL_STORAGE "$M"; then
  patch_file 's|<application|<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/> <application|' "$M"
fi

flutter pub get
echo
echo "Setup complete. Ab chalao:"
echo "  flutter build apk --release --no-shrink --target-platform android-arm64"
