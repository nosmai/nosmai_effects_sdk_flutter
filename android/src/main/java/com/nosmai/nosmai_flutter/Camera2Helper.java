package com.nosmai.nosmai_flutter;


import android.Manifest;
import android.annotation.SuppressLint;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.util.Range;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import android.view.Surface;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.ActivityCompat;


import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

@Keep
public class Camera2Helper {
    private static final String TAG = "Camera2Helper";
    private static final long CAMERA_OPEN_CLOSE_TIMEOUT_MS = 2500;
    private static final long CAMERA_DEVICE_CLOSE_TIMEOUT_MS = 1000;
    public static final int CAMERA_FACING =
            CameraCharacteristics.LENS_FACING_FRONT;

    public enum InputMode {
        YUV,
        OES
    }

    private int mCurrentCameraFacing = CAMERA_FACING;

    private Context mContext;
    private volatile CameraDevice mCameraDevice;
    private volatile CameraCaptureSession mCaptureSession;
    private Surface mPreviewSurface; // Optional OES preview surface
    private SurfaceTexture mPreviewSurfaceTexture;
    private boolean mOwnsPreviewSurface = false;
    private ImageReader mImageReader;
    private Size mPreviewSize;
    private HandlerThread mBackgroundThread;
    private Handler mBackgroundHandler;
    private Semaphore mCameraOpenCloseLock = new Semaphore(1);
    private final Semaphore mCameraClosedLock = new Semaphore(0);
    private int mSensorOrientation;
    private int mTargetWidth = 1280;
    private int mTargetHeight = 720;
    private FrameCallback mFrameCallback;
    private PreviewSizeCallback mPreviewSizeCallback;
    private CameraErrorCallback mCameraErrorCallback;
    private CameraReadyCallback mCameraReadyCallback;
    private CameraCharacteristics mCameraCharacteristics; // 📊 Store camera characteristics
    private InputMode mInputMode = InputMode.YUV;

    private volatile boolean mIsCameraOpened = false;
    private volatile boolean mOpeningCamera = false;
    private volatile boolean mClosingCamera = false;

    // 🚀 SMART BUFFER REUSE: Simple reusable buffer for current session
    private byte[] mReuseBuffer = null;
    private int mLastBufferSize = 0;

    // public interface FrameCallback {
    //     void onFrameAvailable(byte[] rgbaData, int width, int height);
    // }
    public interface FrameCallback {
        void onFrameAvailable(ByteBuffer y, ByteBuffer u, ByteBuffer v,
                              int width, int height,
                              int yStride, int uStride, int vStride,
                              int uPixelStride, int vPixelStride);
    }

    public interface PreviewSizeCallback {
        void onPreviewSizeSelected(int width, int height);
    }

    public interface CameraErrorCallback {
        void onCameraError(String reason);
    }

    public interface CameraReadyCallback {
        void onCameraReady();
    }



    public Camera2Helper(Context context) {
        mContext = context;
    }

    public Camera2Helper(Context context, boolean isFrontCamera) {
        mContext = context;
        mCurrentCameraFacing = isFrontCamera ?
            CameraCharacteristics.LENS_FACING_FRONT :
            CameraCharacteristics.LENS_FACING_BACK;
    }


    public void setFrameCallback(FrameCallback callback) {
        mFrameCallback = callback;
    }

    public void setPreviewSizeCallback(PreviewSizeCallback callback) {
        mPreviewSizeCallback = callback;
    }

    public void setCameraErrorCallback(CameraErrorCallback callback) {
        mCameraErrorCallback = callback;
    }

    public void setCameraReadyCallback(CameraReadyCallback callback) {
        mCameraReadyCallback = callback;
    }

    public void setTargetDimensions(int width, int height) {
        if (width > 0 && height > 0) {
            mTargetWidth = width;
            mTargetHeight = height;
        }
    }

    public void setFacing(boolean isFront) {
        mCurrentCameraFacing = isFront
                ? CameraCharacteristics.LENS_FACING_FRONT
                : CameraCharacteristics.LENS_FACING_BACK;
    }

    public void setInputMode(@NonNull InputMode inputMode) {
        mInputMode = inputMode;
        if (inputMode == InputMode.OES) {
            mFrameCallback = null;
        }
    }

    public boolean startCamera() {
        if (isCameraStarting() || isCameraOpened()) {
            NosmaiLog.d(TAG, "Camera start ignored; open is already active or pending");
            return true;
        }
        startBackgroundThread();
        return openCamera();
    }

    public void stopCamera() {
        NosmaiLog.d(TAG, "Stopping camera...");
        try {
            closeCamera();
            stopBackgroundThread();
            NosmaiLog.d(TAG, "✅ Camera stopped successfully");
        } catch (Exception e) {
            NosmaiLog.e(TAG, "Error during camera stop: " + e.getMessage());
        }
    }

    public void cancelRetry() {
        // Demo helper does not keep retry runnables; retained for Flutter plugin lifecycle compatibility.
    }

    private void startBackgroundThread() {
        if (mBackgroundThread != null) {
            return;
        }
        mBackgroundThread = new HandlerThread("CameraBackground");
        mBackgroundThread.start();
        mBackgroundHandler = new Handler(mBackgroundThread.getLooper());
    }

    private void stopBackgroundThread() {
        if (mBackgroundThread != null) {
            if (mBackgroundHandler != null) {
                mBackgroundHandler.removeCallbacksAndMessages(null);
            }
            mBackgroundThread.quitSafely();
            try {
                mBackgroundThread.join();
                mBackgroundThread = null;
                mBackgroundHandler = null;
            } catch (InterruptedException e) {
                NosmaiLog.e(TAG, "Interrupted when stopping background thread", e);
            }
        }
    }

    @SuppressLint("MissingPermission")
    private boolean openCamera() {
        if (ActivityCompat.checkSelfPermission(mContext, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            NosmaiLog.e(TAG, "No camera permission");
            return false;
        }

        CameraManager manager = (CameraManager) mContext.getSystemService(Context.CAMERA_SERVICE);
        boolean lockAcquired = false;
        try {
            String cameraId = getCameraId(manager);
            if (cameraId == null) {
                NosmaiLog.e(TAG, "Failed to find appropriate camera");
                return false;
            }

            // Get camera characteristics
            mCameraCharacteristics = manager.getCameraCharacteristics(cameraId);
            StreamConfigurationMap map =
                    mCameraCharacteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            if (map == null) {
                NosmaiLog.e(TAG, "Cannot get available preview sizes");
                return false;
            }

            // Get sensor orientation
            mSensorOrientation = mCameraCharacteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);

            Size[] outputSizes = mInputMode == InputMode.OES
                    ? map.getOutputSizes(SurfaceTexture.class)
                    : map.getOutputSizes(ImageFormat.YUV_420_888);
            if (outputSizes == null || outputSizes.length == 0) {
                outputSizes = map.getOutputSizes(SurfaceTexture.class);
            }
            if (outputSizes == null || outputSizes.length == 0) {
                NosmaiLog.e(TAG, "No supported camera output sizes available");
                return false;
            }

            // Cap the preview to 720p. The back camera exposes 1080p and the front
            // usually ~720p; running the back at 1080p pushes ~2x the pixels through
            // the per-pixel GPU/OES pipeline (~8-10 full-res passes) → the back-camera
            // fps drop. Capping to 1280x720 matches both cameras (~0.9M px) and lifts
            // back-camera fps with no visible quality loss on a phone preview.
            mPreviewSize = chooseOptimalSize(outputSizes, mTargetWidth, mTargetHeight);
            NosmaiLog.i(TAG, "📐 Selected preview size: " + mPreviewSize.getWidth()
                    + "x" + mPreviewSize.getHeight()
                    + ", sensorOrientation=" + mSensorOrientation
                    + ", inputMode=" + mInputMode);

            if (mInputMode == InputMode.OES) {
                if (!ensureOesPreviewSurface()) {
                    NosmaiLog.e(TAG, "OES input selected but SurfaceTexture is not ready");
                    return false;
                }
                if (mPreviewSizeCallback != null) {
                    mPreviewSizeCallback.onPreviewSizeSelected(
                            mPreviewSize.getWidth(), mPreviewSize.getHeight());
                }
            } else {
                // PERFORMANCE FIX: Increase buffers for smoother pipeline
                mImageReader = ImageReader.newInstance(
                        mPreviewSize.getWidth(), mPreviewSize.getHeight(), ImageFormat.YUV_420_888, 3);
                mImageReader.setOnImageAvailableListener(mOnImageAvailableListener, mBackgroundHandler);
            }


            // Open camera
            if (!mCameraOpenCloseLock.tryAcquire(CAMERA_OPEN_CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                throw new RuntimeException("Time out waiting to lock camera opening.");
            }
            lockAcquired = true;
            mClosingCamera = false;
            mOpeningCamera = true;

            manager.openCamera(cameraId, mStateCallback, mBackgroundHandler);
            return true;
        } catch (CameraAccessException e) {
            NosmaiLog.e(TAG, "Failed to access camera", e);
        } catch (InterruptedException e) {
            NosmaiLog.e(TAG, "Interrupted while trying to lock camera opening", e);
            Thread.currentThread().interrupt();
        } catch (RuntimeException e) {
            NosmaiLog.e(TAG, "Failed to open camera", e);
        }

        if (lockAcquired) {
            mOpeningCamera = false;
            mCameraOpenCloseLock.release();
        }
        return false;
    }

    private String getCameraId(CameraManager manager) {
        try {
            for (String cameraId : manager.getCameraIdList()) {
                CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraId);
                Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING);
                if (facing != null && facing == mCurrentCameraFacing) {
                    return cameraId;
                }
            }
            // If front camera not found, try to use any available camera
            if (manager.getCameraIdList().length > 0) {
                return manager.getCameraIdList()[0];
            }
        } catch (CameraAccessException e) {
//            NosmaiLog.e(TAG, "Failed to get camera ID", e);
        }
        return null;
    }

    private Size chooseOptimalSize(Size[] choices, int width, int height) {
        List<Size> bigEnough = Arrays.asList(choices);

        // Sort by area
        Collections.sort(bigEnough, new Comparator<Size>() {
            @Override
            public int compare(Size lhs, Size rhs) {
                // Sort in descending order
                return Long.signum((long) rhs.getWidth() * rhs.getHeight()
                        - (long) lhs.getWidth() * lhs.getHeight());
            }
        });

        // Choose one that doesn't exceed target resolution and is large enough
        for (Size option : bigEnough) {
            if (option.getWidth() <= width && option.getHeight() <= height) {
                return option;
            }
        }

        // If no suitable size found, choose the smallest one
        return bigEnough.get(bigEnough.size() - 1);
    }


    private final CameraDevice.StateCallback mStateCallback = new CameraDevice.StateCallback() {
        @Override
        public void onOpened(@NonNull CameraDevice cameraDevice) {
            releaseOpeningLockIfNeeded();
            if (mClosingCamera) {
                NosmaiLog.w(TAG, "Camera opened after close was requested; closing immediately");
                mCameraClosedLock.drainPermits();
                cameraDevice.close();
                mIsCameraOpened = false;
                return;
            }
            mCameraDevice = cameraDevice;
            createCaptureSession();
        }

        @Override
        public void onDisconnected(@NonNull CameraDevice cameraDevice) {
            NosmaiLog.w(TAG, "Camera device disconnected - cleaning up resources");
            releaseOpeningLockIfNeeded();
            cameraDevice.close();
            mCameraDevice = null;
            closeCaptureSessionQuietly();
            mIsCameraOpened = false;
            notifyCameraError("Camera device disconnected");
        }

        @Override
        public void onError(@NonNull CameraDevice cameraDevice, int error) {
            NosmaiLog.e(TAG, "Camera device error: " + error + " - cleaning up resources");
            releaseOpeningLockIfNeeded();
            cameraDevice.close();
            mCameraDevice = null;
            closeCaptureSessionQuietly();
            mIsCameraOpened = false;
            notifyCameraError("Camera device error: " + error);
        }

        @Override
        public void onClosed(@NonNull CameraDevice cameraDevice) {
            mClosingCamera = false;
            mCameraClosedLock.release();
        }
    };

    private void releaseOpeningLockIfNeeded() {
        if (mOpeningCamera) {
            mOpeningCamera = false;
            mCameraOpenCloseLock.release();
        }
    }

    private void createCaptureSession() {
        try {
            if (mCameraDevice == null) return;

            // Build exactly the target set for the selected input mode.
            java.util.ArrayList<Surface> targets = new java.util.ArrayList<>();
            mPreviewRequestBuilder = mCameraDevice.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);

            if (mInputMode == InputMode.OES) {
                if (!ensureOesPreviewSurface()) {
                    NosmaiLog.e(TAG, "Cannot create OES capture session without preview surface");
                    return;
                }
                targets.add(mPreviewSurface);
                mPreviewRequestBuilder.addTarget(mPreviewSurface);
            } else {
                if (mImageReader == null) return;
                Surface yuvSurface = mImageReader.getSurface();
                targets.add(yuvSurface);
                mPreviewRequestBuilder.addTarget(yuvSurface);
            }

            mCameraDevice.createCaptureSession(
                    targets, new CameraCaptureSession.StateCallback() {
                        @Override
                        public void onConfigured(
                                @NonNull CameraCaptureSession cameraCaptureSession) {
                            if (mCameraDevice == null || mClosingCamera) {
                                cameraCaptureSession.close();
                                return;
                            }

                            closeCaptureSessionQuietly();
                            mCaptureSession = cameraCaptureSession;
                            try {
                                // 🚀 SMART FPS: Get best supported FPS range for optimal performance
                                Range<Integer> fpsRange = getBestFpsRange();
                                NosmaiLog.i(TAG, "📊 Using FPS range: " + fpsRange);
                                mPreviewRequestBuilder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange);

                                // Set auto-exposure and auto-focus for stability
                                mPreviewRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
                                int activeFlashMode = mTorchMode == CaptureRequest.FLASH_MODE_TORCH
                                        ? CaptureRequest.FLASH_MODE_TORCH
                                        : (mFlashEnabled && !isFrontCamera()
                                                ? CaptureRequest.FLASH_MODE_TORCH
                                                : mFlashMode);
                                mPreviewRequestBuilder.set(CaptureRequest.FLASH_MODE, activeFlashMode);
                                mPreviewRequestBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);

                                CaptureRequest request = mPreviewRequestBuilder.build();
                                mCaptureSession.setRepeatingRequest(
                                        request, null, mBackgroundHandler);
                                mIsCameraOpened = true;
                                notifyCameraReady();
                            } catch (CameraAccessException | IllegalStateException e) {
                                NosmaiLog.e(TAG, "Failed to set up capture request", e);
                                closeCameraAfterFailure(cameraCaptureSession);
                                notifyCameraError("Failed to start camera preview");
                            }
                        }

                        @Override
                        public void onConfigureFailed(
                                @NonNull CameraCaptureSession cameraCaptureSession) {
                            NosmaiLog.e(TAG, "Failed to configure capture session");
                            closeCameraAfterFailure(cameraCaptureSession);
                            notifyCameraError("Failed to configure capture session");
                        }
                    }, mBackgroundHandler);
        } catch (CameraAccessException e) {
            NosmaiLog.e(TAG, "Failed to create capture session", e);
            closeCameraAfterFailure(null);
            notifyCameraError("Failed to create capture session");
        }
    }

    private void closeCamera() {
        boolean lockAcquired = false;
        boolean waitForDeviceClosed = false;
        mClosingCamera = true;
        try {
            if (!mCameraOpenCloseLock.tryAcquire(CAMERA_OPEN_CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                NosmaiLog.w(TAG, "Timed out waiting to lock camera closing; skipping blocking close");
                if (mImageReader != null) {
                    mImageReader.close();
                    mImageReader = null;
                }
                releaseOwnedPreviewSurface();
                mIsCameraOpened = false;
                mReuseBuffer = null;
                mLastBufferSize = 0;
                return;
            }
            lockAcquired = true;

            if (mCaptureSession != null) {
                try {
                    mCaptureSession.stopRepeating();
                    mCaptureSession.abortCaptures();
                } catch (CameraAccessException | IllegalStateException e) {
                    NosmaiLog.d(TAG, "Capture session already stopping: " + e.getMessage());
                }
                mCaptureSession.close();
                mCaptureSession = null;
            }

            if (mCameraDevice != null) {
                mCameraClosedLock.drainPermits();
                mCameraDevice.close();
                mCameraDevice = null;
                waitForDeviceClosed = true;
            }

            if (mImageReader != null) {
                mImageReader.close();
                mImageReader = null;
            }
            releaseOwnedPreviewSurface();

            mIsCameraOpened = false;

            // 🚀 CLEANUP: Clear reuse buffer
            mReuseBuffer = null;
            mLastBufferSize = 0;

        } catch (InterruptedException e) {
            NosmaiLog.e(TAG, "Interrupted while trying to lock camera closing", e);
            Thread.currentThread().interrupt();
        } finally {
            if (lockAcquired) {
                mCameraOpenCloseLock.release();
            }
        }

        if (waitForDeviceClosed) {
            try {
                if (!mCameraClosedLock.tryAcquire(CAMERA_DEVICE_CLOSE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                    NosmaiLog.w(TAG, "Timed out waiting for camera close callback");
                }
            } catch (InterruptedException e) {
                NosmaiLog.e(TAG, "Interrupted while waiting for camera close callback", e);
                Thread.currentThread().interrupt();
            }
        }
        mClosingCamera = false;
    }

    /**
     * Optionally set a GL OES preview Surface (from SurfaceTexture). Call before startCamera().
     */
    public void setPreviewSurface(@Nullable android.view.Surface surface) {
        releaseOwnedPreviewSurface();
        this.mPreviewSurface = surface;
        this.mOwnsPreviewSurface = false;
        this.mPreviewSurfaceTexture = null;
    }

    public void setOesPreviewSurfaceTexture(@Nullable SurfaceTexture surfaceTexture) {
        if (mPreviewSurfaceTexture == surfaceTexture && mPreviewSurface != null) {
            return;
        }
        releaseOwnedPreviewSurface();
        mPreviewSurfaceTexture = surfaceTexture;
        if (surfaceTexture != null) {
            mPreviewSurface = new Surface(surfaceTexture);
            mOwnsPreviewSurface = true;
            if (mPreviewSize != null) {
                surfaceTexture.setDefaultBufferSize(
                        mPreviewSize.getWidth(), mPreviewSize.getHeight());
            }
        }
    }

    /**
     * Reconfigure capture session with a new preview surface (safe to call at runtime).
     */
    public void reconfigurePreviewSurface(@Nullable android.view.Surface surface) {
        releaseOwnedPreviewSurface();
        this.mPreviewSurface = surface;
        this.mOwnsPreviewSurface = false;
        this.mPreviewSurfaceTexture = null;
        if (isCameraOpened()) {
            // Rebuild the capture session with the updated targets
            createCaptureSession();
        }
    }

    public void reconfigurePreviewSurfaceTexture(@Nullable SurfaceTexture surfaceTexture) {
        setOesPreviewSurfaceTexture(surfaceTexture);
        if (isCameraOpened()) {
            createCaptureSession();
        }
    }

    private boolean ensureOesPreviewSurface() {
        if (mPreviewSurface == null && mPreviewSurfaceTexture != null) {
            mPreviewSurface = new Surface(mPreviewSurfaceTexture);
            mOwnsPreviewSurface = true;
        }
        if (mPreviewSurfaceTexture != null && mPreviewSize != null) {
            mPreviewSurfaceTexture.setDefaultBufferSize(
                    mPreviewSize.getWidth(), mPreviewSize.getHeight());
        }
        return mPreviewSurface != null;
    }

    private void releaseOwnedPreviewSurface() {
        if (mOwnsPreviewSurface && mPreviewSurface != null) {
            mPreviewSurface.release();
        }
        mPreviewSurface = null;
        mOwnsPreviewSurface = false;
    }

    private void notifyCameraError(String reason) {
        if (mCameraErrorCallback != null) {
            mCameraErrorCallback.onCameraError(reason);
        }
    }

    private void notifyCameraReady() {
        if (mCameraReadyCallback != null) {
            mCameraReadyCallback.onCameraReady();
        }
    }

    private void closeCaptureSessionQuietly() {
        if (mCaptureSession == null) {
            return;
        }
        try {
            mCaptureSession.close();
        } catch (Throwable t) {
            NosmaiLog.d(TAG, "Capture session already closed: " + t.getMessage());
        } finally {
            mCaptureSession = null;
        }
    }

    private void closeCameraAfterFailure(
            @Nullable CameraCaptureSession failedSession) {
        if (failedSession != null && failedSession != mCaptureSession) {
            try {
                failedSession.close();
            } catch (Throwable ignore) {
            }
        }
        closeCaptureSessionQuietly();
        CameraDevice cameraDevice = mCameraDevice;
        mCameraDevice = null;
        if (cameraDevice != null) {
            try {
                cameraDevice.close();
            } catch (Throwable ignore) {
            }
        }
        mIsCameraOpened = false;
    }

    private final ImageReader.OnImageAvailableListener mOnImageAvailableListener =
        new ImageReader.OnImageAvailableListener() {
            @Override
            public void onImageAvailable(ImageReader reader) {
                Image image = null;
                try {
                    image = reader.acquireLatestImage();
                    if (image == null) {
                        return;
                    }

                    // A callback must be registered
                    if (mFrameCallback == null) {
                        image.close();
                        return;
                    }

                    final Image.Plane[] planes = image.getPlanes();

                    mFrameCallback.onFrameAvailable(
                        planes[0].getBuffer(),
                        planes[1].getBuffer(),
                        planes[2].getBuffer(),
                        image.getWidth(), image.getHeight(),
                        planes[0].getRowStride(),
                        planes[1].getRowStride(),
                        planes[2].getRowStride(),
                        planes[1].getPixelStride(), // Pass U pixel stride
                        planes[2].getPixelStride()  // Pass V pixel stride
                    );

                } catch (final Exception e) {
                    NosmaiLog.e(TAG, "onImageAvailable: ", e);
                } finally {
                    if (image != null) {
                        image.close();
                    }
                }
            }

        };


    public boolean isCameraOpened() {
        return mIsCameraOpened && mCameraDevice != null && mCaptureSession != null;
    }

    /**
     * Check if camera is in a valid state - do NOT auto restart to avoid loops
     */
    public boolean isValidState() {
        return isCameraOpened();
    }

    public boolean isCameraStarting() {
        return mOpeningCamera
                || (!mClosingCamera && mCameraDevice != null && mCaptureSession == null);
    }

    public Size getPreviewSize() {
        return mPreviewSize;
    }

    public int getPreviewWidth() {
        return mPreviewSize != null ? mPreviewSize.getWidth() : 0;
    }

    public int getPreviewHeight() {
        return mPreviewSize != null ? mPreviewSize.getHeight() : 0;
    }

    public int getSensorOrientation() {
        return mSensorOrientation;
    }

    public boolean isFrontCamera() {
        return mCurrentCameraFacing == CameraCharacteristics.LENS_FACING_FRONT;
    }

    // 🔧 DISABLED: Rotation buffer method disabled
    // public byte[] getRotationBuffer() { return null; }

    // Camera controls
    private boolean mFlashEnabled = false;
    private int mFlashMode = CaptureRequest.FLASH_MODE_OFF;
    private int mTorchMode = CaptureRequest.FLASH_MODE_OFF;
    private CaptureRequest.Builder mPreviewRequestBuilder;

    public void setFlashMode(int mode) {
        mFlashMode = mode;
        updateFlashMode();
    }

    public int getFlashMode() {
        return mFlashMode;
    }

    public void setTorchMode(int mode) {
        mTorchMode = mode;
        updateFlashMode();
    }

    public int getTorchMode() {
        return mTorchMode;
    }

    /**
     * Set flash enabled/disabled (only works for back camera)
     */
    public void setFlashEnabled(boolean enabled) {
        mFlashEnabled = enabled;
        updateFlashMode();
    }

    /**
     * Update flash mode in capture request
     */
    private void updateFlashMode() {
        if (mPreviewRequestBuilder != null && mCaptureSession != null) {
            try {
                int activeFlashMode = mTorchMode == CaptureRequest.FLASH_MODE_TORCH
                        ? CaptureRequest.FLASH_MODE_TORCH
                        : (mFlashEnabled && !isFrontCamera()
                                ? CaptureRequest.FLASH_MODE_TORCH
                                : mFlashMode);
                mPreviewRequestBuilder.set(CaptureRequest.FLASH_MODE, activeFlashMode);
                mPreviewRequestBuilder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON);
                mCaptureSession.setRepeatingRequest(mPreviewRequestBuilder.build(), null, mBackgroundHandler);
            } catch (CameraAccessException | IllegalStateException e) {
                NosmaiLog.e(TAG, "Failed to update flash mode", e);
            }
        }
    }

    /**
     * Switch camera (basic implementation - requires restart)
     * Note: This is a simple implementation that just changes the static CAMERA_FACING
     */
    public void switchCamera() {
        // For a full implementation, we would need to restructure the class
        // For now, we'll just log that camera switching was requested
        NosmaiLog.w(TAG, "Camera switching requested but requires app restart for full implementation");
    }

    /**
     * 📊 SMART FPS SELECTION: Get the best FPS range supported by device
     * Priority: 30 FPS > 25 FPS > highest available
     */
    private Range<Integer> getBestFpsRange() {
        if (mCameraCharacteristics == null) {
            NosmaiLog.w(TAG, "⚠️ Camera characteristics not available, using default 15-30 FPS");
            return new Range<>(15, 30);
        }

        try {
            // Get all supported FPS ranges
            Range<Integer>[] fpsRanges = mCameraCharacteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
            if (fpsRanges == null || fpsRanges.length == 0) {
                NosmaiLog.w(TAG, "⚠️ No FPS ranges available, using default");
                return new Range<>(15, 30);
            }

            // Log all available FPS ranges for debugging
            NosmaiLog.i(TAG, "📊 Available FPS ranges:");
            for (Range<Integer> range : fpsRanges) {
                NosmaiLog.i(TAG, "   - " + range.getLower() + " to " + range.getUpper() + " FPS");
            }

            // Priority 1: Try to find 30 FPS fixed
            for (Range<Integer> range : fpsRanges) {
                if (range.getLower() >= 30 && range.getUpper() >= 30) {
                    NosmaiLog.i(TAG, "✅ Selected: 30 FPS fixed range");
                    return new Range<>(30, 30);
                }
            }

            // Priority 2: Try to find range that includes 30 FPS
            for (Range<Integer> range : fpsRanges) {
                if (range.getLower() <= 30 && range.getUpper() >= 30) {
                    NosmaiLog.i(TAG, "✅ Selected: Variable range with 30 FPS max");
                    return range;
                }
            }

            // Priority 3: Find highest available FPS
            Range<Integer> bestRange = fpsRanges[0];
            for (Range<Integer> range : fpsRanges) {
                if (range.getUpper() > bestRange.getUpper()) {
                    bestRange = range;
                }
            }

            NosmaiLog.i(TAG, "✅ Selected: Best available range " + bestRange);
            return bestRange;

        } catch (Exception e) {
            NosmaiLog.e(TAG, "❌ Error getting FPS ranges: " + e.getMessage());
            return new Range<>(15, 30);
        }
    }
}
