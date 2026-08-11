#import "NosmaiCameraPreviewView.h"
#import "NosmaiFlutterPlugin.h"
#import <nosmai/Nosmai.h>
#import <nosmai/NosmaiSDK.h>

#if DEBUG
#define NOSMAI_PLUGIN_LOG(...) NSLog(__VA_ARGS__)
#else
#define NOSMAI_PLUGIN_LOG(...) do { } while (0)
#endif

// Custom UIView subclass that handles layout updates
@interface NosmaiNativePreviewView : UIView
@end

@implementation NosmaiNativePreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Ensure the view can handle device rotations and size changes
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // Set up notifications for orientation changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationDidChange:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // Ensure we're on the main thread for UI updates
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self layoutSubviews];
        });
        return;
    }

    // Force the camera preview to fill the entire view bounds
    // This ensures proper scaling on all device sizes
    NosmaiCore* core = [NosmaiCore shared];
    if (core && core.isInitialized && core.camera) {
        // Update all sublayers to fill the bounds
        for (CALayer* layer in self.layer.sublayers) {
            // Only update if frame changed to avoid thrashing
            if (!CGRectEqualToRect(layer.frame, self.bounds)) {
                layer.frame = self.bounds;
                layer.contentsGravity = kCAGravityResizeAspectFill;
                layer.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
                layer.masksToBounds = YES;
                [layer setNeedsDisplay];
            }
        }

        // Force resize of all NosmaiView subviews
        for (UIView* subview in self.subviews) {
            if ([subview isKindOfClass:NSClassFromString(@"NosmaiView")]) {
                subview.frame = self.bounds;
                subview.layer.contentsGravity = kCAGravityResizeAspectFill;
                subview.layer.masksToBounds = YES;
                subview.contentMode = UIViewContentModeScaleAspectFill;

                // Force all sublayers to also scale to fill
                for (CALayer* layer in subview.layer.sublayers) {
                    layer.frame = subview.bounds;
                    layer.contentsGravity = kCAGravityResizeAspectFill;
                    layer.masksToBounds = YES;
                    [layer setNeedsDisplay];
                }

                [subview setNeedsLayout];
                [subview layoutIfNeeded];

            }
        }
    }

}

- (void)orientationDidChange:(NSNotification*)notification {
    // Force layout update when device orientation changes
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end

@interface NosmaiCameraPreviewView()
@property(nonatomic, strong) NosmaiNativePreviewView* nativeView;
@property(nonatomic, assign) BOOL isSetupInProgress;
@property(nonatomic, strong) dispatch_queue_t setupQueue;
@property(nonatomic, assign) BOOL isAttached;
@property(nonatomic, assign) BOOL wasDetachedGracefully;
@property(nonatomic, strong) dispatch_semaphore_t setupSemaphore;
@property(nonatomic, assign) NSInteger setupRetryCount;
@property(nonatomic, strong) UIView* coverView;
@end

static __weak NosmaiCameraPreviewView* sActivePreviewView = nil;

@implementation NosmaiCameraPreviewView

+ (BOOL)reattachActivePreviewIfReady {
    NosmaiCameraPreviewView* activeView = sActivePreviewView;
    if (!activeView) {
        return NO;
    }

    [activeView setupCameraPreviewWithStateCheck];
    return YES;
}

+ (BOOL)detachActivePreview {
    NosmaiCameraPreviewView* activeView = sActivePreviewView;
    if (!activeView) {
        return NO;
    }

    [activeView detachCameraGracefully];
    return YES;
}

- (instancetype)initWithFrame:(CGRect)frame
               viewIdentifier:(int64_t)viewId
                    arguments:(id _Nullable)args
              binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    if (self = [super init]) {
        // Initialize thread-safe setup queue
        _setupQueue = dispatch_queue_create("com.nosmai.preview.setup", DISPATCH_QUEUE_SERIAL);
        _isSetupInProgress = NO;
        _isAttached = NO;
        _wasDetachedGracefully = NO;
        _setupSemaphore = dispatch_semaphore_create(1);
        _setupRetryCount = 0;

        _nativeView = [[NosmaiNativePreviewView alloc] initWithFrame:frame];
        _nativeView.backgroundColor = [UIColor blackColor];
        _nativeView.layer.masksToBounds = YES;
        _nativeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // Use ScaleAspectFill to ensure full coverage without letterboxing
        _nativeView.contentMode = UIViewContentModeScaleAspectFill;

        // Set content scaling mode for full-screen display (no letterboxing)
        _nativeView.layer.contentsGravity = kCAGravityResizeAspectFill;

        // Ensure the view is properly configured for OpenGL rendering
        _nativeView.opaque = YES;
        _nativeView.clearsContextBeforeDrawing = NO;

        // Set up proper layer configuration for high-performance rendering
        _nativeView.layer.opaque = YES;
        _nativeView.layer.drawsAsynchronously = NO; // Disable async drawing to reduce thread issues

        // Ensure the view extends to all edges (including safe areas)
        _nativeView.clipsToBounds = YES;
        _nativeView.insetsLayoutMarginsFromSafeArea = NO;

        // Create cover view to hide initial flash
        _coverView = [[UIView alloc] initWithFrame:_nativeView.bounds];
        _coverView.backgroundColor = [UIColor blackColor];
        _coverView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _coverView.userInteractionEnabled = NO; // Let touches pass through if needed, though usually not for preview
        [_nativeView addSubview:_coverView];

        sActivePreviewView = self;

        // SDK initialization can complete after the Flutter PlatformView is created.
        [self setupCameraPreviewWithStateCheck];

    }
    return self;
}

- (void)setupCameraPreviewWithStateCheck {
    if (sActivePreviewView != self) {
        return;
    }

    dispatch_async(_setupQueue, ^{
        if (sActivePreviewView != self) {
            return;
        }

        // Use semaphore to ensure only one setup operation at a time
        dispatch_semaphore_wait(self.setupSemaphore, DISPATCH_TIME_FOREVER);

        if (self.isSetupInProgress) {
            dispatch_semaphore_signal(self.setupSemaphore);
            return;
        }

        self.isSetupInProgress = YES;
        dispatch_semaphore_signal(self.setupSemaphore);

        [self waitForSDKReadyThenSetup];
    });
}

- (void)waitForSDKReadyThenSetup {
    if (sActivePreviewView != self) {
        return;
    }

    NosmaiCore* core = [NosmaiCore shared];

    if (core && core.isInitialized && core.camera) {
        [self performCameraAttachment];
    } else {
        self.setupRetryCount++;
        if (self.setupRetryCount > 50) {
            dispatch_semaphore_wait(self.setupSemaphore, DISPATCH_TIME_FOREVER);
            self.isSetupInProgress = NO;
            self.setupRetryCount = 0;
            dispatch_semaphore_signal(self.setupSemaphore);
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self waitForSDKReadyThenSetup];
        });
    }
}

- (void)performCameraAttachment {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sActivePreviewView != self) {
            return;
        }

        NosmaiCore* core = [NosmaiCore shared];

        // Non-blocking check for setup semaphore
        if (dispatch_semaphore_wait(self.setupSemaphore, DISPATCH_TIME_NOW) != 0) {
            // Semaphore is locked, retry later
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self performCameraAttachment];
            });
            return;
        }

        if (!core || !core.isInitialized) {
            self.isSetupInProgress = NO;
            dispatch_semaphore_signal(self.setupSemaphore);
            return;
        }

        // Don't setup during recording to prevent black screen
        if (core.isRecording) {
            self.isSetupInProgress = NO;
            dispatch_semaphore_signal(self.setupSemaphore);
            return;
        }


        // Detach from previous view if needed
        if (self.isAttached && !self.wasDetachedGracefully) {
            NOSMAI_PLUGIN_LOG(@"[NosmaiCameraPreview] forced detach before reattach (view=%p)", self->_nativeView);
            [core.camera detachFromView];
            self.isAttached = NO;
        }

        // Release semaphore before calling attach, as attach might need to wait on other things
        // or we can keep it locked if attach is fast.
        // In this case, attachCameraToView calls completeAttachment which grabs semaphore at the end.
        // So we should RELEASE it here to avoid deadlock if completeAttachment needs it?
        // Wait, completeAttachment waits for semaphore at the end to clear flags.
        // So we MUST release it here?
        // No, completeAttachment is called synchronously below.
        // Let's look at completeAttachment. It waits for semaphore at line 342.
        // If we hold it here, we DEADLOCK.
        // So we must release it before calling attachCameraToView.

        dispatch_semaphore_signal(self.setupSemaphore);

        // Attach immediately without delay
        [self attachCameraToView];
    });
}

- (void)attachCameraToView {
    // Ensure camera attachment happens on main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachCameraToView];
        });
        return;
    }

    // Reset graceful detach flag
    self.wasDetachedGracefully = NO;

    // Always proceed with attachment - NosmaiSDK handles processing state internally
    [self completeAttachment];
}

- (void)completeAttachment {
    if (sActivePreviewView != self) {
        return;
    }

    NosmaiCore* core = [NosmaiCore shared];

#ifdef DEBUG
    NOSMAI_PLUGIN_LOG(@"[NosmaiCameraPreview] completeAttachment (view=%p, attached=%d)", self->_nativeView, self.isAttached);
#endif
    // Essential dual attachment (the actual fix)
    [core.camera attachToView:self->_nativeView];
    [[NosmaiSDK sharedInstance] setPreviewView:self->_nativeView];
    self.isAttached = YES;

    // Configure the native view for full-screen display
    self->_nativeView.layer.contentsGravity = kCAGravityResizeAspectFill;
    self->_nativeView.layer.masksToBounds = YES;

    // 🔧 FIX: Clear layer contents before forcing layout
    // This prevents old content from flashing when layoutIfNeeded triggers layoutSubviews
    self->_nativeView.layer.contents = nil;

    // Single layout update - let the system handle proper sizing
    [self->_nativeView setNeedsLayout];
    [self->_nativeView layoutIfNeeded];

    // Essential fillMode configuration (the key fix)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self configureNosmaiViewFillMode];

        // Ensure cover view is on top
        [self->_nativeView bringSubviewToFront:self.coverView];
        self.coverView.hidden = NO;
        self.coverView.alpha = 1.0;

        // Fade out cover view after a short delay to allow first frame to render
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                self.coverView.alpha = 0.0;
            } completion:^(BOOL finished) {
                self.coverView.hidden = YES;
            }];
        });
    });


    // Reset setup state
    dispatch_semaphore_wait(self.setupSemaphore, DISPATCH_TIME_FOREVER);
    self.isSetupInProgress = NO;
    self.setupRetryCount = 0;
    dispatch_semaphore_signal(self.setupSemaphore);

}

- (void)setupCameraPreviewSafely {
    // Redirect to new state-based method
    [self setupCameraPreviewWithStateCheck];
}

- (void)setupCameraPreview {
    // Deprecated method - redirect to safe version
    [self setupCameraPreviewSafely];
}

- (UIView*)view {
    return _nativeView;
}

- (void)updateViewBounds:(CGRect)bounds {
    // Update the native view bounds for dynamic resizing on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_nativeView.frame = bounds;

        // Force full layout update for new bounds
        [self->_nativeView setNeedsLayout];
        [self->_nativeView layoutIfNeeded];

        // Update layer properties for new frame
        self->_nativeView.layer.contentsGravity = kCAGravityResizeAspectFill;
        self->_nativeView.layer.masksToBounds = YES;


        // Force resize of all NosmaiView subviews
        [self forceNosmaiViewResize];

        // Additional delayed update for complex layout changes
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_nativeView setNeedsLayout];
            [self->_nativeView layoutIfNeeded];
            [self forceNosmaiViewResize];
        });
    });
}

- (void)forceNosmaiViewResize {
    // Force resize of all NosmaiView instances to fill the entire bounds
    for (UIView* subview in self->_nativeView.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"NosmaiView")]) {
            subview.frame = self->_nativeView.bounds;
            subview.layer.contentsGravity = kCAGravityResizeAspectFill;
            subview.layer.masksToBounds = YES;
            subview.contentMode = UIViewContentModeScaleAspectFill;

            // Force all sublayers to also scale to fill
            for (CALayer* layer in subview.layer.sublayers) {
                layer.frame = subview.bounds;
                layer.contentsGravity = kCAGravityResizeAspectFill;
                layer.masksToBounds = YES;
                [layer setNeedsDisplay];
            }

            [subview setNeedsLayout];
            [subview layoutIfNeeded];
        }
    }
}

- (void)configureNosmaiViewFillMode {
    // Essential fillMode fix from working iOS app
    for (UIView *subview in self->_nativeView.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"NosmaiView")]) {
            subview.frame = self->_nativeView.bounds;
            if ([subview respondsToSelector:@selector(setFillMode:)]) {
                [subview setValue:@(2) forKey:@"fillMode"]; // Aspect fill
            }
            break;
        }
    }
}

- (void)detachCameraGracefully {

    // Use timeout to avoid blocking main thread forever
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(self.setupSemaphore, timeout) != 0) {
        NOSMAI_PLUGIN_LOG(@"[NosmaiCameraPreview] Timeout waiting for semaphore in detach");
        // Proceed anyway if we are deallocating or force detaching,
        // but strictly speaking we should be careful.
        // For now, just log and skip to avoid ANR.
        return;
    }

    NosmaiCore* core = [NosmaiCore shared];
    if (core && core.isInitialized && self.isAttached) {
        NOSMAI_PLUGIN_LOG(@"[NosmaiCameraPreview] detachCameraGracefully (view=%p)", self->_nativeView);
        [core.camera detachFromView];
        self.isAttached = NO;
        self.wasDetachedGracefully = YES;
    }

    dispatch_semaphore_signal(self.setupSemaphore);
}

- (void)dealloc {
    BOOL ownsActivePreview = sActivePreviewView == self;
    if (ownsActivePreview) {
        sActivePreviewView = nil;
    }

    // A stale view must never detach the global camera from a newer preview.
    if (ownsActivePreview && self.isAttached) {
        [self detachCameraGracefully];
    }

    // Clean up dispatch queue and semaphore
    if (_setupQueue) {
        _setupQueue = nil;
    }
    if (_setupSemaphore) {
        _setupSemaphore = nil;
    }
}

@end

@implementation NosmaiCameraPreviewViewFactory {
    NSObject<FlutterBinaryMessenger>* _messenger;
}

- (instancetype)initWithMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    self = [super init];
    if (self) {
        _messenger = messenger;
    }
    return self;
}

- (NSObject<FlutterPlatformView>*)createWithFrame:(CGRect)frame
                                   viewIdentifier:(int64_t)viewId
                                        arguments:(id _Nullable)args {

    return [[NosmaiCameraPreviewView alloc] initWithFrame:frame
                                           viewIdentifier:viewId
                                                arguments:args
                                          binaryMessenger:_messenger];
}

- (NSObject<FlutterMessageCodec>*)createArgsCodec {
    return [FlutterStandardMessageCodec sharedInstance];
}

@end
