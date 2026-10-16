![Nosmai Effects SDK Banner](banner.jpg)

# Nosmai Effects SDK for Flutter

Add real-time AR effects, beauty filters, digital makeup, background replacement,
interactive camera games, camera capture, and cloud filters to Flutter
applications through one SDK for Android and iOS.

## Installation

```yaml
dependencies:
  nosmai_effects_sdk: ^2.0.2
```

## Managed cloud previews

Use `NosmaiFilterPreview(filter: filter)` in filter tiles. It handles thumbnail
memory/disk caching, network loading, downloaded-package fallback and placeholders.
No cache toggle or extra initialization call is required. Existing `previewUrl`
values remain supported with a deprecation notice directing clients to this widget.

```dart
NosmaiFilterPreview(
  filter: filter,
  fit: BoxFit.cover,
  placeholder: (_) => const Icon(Icons.image_outlined),
  errorBuilder: (_) => const Icon(Icons.image_not_supported_outlined),
)
```

The preview cache allows 32 MB / 128 files on disk and 4 MB of encoded image
data in memory, with a seven-day TTL. URL/version changes invalidate cache keys.
The widget reads previews only; download/apply calls remain the host app's choice.

## Built for

Nosmai Effects can be used in:

- social media and short-video apps
- live streaming and video chat
- creator cameras and recording tools
- beauty and makeup experiences
- photo and video editing workflows
- virtual background experiences
- entertainment and interactive camera apps

## Key features

- Real-time camera preview with GPU-accelerated rendering
- Face detection and face-tracked AR effects
- 3D masks, stickers, particles, and animated overlays
- Face stickers from your own image or animated GIF, anchored to facial landmarks
- Hair colouring driven by on-device hair segmentation
- Skin smoothing, whitening, sharpening, and teeth whitening
- Lipstick, eyeshadow, blusher, eyelashes, and eyebrows
- Face slimming, eye size, nose, chin, jaw, lips, forehead, and brow controls
- LUT filters, brightness, contrast, hue, saturation, RGB, and white balance
- Background blur, color, image, video, and packaged background effects
- Interactive `.nosmai` games with touch/face input and typed event streams
- Local and cloud-based `.nosmai` filters
- Cloud filter browsing, pagination, download, caching, and removal
- Front and back camera switching
- Photo capture and processed video recording
- Processed camera output for live streaming integrations

## On-device processing

Camera frames, face tracking, beauty, AR effects, and background processing run
on the user's device. Camera frames do not need to be uploaded to apply visual
effects.

Network access is used for license verification, cloud filter discovery, and
filter downloads.

## Platform support

| Platform | Minimum requirement |
| --- | --- |
| Android | API 24 or later, physical `arm64-v8a` or `armeabi-v7a` device |
| iOS | iOS 15.0 or later, physical arm64 device |
| Flutter | Flutter 3.29.0 or later, Dart 3.0.0 or later |

Camera preview, face tracking, recording, and performance should be tested on
physical devices. The iOS simulator is not supported by the native Effects SDK.
Android production builds must include both Flutter target platforms
`android-arm` and `android-arm64` when both supported Nosmai ABIs are required.

## Face reshape controls

Use `setReshape` for the complete Android/iOS reshape set. Its value is signed
from `-1.0` to `1.0`, with `0.0` as neutral:

```dart
await nosmai.setReshape(type: NosmaiReshapeType.jaw, value: 0.25);
await nosmai.setReshape(type: NosmaiReshapeType.mouthWidth, value: -0.15);
```

Convenience methods are also available for lip size, chin size, eyebrow
position/thickness, jawline, mouth width, and forehead size. Existing
one-direction face-slim, eye-enlargement, and nose-slim methods remain
`0.0...1.0` for backward compatibility.

## Face stickers

Pin any image, or an animated GIF, to the tracked face. The developer hands the
SDK the file's bytes; frames, timing and looping are handled inside the SDK.

```dart
// From a bundled asset (PNG, JPEG or GIF):
await nosmai.setFaceStickerAsset(
  'assets/stickers/heart.gif',
  anchor: NosmaiFaceStickerAnchor.aboveHead,
);

// Or from bytes you already have (gallery, network, a rendered widget):
await nosmai.setFaceSticker(bytes, anchor: NosmaiFaceStickerAnchor.nose);

// Cheap to call from a gesture or slider; pass the same anchor.
await nosmai.setFaceStickerPlacement(
  anchor: NosmaiFaceStickerAnchor.nose,
  offsetY: 0.05, // a little above the tip, in face units
  scale: 0.4,    // width as a multiple of face width; 0 = anchor default
);

await nosmai.clearFaceSticker();
```

Anchors: `center`, `forehead`, `aboveHead`, `leftEye`, `rightEye`, `eyes`
(sunglasses, masks), `nose`, `mouth`, `chin`; left and right are the subject's.
The sticker shares the AR slot with `.nosmai` effects: applying one replaces
the other, and built-in beauty is cleared when a sticker is applied. While a
sticker is active, `activeEffectPath` stays null; check
`isFaceStickerActive()` or `NosmaiActiveEffects.hasFaceSticker`.

## Hair colouring

```dart
// Enable with a colour; intensity 0.0...1.0 (default 0.6)
await nosmai.setHairColor(const Color(0xFFB35933), intensity: 0.6);

// Adjust later
await nosmai.setHairColorIntensity(0.8);

// Remove
await nosmai.removeHairColoring();

final on = await nosmai.isHairColoringActive();
```

Hair colouring is a built-in beauty effect like teeth whitening or eye colour:
it combines with lipstick, blusher and the other built-ins, is cleared by
`removeAllBeautyEffects()`, and never touches the AR slot. The hair
segmentation model runs on its own native thread; the first coloured frame
appears once it has warmed up. `NosmaiActiveEffects.hasHairColoring` mirrors
`isHairColoringActive()`. An older iOS binary reports `UNSUPPORTED_SDK_VERSION`.

## Getting started

Add `nosmai_effects_sdk` to your Flutter application and follow the official
Flutter integration guide for licensing, native setup, permissions, camera
lifecycle, filters, capture, and production requirements.

- [Introduction](https://nosmai.com/docs/effects/introduction/)
- [Flutter platform guide](https://nosmai.com/docs/effects/platforms/flutter/)
- [Flutter installation](https://nosmai.com/docs/effects/installation/flutter/)
- [License key](https://nosmai.com/docs/effects/license-key/)
- [Apply a beauty filter](https://nosmai.com/docs/effects/guides/effects/apply-a-beauty-filter/flutter/)
- [Filters and effects](https://nosmai.com/docs/effects/concepts/filters-and-effects/)
- [Cloud filters](https://nosmai.com/docs/effects/concepts/cloud-filters/)
- [Flutter live streaming with Agora](https://nosmai.com/docs/effects/integrations/agora/flutter/)
- [Troubleshooting](https://nosmai.com/docs/effects/troubleshooting/)

A valid Nosmai license key is required. Create and manage projects through the
[Nosmai Console](https://console.nosmai.com/).

### Recommended camera lifecycle

Initialize Nosmai once before opening the camera route, then mount exactly one
`NosmaiCameraPreview`. The preview starts native camera processing
automatically; applications should not call `startProcessing()` during normal
screen setup.

Await `endCameraSession()` before leaving the route. The included
`NosmaiCameraLifecycleMixin` provides this safe navigation flow:

```dart
class CameraScreenState extends State<CameraScreen>
    with NosmaiCameraLifecycleMixin {
  Future<void> closeCamera() async {
    await cleanupBeforeNavigation();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return const NosmaiCameraPreview();
  }
}
```

Do not call asynchronous global cleanup from a camera widget's `dispose()`.
The native PlatformView owns final view disposal, and an old cleanup request
could otherwise stop a newly-created preview.

### Built-in adjustment ranges

- Skin smoothing, whitening, sharpening, teeth whitening, hair colour intensity,
  and makeup intensity: `0.0...1.0`
- Brightness: `-1.0...1.0` (`0.0` is neutral)
- Contrast, RGB channels, HSB saturation, and HSB brightness: `0.0...2.0`
  (`1.0` is neutral)
- Hue: `0...360` degrees
- White-balance temperature: `2000...8000`; tint: `-100...100`

## Native SDK distribution

- Version `2.0.2` uses Android Effects SDK `3.0.7` from the official GitHub
  release and resolves `NosmaiCameraSDK 3.0.7` through CocoaPods on iOS.
- The Flutter plugin resolves the Android AAR from
  [Nosmai Effects SDK for Android releases](https://github.com/nosmai/nosmai_effects_sdk_android/releases/tag/v3.0.7);
  applications do not need to keep a local AAR in `android/app/libs`.
- Native SDK binaries and licensed `.nosmai` assets are not bundled in the
  pub.dev package.

See the Flutter integration guide for the current compatible native SDK
versions and installation steps.

## Support

- [Documentation](https://nosmai.com/docs/effects/introduction/)
- [GitHub issues](https://github.com/nosmai/nosmai_effects_sdk_flutter/issues)
- [Nosmai Effects](https://effects.nosmai.com/)
- Email: admin@nosmai.com

## License

This Flutter plugin and its associated native SDKs are proprietary commercial
software. A valid agreement and license key are required. See [LICENSE](LICENSE)
for the applicable terms.

### Android preview rendering

`NosmaiCameraPreview` uses Flutter's `SurfaceProducer` and `Texture` on Android.
The existing GPU beauty/AR pipeline renders directly to the Flutter-owned
Surface at 720 x 1280 physical pixels. A processed output frame determines
readiness; camera input acceptance alone does not show the preview.

The widget releases only its own texture, hides old frames during camera
switch/resume, and rebinds output when Flutter recreates its Surface.
Native recording and streaming continue through their existing SDK sinks.

This release resolves the matching Android AAR automatically from the official
`3.0.7` GitHub release. Applications do not need to download or copy
the AAR into `android/app/libs`.
