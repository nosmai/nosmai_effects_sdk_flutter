![Nosmai Effects SDK Banner](banner.jpg)

# Nosmai Effects SDK for Flutter

The official Flutter plugin for integrating Nosmai Effects with real-time camera preview,
beauty effects, AR effects, LUT filters, recording, and local/cloud filter
discovery.

## Features

- Real-time camera preview on Android and iOS
- Beauty controls such as smoothing, whitening, face shape, lipstick, blush, and eye makeup
- `.nosmai` AR effects and regular filter/LUT effects
- Local production filter listing with manifest metadata
- Development-only loose `.nosmai` filter discovery
- Cloud filter listing, pagination, download, and removal
- Front/back camera switching, photo capture, video recording, and gallery save

## Platform Support

| Platform | Status |
|----------|--------|
| iOS      | iOS 15.0+, physical ARM64 device |
| Android  | API 21+, ARM64 (`arm64-v8a`) device |

The iOS simulator is not supported. Camera, rendering, filters, and recording
must be built and tested on a physical ARM64 iOS device.

## Installation

```yaml
dependencies:
  nosmai_effects_sdk: ^1.0.0
```

### Migrating from `nosmai_camera_sdk`

Replace the dependency and public Dart import:

```dart
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';
```

The existing `NosmaiFlutter`, `NosmaiCameraPreview`, filter, camera, and cloud
API usage remains unchanged. Keep the native Android AAR and iOS CocoaPods
setup described below.

## Setup

### iOS

The plugin installs the proprietary `NosmaiCameraSDK` native dependency through
CocoaPods. Do not copy an iOS framework into the Flutter application manually.

Update `ios/Podfile`:

```ruby
platform :ios, '15.0'

target 'Runner' do
  use_frameworks! :linkage => :static
  use_modular_headers!

  flutter_install_all_ios_pods(File.dirname(File.realpath(__FILE__)))
end
```

Add permissions to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera to apply real-time filters.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone for video recording.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>This app saves photos and videos to your gallery.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>This app saves photos and videos to your gallery.</string>
```

### Android

The proprietary Android SDK is distributed separately and is not included in
the pub.dev package.

1. Download `nosmai-sdk-3.0.0.aar` from the
   [Android SDK v3.0.0 release](https://github.com/nosmai/camera-sdk-android/releases/tag/v3.0.0).
2. Verify it with the release `SHA256SUMS` file.
3. Rename it to `nosmai-release.aar` and place it at
   `android/app/libs/nosmai-release.aar`.

Add the local AAR repository to `android/build.gradle`:

```gradle
allprojects {
  repositories {
    google()
    mavenCentral()
    flatDir { dirs "${rootProject.projectDir}/app/libs" }
  }
}
```

For projects using Kotlin DSL, add the equivalent to
`android/build.gradle.kts`:

```kotlin
allprojects {
  repositories {
    google()
    mavenCentral()
    flatDir { dirs("${rootProject.projectDir}/app/libs") }
  }
}
```

Add the native SDK to `android/app/build.gradle`:

```gradle
dependencies {
  implementation files('libs/nosmai-release.aar')
}
```

Kotlin DSL (`android/app/build.gradle.kts`):

```kotlin
dependencies {
  implementation(files("libs/nosmai-release.aar"))
}
```

The current native SDK supports ARM64 Android devices (`arm64-v8a`).

Restrict the consuming app to the supported ABI in
`android/app/build.gradle`:

```gradle
android {
  defaultConfig {
    ndk {
      abiFilters "arm64-v8a"
    }
  }
}
```

Add permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

## Basic Usage

```dart
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const licenseKey = String.fromEnvironment('NOSMAI_LICENSE_KEY');
  if (licenseKey.isEmpty) {
    throw StateError('NOSMAI_LICENSE_KEY is required');
  }
  await NosmaiFlutter.initialize(licenseKey);
  runApp(const MyApp());
}
```

Pass the key at build or run time. Do not commit production keys to source
control:

```bash
flutter run --dart-define=NOSMAI_LICENSE_KEY=YOUR_LICENSE_KEY
```

```dart
class CameraScreen extends StatelessWidget {
  const CameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: NosmaiCameraPreview(),
    );
  }
}
```

## Applying Filters

Use `applyEffect` for every external `.nosmai` package. The package manifest
routes `filter`, `effect`, `beauty_effect`, and `background` to the correct
native render slot.

```dart
final nosmai = NosmaiFlutter.instance;
await nosmai.applyEffect(filter.path);
```

`applyFilter` remains available only as a legacy compatibility alias.

Clear specific layers when needed:

```dart
await nosmai.clearFilter();    // regular filter only
await nosmai.clearAREffect();  // AR effect only
await nosmai.clearAll();       // AR, filter, beauty, and background
```

## Local Filters

The plugin and its example app do not ship any `.nosmai` filter binaries.
Add only the licensed filters owned by your application to the consuming app.

Production local filters should use the manifest-based folder structure:

```text
assets/nosmai_filters/
  glam_lips/
    glam_lips_manifest.json
    glam_lips_preview.png
    glam_lips.nosmai
```

Declare each filter folder in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/nosmai_filters/glam_lips/
    - assets/nosmai_filters/soft_blush/
```

Load production filters:

```dart
final filters = await nosmai.getLocalFilters();
final grouped = await nosmai.getAllLocalFilters();
final effects = await nosmai.getLocalEffects();
final backgrounds = await nosmai.getLocalBackgrounds();
final beauty = await nosmai.getLocalBeautyEffects();
```

The plugin uses Flutter's supported `AssetManifest` API to discover declared
assets. It does not depend on the removed `AssetManifest.json` build file.

## Debug Filters

`getDebugFilters` is intentionally kept for development/testing. Use it when
you want to bundle loose `.nosmai` files directly, usually under
`assets/filters/`, without creating manifest and preview files.

```yaml
flutter:
  assets:
    - assets/filters/
```

```dart
final allDebugFilters = await nosmai.getDebugFilters();

final debugEffects = await nosmai.getDebugFilters(
  type: NosmaiLocalFilterType.effect,
);
```

For production apps, prefer the manifest-based local filter methods above.

## Cloud Filters

```dart
final allFilters = await nosmai.getCloudFilters();

final page = await nosmai.getCloudFilters(
  filterType: NosmaiCloudFilterType.effects,
  version: NosmaiCloudFilterVersion.v2,
  page: 1,
  limit: 20,
);

final beautyEffects = await nosmai.getCloudFilters(
  filterType: NosmaiCloudFilterType.beautyEffect,
);

final pagination = nosmai.lastPaginationInfo;
```

`version` is optional. Cloud filter version 2 is used by default, so existing
`getCloudFilters()` calls remain unchanged.

Download and apply a cloud filter:

```dart
final result = await nosmai.downloadCloudFilter(filter.cloudIdentifier);
final path = result['path'] as String?;
if (path != null) {
  await nosmai.applyEffect(path);
}
```

## Camera Controls

```dart
await nosmai.switchCamera();

final photo = await nosmai.capturePhoto();
if (photo.success) {
  await nosmai.saveImageToGallery(photo.imageData!);
}

await nosmai.startRecording();
final recording = await nosmai.stopRecording();
if (recording.success && recording.videoPath != null) {
  await nosmai.saveVideoToGallery(recording.videoPath!);
}
```

## Lifecycle

Use `pauseCamera`/`resumeCamera` for short tab changes where you want fast
return to the camera. Use `cleanup` when leaving the camera flow and releasing
native camera/GL resources.

```dart
await nosmai.pauseCamera();
await nosmai.resumeCamera();
await nosmai.cleanup();
```

## Support

- Plugin issues: [GitHub Issues](https://github.com/nosmai/nosmai_effects_sdk_flutter/issues)
- SDK documentation: [Nosmai Effects documentation](https://nosmai.com/docs/effects/introduction/)
- License registration: [https://effects.nosmai.com/](https://effects.nosmai.com/)

## License

This plugin and its associated native SDKs are proprietary commercial software.
Use, modification, redistribution, reverse engineering, or sublicensing is not
permitted without written authorization from Nosmai. A valid license agreement
and platform license key are required. See [LICENSE](LICENSE).
