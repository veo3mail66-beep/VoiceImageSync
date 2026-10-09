# Voice Image Sync (Flutter)

Audio + TXT script + Images -> MP4 video (FFmpeg, offline).
Har image ko script ke words ke hisaab se audio ka hissa milta hai.

## Sabse aasan: GitHub se APK (PC/Flutter install ki zaroorat nahi)
1. github.com par free account -> New repository.
2. Is poore folder ki files upload karo (`.github` folder samet).
3. Repo mein **Actions** tab -> **Build APK** -> **Run workflow**.
4. 8-15 minute baad us run ke andar **Artifacts -> VoiceImageSync-apk** download karo.
   Zip kholo, andar `app-release.apk` hai. Phone par install karo.

## PC par khud banana (Linux / Mac / Termux-style shell)
Flutter SDK + Android SDK + Java 17 chahiye.

    bash setup.sh
    flutter build apk --release --no-shrink --target-platform android-arm64

APK: `build/app/outputs/flutter-apk/app-release.apk`

Pehli build mein agar FFmpeg wali library ka error aaye to wohi command dobara chala do.

## Windows (manual)
    flutter create --org com.rizwan --project-name voice_image_sync --platforms=android .
(lib/main.dart aur pubspec.yaml ko is project wali files se wapas replace karo)
Phir `android/app/build.gradle(.kts)` mein `minSdk` ko `24` kar do aur:

    flutter pub get
    flutter build apk --release --no-shrink --target-platform android-arm64

## Note
- `--target-platform android-arm64` APK chhota rakhta hai (zyada tar phones ke liye theek).
  Bahut purane 32-bit phone ho to ye flag hata do.
- Video `Movies/VoiceImageSync` (Gallery) mein save hoti hai.
