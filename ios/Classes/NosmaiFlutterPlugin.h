#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>

@interface NosmaiFlutterPlugin : NSObject<FlutterPlugin>

// ✅ NEW: External CVPixelBuffer processing with manual flip control
// This method provides explicit control over horizontal flipping for correct mirror behavior
//
// @param pixelBuffer The CVPixelBuffer to process (modified in-place)
// @param shouldFlip YES to flip horizontally BEFORE Nosmai processing (for front camera un-mirroring)
//                   NO to keep original orientation (for back camera)
//
// Processing flow:
// 1. If shouldFlip=YES: Manually flip buffer horizontally (GPU-accelerated)
// 2. Process through Nosmai SDK with filters (always with mirror:NO)
// 3. Copy result back to original buffer
//
// Result:
// - Front camera (shouldFlip=YES): Remote users see correct orientation, local preview mirrored by Agora
// - Back camera (shouldFlip=NO): Everyone sees correct orientation
+ (BOOL)processExternalPixelBuffer:(CVPixelBufferRef)pixelBuffer shouldFlip:(BOOL)shouldFlip;

// Backward compatible method (redirects to shouldFlip version)
+ (BOOL)processExternalPixelBuffer:(CVPixelBufferRef)pixelBuffer mirror:(BOOL)mirror;

// Reset external frame mode - call this when Agora bridge disposes
// This resets the SDK from offscreen mode back to normal camera mode
+ (void)resetExternalFrameMode;

@end
