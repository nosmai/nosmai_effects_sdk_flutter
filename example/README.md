# Nosmai Effects SDK Flutter Example

This application demonstrates the production Flutter plugin flow on Android
and iOS, including camera preview, photo and video capture, cloud filters,
backgrounds, beauty controls, and camera switching. It intentionally ships
without local `.nosmai` filter binaries.

## Requirements

- Flutter compatible with the version declared by the package
- Android API 21 or later on an ARM64 device
- iOS 15 or later on a physical ARM64 device
- A valid Nosmai license key for each platform
- Camera and microphone permissions

The iOS simulator is not supported. Use a physical ARM64 iOS device.

## Native SDK Setup

iOS resolves `NosmaiCameraSDK 3.0.0` automatically through CocoaPods.

For Android, download `nosmai-sdk-3.0.0.aar` and `SHA256SUMS` from the
[Android SDK v3.0.0 release](https://github.com/nosmai/camera-sdk-android/releases/tag/v3.0.0),
verify the checksum, rename the AAR to `nosmai-release.aar`, and place it at:

```text
android/app/libs/nosmai-release.aar
```

The example intentionally does not include proprietary native binaries.

## Run the Example

Do not place production license keys in Dart source. Pass the appropriate key
at run time:

```bash
flutter pub get

flutter run \
  --dart-define=NOSMAI_ANDROID_LICENSE_KEY=YOUR_ANDROID_KEY \
  --dart-define=NOSMAI_IOS_LICENSE_KEY=YOUR_IOS_KEY
```

Only the key for the active platform is used.

## Production Builds

The Android native SDK currently supports `arm64-v8a`. Build the Android
example for that target after completing the native SDK setup above:

```bash
flutter build apk --release --target-platform android-arm64 \
  --dart-define=NOSMAI_ANDROID_LICENSE_KEY=YOUR_ANDROID_KEY
```

Build iOS on a Mac with an eligible signing configuration:

```bash
flutter build ios --release \
  --dart-define=NOSMAI_IOS_LICENSE_KEY=YOUR_IOS_KEY
```

## Main Files

- `lib/main.dart`: permissions, license initialization, and navigation
- `lib/unified_camera_screen.dart`: camera, recording, filters, backgrounds,
  and beauty interface
- `lib/filter_example.dart`: reference implementation for apps that provide
  their own licensed local filters

## Notes

- Repeated download taps are disabled while a cloud filter is downloading.
- Add licensed local filters in the consuming application; none are bundled
  with this package or example.
- External effects, filters, beauty effects, and backgrounds follow the native
  SDK compatibility rules.
- Use a physical device for camera, rendering, recording, and performance
  validation.

For commercial licensing and support, contact admin@nosmai.com.
