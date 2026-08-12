package com.nosmai.nosmai_flutter

import androidx.annotation.Keep
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.util.Base64
import android.graphics.Color
import android.view.Surface
import android.view.ViewGroup
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import android.content.ContentValues
import android.provider.MediaStore
import android.os.Build
import android.os.Environment
import java.io.IOException
import android.media.MediaRecorder
import android.media.MediaMuxer
import android.media.MediaFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaScannerConnection
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraCharacteristics
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

import com.nosmai.effect.api.NosmaiSDK
import com.nosmai.effect.api.NosmaiBeauty
import com.nosmai.effect.NosmaiEffects
import com.nosmai.effect.NosmaiBackgroundSegmentationConfig
import com.nosmai.effect.NosmaiEffectsEngine
import com.nosmai.effect.api.NosmaiPreviewView
import com.nosmai.effect.api.NosmaiCloud
import com.nosmai.effect.api.NosmaiCloudFilterVersion
import com.nosmai.effect.NosmaiFilterInfo
import com.nosmai.effect.NosmaiPipelineState
import com.nosmai.effect.internal.NosmaiFilter

@Keep
class NosmaiFlutterPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingLicenseKey: String? = null
    private var isSdkInitialized = false

    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var pendingSurfaceWidth: Int? = null
    private var pendingSurfaceHeight: Int? = null
    private var isSurfaceReady: Boolean = false
    private var pendingStartProcessing: Boolean = false

    private var previewView: NosmaiPreviewView? = null
    private var platformContainer: android.widget.FrameLayout? = null
    private var switchOverlayView: android.view.View? = null
    private var camera2Helper: Camera2Helper? = null
    private val REQ_CAMERA = 2001
    private var surfaceReboundOnce = false
    private var cleanupInProgress: Boolean = false
    private var lastCleanupAtMs: Long = 0L
    private var usingPlatformView: Boolean = false
    private var isCameraPaused: Boolean = false  // New flag for pause/resume
    private var isCameraStarting: Boolean = false
    private var isCameraRunning: Boolean = false
    private var cameraReadyNotified: Boolean = false
    private var oesModeDecided: Boolean = false
    private var useOesCameraInput: Boolean = false
    private var oesReadySurfaceTexture: SurfaceTexture? = null
    private var oesReadyView: NosmaiPreviewView? = null
    private var oesListenersBoundView: NosmaiPreviewView? = null
    private var oesFirstFrameWatchdogGeneration: Long = 0
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private var backgroundExecutor: ExecutorService = Executors.newFixedThreadPool(3)
    private val cloudDownloadWaiters =
        ConcurrentHashMap<String, CopyOnWriteArrayList<Result>>()
    @Volatile private var isEngineAttached = false
    @Volatile private var flutterAssetPaths: List<String> = emptyList()
    private val pipelineStateListener = NosmaiEffects.PipelineStateListener { state ->
        runOnMain {
            try {
                if (::channel.isInitialized) {
                    channel.invokeMethod("onActiveEffectsChanged", pipelineStateToMap(state))
                }
            } catch (_: Throwable) {}
        }
    }
    private val gameEventListener = NosmaiEffects.GameEventListener { event ->
        runOnMain {
            try {
                if (isEngineAttached && ::channel.isInitialized) {
                    channel.invokeMethod("onGameEvent", event.toMap())
                }
            } catch (_: Throwable) {}
        }
    }
    @Volatile private var gameEventsEnabled = false

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else mainHandler.post(block)
    }

    private fun decideOesCameraModeIfNeeded() {
        if (oesModeDecided) return
        useOesCameraInput = isOesSafeDevice()
        oesModeDecided = true
        NosmaiLog.i(
            TAG,
            if (useOesCameraInput) {
                "OES camera input enabled for Flutter Android preview"
            } else {
                "OES camera input disabled for this device; using YUV camera input"
            }
        )
    }

    private fun configurePreviewViewForCamera(pv: NosmaiPreviewView) {
        decideOesCameraModeIfNeeded()
        try {
            pv.enableOesInput(useOesCameraInput)
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "enableOesInput unavailable; using YUV input: ${t.message}")
            useOesCameraInput = false
        }

        if (oesListenersBoundView !== pv) {
            oesReadySurfaceTexture = null
            oesReadyView = null
        } else {
            return
        }
        oesListenersBoundView = pv

        try {
            pv.addOnOesInputErrorListener { reason ->
                runOnMain { fallbackToYuvCamera(reason ?: "OES input error") }
            }
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "OES error listener unavailable: ${t.message}")
        }

        try {
            pv.addOnOesReadyListener(object : NosmaiPreviewView.OnOesReadyListener {
                override fun onOesReady(st: SurfaceTexture) {
                    runOnMain { handleOesReady(pv, st) }
                }
            })
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "OES ready listener unavailable: ${t.message}")
            useOesCameraInput = false
        }

        try {
            pv.setOnOesFrameProcessedListener {
                if (pv === previewView) {
                    handleFirstVisibleCameraFrame()
                }
            }
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "OES frame listener unavailable: ${t.message}")
        }
    }

    private fun handleOesReady(sourceView: NosmaiPreviewView, surfaceTexture: SurfaceTexture?) {
        if (!useOesCameraInput || surfaceTexture == null) return
        if (sourceView !== previewView) {
            NosmaiLog.i(TAG, "Ignoring stale OES SurfaceTexture from old preview view")
            return
        }
        oesReadySurfaceTexture = surfaceTexture
        oesReadyView = sourceView
        try {
            camera2Helper?.let { helper ->
                helper.setInputMode(Camera2Helper.InputMode.OES)
                if (helper.isCameraOpened()) {
                    helper.reconfigurePreviewSurfaceTexture(surfaceTexture)
                    armOesFirstFrameWatchdog(sourceView, surfaceTexture)
                } else {
                    helper.setOesPreviewSurfaceTexture(surfaceTexture)
                }
            }
            if (isProcessingActive && !isCameraRunning) {
                ensureCameraPermissionThenStart()
            }
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "OES SurfaceTexture wiring failed: ${t.message}")
            fallbackToYuvCamera("OES SurfaceTexture wiring failed")
        }
    }

    private fun fallbackToYuvCamera(reason: String) {
        if (!useOesCameraInput) return
        NosmaiLog.w(TAG, "Falling back to YUV camera input: $reason")
        useOesCameraInput = false
        oesReadySurfaceTexture = null
        oesReadyView = null
        try { previewView?.enableOesInput(false) } catch (_: Throwable) {}
        stopCameraHelper(true)
        if (isProcessingActive) {
            pendingStartProcessing = true
            ensureCameraPermissionThenStart()
        }
    }

    private fun isOesSafeDevice(): Boolean {
        val hardware = Build.HARDWARE?.lowercase().orEmpty()
        val manufacturer = Build.MANUFACTURER?.lowercase().orEmpty()
        val brand = Build.BRAND?.lowercase().orEmpty()

        if (hardware.contains("mt") ||
            manufacturer.contains("mediatek") ||
            brand.contains("tecno") ||
            brand.contains("infinix")
        ) {
            NosmaiLog.w(TAG, "OES disabled by device guard: hw=$hardware, manufacturer=$manufacturer, brand=$brand")
            return false
        }

        return true
    }

    companion object {
        private const val TAG = "NosmaiFlutterPlugin"
        private const val CHANNEL = "nosmai_camera_sdk"
        private const val FILTERS_PREFIX = "assets/filters/"
        private const val NOSMAI_FILTERS_PREFIX = "assets/nosmai_filters/"
        private const val CACHE_DIR_NAME = "NosmaiLocalFilters"
        /**
         * Process external I420 video buffer through Nosmai SDK filters
         * This method can be called from native code (e.g., Agora VideoFrameObserver)
         *
         * @param yBuffer Y plane buffer
         * @param uBuffer U plane buffer
         * @param vBuffer V plane buffer
         * @param width Frame width
         * @param height Frame height
         * @param yStride Y plane stride
         * @param uStride U plane stride
         * @param vStride V plane stride
         * @param rotation Frame rotation (0, 90, 180, 270)
         * @return true if processing succeeded, false otherwise
         */
        @JvmStatic
        fun processExternalI420Buffer(
            yBuffer: java.nio.ByteBuffer,
            uBuffer: java.nio.ByteBuffer,
            vBuffer: java.nio.ByteBuffer,
            width: Int,
            height: Int,
            yStride: Int,
            uStride: Int,
            vStride: Int,
            rotation: Int
        ): Boolean {
            return try {
                try {
                    val glView = com.nosmai.effect.internal.Nosmai.getCurrentGLView()

                    if (glView != null) {
                        val sourceRawData = glView.sourceRawData

                        if (sourceRawData != null) {
                            sourceRawData.ProcessData(
                                yBuffer,
                                uBuffer,
                                vBuffer,
                                width,
                                height,
                                yStride,
                                uStride,
                                vStride,
                                1,
                                1,
                                rotation
                            )
                            return true
                        }
                    }
                } catch (e: Exception) {
                    NosmaiLog.w(TAG, "Direct processing failed, trying pipeline ready callback: ${e.message}")
                }

                NosmaiSDK.addOnPipelineReady {
                    try {

                        val glView = com.nosmai.effect.internal.Nosmai.getCurrentGLView()

                        if (glView == null) {
                            return@addOnPipelineReady
                        }

                        val sourceRawData = glView.sourceRawData

                        if (sourceRawData == null) {
                            return@addOnPipelineReady
                        }

                        sourceRawData.ProcessData(
                            yBuffer,
                            uBuffer,
                            vBuffer,
                            width,
                            height,
                            yStride,
                            uStride,
                            vStride,
                            1,
                            1,
                            rotation
                        )

                        NosmaiLog.d(TAG, "Frame processed (callback)")
                    } catch (e: Exception) {
                        NosmaiLog.e(TAG, "Pipeline processing error: ${e.message}", e)
                    }
                }

                true
            } catch (e: Exception) {
                NosmaiLog.e(TAG, "Error processing external I420 buffer: ${e.message}", e)
                false
            }
        }
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        isEngineAttached = true
        if (backgroundExecutor.isShutdown) {
            backgroundExecutor = Executors.newFixedThreadPool(3)
        }
        context = flutterPluginBinding.applicationContext
        textures = flutterPluginBinding.textureRegistry
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        registerPipelineStateListener()

        flutterPluginBinding.platformViewRegistry.registerViewFactory(
            "nosmai_camera_preview",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context?, viewId: Int, args: Any?): PlatformView {
                    NosmaiLog.i(TAG, "Creating Nosmai PlatformView preview viewId=$viewId")
                    val ctx = context ?: this@NosmaiFlutterPlugin.context
                    val container = android.widget.FrameLayout(ctx)
                    val pv = NosmaiPreviewView(ctx)
                    configurePreviewViewForCamera(pv)
                    container.addView(
                        pv,
                        android.widget.FrameLayout.LayoutParams(
                            android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                            android.widget.FrameLayout.LayoutParams.MATCH_PARENT
                        )
                    )
                    val overlay = android.view.View(ctx)
                    overlay.setBackgroundColor(Color.BLACK)
                    overlay.alpha = 0f
                    overlay.visibility = android.view.View.GONE
                    container.addView(
                        overlay,
                        android.widget.FrameLayout.LayoutParams(
                            android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                            android.widget.FrameLayout.LayoutParams.MATCH_PARENT
                        )
                    )
                    previewView = pv
                    platformContainer = container
                    switchOverlayView = overlay
                    usingPlatformView = true
                    cameraReadyNotified = false

                    pendingStartProcessing = true

                    Handler(Looper.getMainLooper()).postDelayed({
                        try { attemptDeferredStart() } catch (_: Throwable) {}
                    }, 50)
                    return object : PlatformView {
                        override fun getView(): android.view.View = container
                        override fun dispose() {
                            val ownsActivePreview = previewView === pv || platformContainer === container
                            if (ownsActivePreview) {
                                try {
                                    stopCameraHelper(true)
                                } catch (_: Throwable) {}
                                try {
                                    NosmaiSDK.stopProcessing()
                                } catch (_: Throwable) {}
                                try {
                                    isProcessingActive = false
                                    pendingStartProcessing = false
                                    oesReadySurfaceTexture = null
                                    oesReadyView = null
                                    if (oesListenersBoundView === pv) {
                                        oesListenersBoundView = null
                                    }
                                } catch (_: Throwable) {}
                                try {
                                    cleanupInProgress = false
                                } catch (_: Throwable) {}
                            } else {
                                NosmaiLog.i(TAG, "Ignoring stale PlatformView dispose for viewId=$viewId")
                            }
                            try {
                                container.removeAllViews()
                                if (previewView === pv) {
                                    previewView = null
                                }
                            } catch (_: Throwable) {}
                            if (platformContainer === container) {
                                usingPlatformView = false
                                platformContainer = null
                                switchOverlayView = null
                            }
                        }
                    }
                }
            }
        )
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        isEngineAttached = false
        setGameEventsEnabled(false)
        unregisterPipelineStateListener()
        channel.setMethodCallHandler(null)
        try { surface?.release() } catch (_: Throwable) {}
        surface = null
        isSurfaceReady = false
        cloudDownloadWaiters.clear()
        backgroundExecutor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android")
            "getLocalFilters" -> handleGetLocalFilters(call, result)
            "getLocalEffects" -> handleGetLocalFiltersByType(call, "effect", result)
            "getLocalBackgrounds" -> handleGetLocalFiltersByType(call, "background", result)
            "getLocalBeautyEffects" -> handleGetLocalFiltersByType(call, "beauty_effect", result)
            "getLocalGames" -> handleGetLocalFiltersByType(call, "game", result)
            "applyEffect" -> handleApplyNosmaiPackage(call, "effectPath", result)
            "applyFilter" -> handleApplyNosmaiPackage(call, "filterPath", result)
            "getActiveEffects" -> handleGetActiveEffects(result)
            "getCurrentPipelineState" -> handleGetActiveEffects(result)
            "getActiveFilterInfo" -> handleGetActiveFilterInfo(result)
            "getActiveEffectInfo" -> handleGetActiveEffectInfo(result)
            "removeEffect" -> handleRemoveEffect(call, result)
            "isGameReady" -> result.success(NosmaiEffects.isGameReady())
            "sendGameTap" -> handleSendGameTap(call, result)
            "sendGameInput" -> handleSendGameInput(call, result)
            "pauseGame" -> { NosmaiEffects.pauseGame(); result.success(null) }
            "resumeGame" -> { NosmaiEffects.resumeGame(); result.success(null) }
            "restartGame" -> { NosmaiEffects.restartGame(); result.success(null) }
            "setGameEventListenerEnabled" -> {
                setGameEventsEnabled(call.argument<Boolean>("enabled") == true)
                result.success(null)
            }
            "initWithLicense" -> handleInitWithLicense(call, result)
            "createTexture", "createPreviewTexture" -> handleCreateTexture(result)
            "setRenderSurface" -> handleSetRenderSurface(call, result)
            "clearRenderSurface" -> handleClearRenderSurface(result)
            "configureCamera" -> handleConfigureCamera(call, result)
            "startProcessing" -> handleStartProcessing(result)
            "stopProcessing" -> handleStopProcessing(result)
            "pauseCamera" -> handlePauseCamera(result)
            "resumeCamera" -> handleResumeCamera(result)
            "switchCamera" -> handleSwitchCamera(result)
            "detachCameraView" -> handleDetachCameraView(result)
            "setPreviewView" -> result.success(null)
            "setFlashMode" -> handleSetFlashMode(call, result)
            "getFlashMode" -> handleGetFlashMode(result)
            "setTorchMode" -> handleSetTorchMode(call, result)
            "getTorchMode" -> handleGetTorchMode(result)
            "hasFlash" -> handleHasFlash(result)
            "hasTorch" -> handleHasTorch(result)
            "removeAllFilters" -> handleRemoveAllFilters(result)
            "clearAREffect" -> handleClearAREffect(result)
            "clearFilter" -> handleClearFilter(result)
            "clearAll" -> handleClearAll(result)
            "startRecording" -> handleStartRecording(result)
            "stopRecording" -> handleStopRecording(result)
            "isRecording" -> result.success(isRecording)
            "getCurrentRecordingDuration" -> result.success(getCurrentRecordingDurationSeconds())
            "applySkinSmoothing" -> handleApplySkinSmoothing(call, result)
            "applySkinWhitening" -> handleApplySkinWhitening(call, result)
            "applyFaceSlimming" -> handleApplyFaceSlimming(call, result)
            "applyEyeEnlargement" -> handleApplyEyeEnlargement(call, result)
            "applyNoseSize" -> handleApplyNoseSize(call, result)
            "applyBrightnessFilter" -> handleApplyBrightness(call, result)
            "applyContrastFilter" -> handleApplyContrast(call, result)
            "applyHue" -> handleApplyHue(call, result)
            "applyRGBFilter" -> handleApplyRGBFilter(call, result)
            "applySharpening" -> handleApplySharpening(call, result)
            "applyTeethWhitening" -> handleApplyTeethWhitening(call, result)
            "applyGrayscaleFilter" -> handleApplyGrayscaleFilter(result)
            "applyLipstick" -> handleApplyLipstick(call, result)
            "setLipstickIntensity" -> handleSetMakeupIntensity(NosmaiBeauty.MAKEUP_LIPSTICK, call, result)
            "removeLipstick" -> handleRemoveMakeup(NosmaiBeauty.MAKEUP_LIPSTICK, result)
            "hasLipstick" -> handleHasMakeup(NosmaiBeauty.MAKEUP_LIPSTICK, result)
            "getLipstickColors" -> handleGetLipstickColors(result)
            "applyEyeshadow" -> handleApplyEyeshadow(call, result)
            "setEyeshadowIntensity" -> handleSetMakeupIntensity(NosmaiBeauty.MAKEUP_EYESHADOW, call, result)
            "removeEyeshadow" -> handleRemoveMakeup(NosmaiBeauty.MAKEUP_EYESHADOW, result)
            "hasEyeshadow" -> handleHasMakeup(NosmaiBeauty.MAKEUP_EYESHADOW, result)
            "applyBlusher" -> handleApplyBlusher(call, result)
            "setBlusherIntensity" -> handleSetMakeupIntensity(NosmaiBeauty.MAKEUP_BLUSHER, call, result)
            "removeBlusher" -> handleRemoveMakeup(NosmaiBeauty.MAKEUP_BLUSHER, result)
            "hasBlusher" -> handleHasMakeup(NosmaiBeauty.MAKEUP_BLUSHER, result)
            "applyEyelash" -> handleApplyEyelash(call, result)
            "setEyelashIntensity" -> handleSetMakeupIntensity(NosmaiBeauty.MAKEUP_EYELASH, call, result)
            "removeEyelash" -> handleRemoveMakeup(NosmaiBeauty.MAKEUP_EYELASH, result)
            "hasEyelash" -> handleHasMakeup(NosmaiBeauty.MAKEUP_EYELASH, result)
            "applyEyebrow" -> handleApplyEyebrow(call, result)
            "setEyebrowIntensity" -> handleSetMakeupIntensity(NosmaiBeauty.MAKEUP_EYEBROW, call, result)
            "removeEyebrow" -> handleRemoveMakeup(NosmaiBeauty.MAKEUP_EYEBROW, result)
            "hasEyebrow" -> handleHasMakeup(NosmaiBeauty.MAKEUP_EYEBROW, result)
            "applyMakeupBlendLevel" -> handleApplyMakeupBlendLevel(call, result)
            "setFaceSlimLevel" -> handleSetFaceSlimLevel(call, result)
            "setEyeSizeLevel" -> handleSetEyeSizeLevel(call, result)
            "setNoseSlimLevel" -> handleSetNoseSlimLevel(call, result)
            "removeAllMorphing" -> handleRemoveAllMorphing(result)
            "setEyeColor" -> handleSetEyeColor(call, result)
            "setEyeColorIntensity" -> handleSetEyeColorIntensity(call, result)
            "removeEyeColoring" -> handleRemoveEyeColoring(result)
            "removeAllMakeup" -> handleRemoveAllMakeup(result)
            "removeAllBeautyEffects" -> handleRemoveAllBeautyEffects(result)
            "resetHSBFilter" -> handleResetHSBFilter(result)
            "adjustHSB" -> handleAdjustHSB(call, result)
            "applyWhiteBalance" -> handleApplyWhiteBalance(call, result)
            "removeBuiltInFilters" -> handleRemoveBuiltInBeautyFilters(result)
            "removeBuiltInFilterByName" -> handleRemoveBuiltInFilterByName(call, result)
            "isBeautyEffectEnabled" -> handleIsBeautyEffectEnabled(result)
            "isCloudFilterEnabled" -> handleIsCloudFilterEnabled(result)
            "getCloudFilters" -> handleGetCloudFilters(call, result)
            "downloadCloudFilter" -> handleDownloadCloudFilter(call, result)
            "removeCloudFilter" -> handleRemoveCloudFilter(call, result)
            "getFilters" -> handleGetFilters(call, result)
            "capturePhoto" -> handleCapturePhoto(result)
            "saveImageToGallery" -> handleSaveImageToGallery(call, result)
            "saveVideoToGallery" -> handleSaveVideoToGallery(call, result)
            "cleanup" -> handleCleanup(result)
            "dispose" -> handleDispose(result)
            "clearFilterCache" -> handleClearFilterCache(result)
            "clearLocalFiltersCache" -> handleClearFilterCache(result)
            "getAllLocalFilters" -> handleGetAllLocalFilters(call, result)
            "getDebugFilters" -> handleGetDebugFilters(call, result)
            "validateLocalFilters" -> handleValidateLocalFilters(call, result)
            "reinitializePreview" -> handleReinitializePreview(result)
            "getEffectParameters" -> handleGetEffectParameters(result)
            "getEffectParameterValue" -> handleGetEffectParameterValue(call, result)
            "setEffectParameter" -> handleSetEffectParameter(call, result)
            "setEffectParameterString" -> handleSetEffectParameterString(call, result)
            "isAdvancedFiltersEnabled" -> result.success(true)
            "setBackgroundSegmentation" -> handleSetBackgroundSegmentation(call, result)
            "clearBackgroundSegmentation" -> handleClearBackgroundSegmentation(result)
            else -> result.notImplemented()
        }
    }

    private fun registerPipelineStateListener() {
        try {
            NosmaiEffects.addPipelineStateListener(pipelineStateListener)
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "Unable to register active effects listener: ${t.message}")
        }
    }

    private fun unregisterPipelineStateListener() {
        try {
            NosmaiEffects.removePipelineStateListener(pipelineStateListener)
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "Unable to remove active effects listener: ${t.message}")
        }
    }

    private fun setGameEventsEnabled(enabled: Boolean) {
        if (gameEventsEnabled == enabled) return
        gameEventsEnabled = enabled
        try {
            if (enabled) {
                NosmaiEffects.addGameEventListener(gameEventListener)
            } else {
                NosmaiEffects.removeGameEventListener(gameEventListener)
            }
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "Unable to update game event listener: ${t.message}")
        }
    }

    private fun gameCoordinate(call: MethodCall, key: String): Float? {
        val value = call.argument<Number>(key)?.toDouble() ?: return null
        return value.takeIf { it.isFinite() && it in 0.0..1.0 }?.toFloat()
    }

    private fun handleSendGameTap(call: MethodCall, result: Result) {
        val x = gameCoordinate(call, "x")
        val y = gameCoordinate(call, "y")
        if (x == null || y == null) {
            result.error(
                "INVALID_ARGUMENT",
                "x and y must be finite values from 0 to 1",
                null
            )
            return
        }
        result.success(NosmaiEffects.sendGameTap(x, y))
    }

    private fun handleSendGameInput(call: MethodCall, result: Result) {
        val name = call.argument<String>("name")?.trim()
        val x = gameCoordinate(call, "x")
        val y = gameCoordinate(call, "y")
        val rawValue = call.argument<Number>("value")?.toDouble()
        if (name.isNullOrEmpty() || x == null || y == null ||
            rawValue == null || !rawValue.isFinite()) {
            result.error(
                "INVALID_ARGUMENT",
                "name, normalized x/y, and a finite value are required",
                null
            )
            return
        }
        result.success(
            NosmaiEffects.sendGameInput(name, x, y, rawValue.toFloat())
        )
    }

    private fun modeName(mode: NosmaiPipelineState.Mode?): String {
        return when (mode) {
            NosmaiPipelineState.Mode.EFFECTS_FILTERS -> "effectsFilters"
            NosmaiPipelineState.Mode.FILTERS_BACKGROUND -> "filtersBackground"
            NosmaiPipelineState.Mode.BEAUTY_FILTERS -> "beautyFilters"
            NosmaiPipelineState.Mode.BEAUTY_BACKGROUND -> "beautyBackground"
            NosmaiPipelineState.Mode.IDLE, null -> "idle"
        }
    }

    private fun backgroundSourceName(source: NosmaiPipelineState.BackgroundSource?): String {
        return when (source) {
            NosmaiPipelineState.BackgroundSource.MANUAL -> "manual"
            NosmaiPipelineState.BackgroundSource.FILTER -> "filter"
            NosmaiPipelineState.BackgroundSource.PACKAGE -> "package"
            NosmaiPipelineState.BackgroundSource.EFFECT -> "effect"
            NosmaiPipelineState.BackgroundSource.NONE, null -> "none"
        }
    }

    private fun filterInfoToMap(info: NosmaiFilterInfo?): Map<String, Any?>? {
        if (info == null) return null
        val map = HashMap<String, Any?>()
        try {
            info.toMap().forEach { entry -> map[entry.key] = entry.value }
            info.getPath()?.takeIf { it.isNotBlank() }?.let { path ->
                map["path"] = path
                map["effectPath"] = path
            }
            map["filterType"] = normalizeFilterType(info.getTypeKey())
            map["type"] = map["type"] ?: "local"
            map["isDownloaded"] = map["isDownloaded"] ?: true
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "Failed to serialize filter info: ${t.message}")
        }
        return map
    }

    private fun pipelineStateToMap(state: NosmaiPipelineState?): Map<String, Any?> {
        if (state == null) {
            return mapOf(
                "mode" to 0,
                "modeName" to "idle",
                "activeFilterPath" to null,
                "activeEffectPath" to null,
                "activeBackgroundPath" to null,
                "activeBackgroundPackagePath" to null,
                "hasBackground" to false,
                "backgroundActive" to false,
                "backgroundSource" to 0,
                "backgroundSourceName" to "none",
                "hasBeautyEffect" to false,
                "hasBuiltInBeauty" to false,
                "hasManualBackground" to false,
                "hasManualBackgroundConfig" to false,
                "activeFilterInfo" to null,
                "activeEffectInfo" to null
            )
        }

        val mode = state.mode
        val source = state.backgroundSource
        val activeFilterPath = state.activeFilterPath
        val activeEffectPath = state.activeEffectPath
        val activeFilterInfo = if (!activeFilterPath.isNullOrBlank()) {
            filterInfoToMap(NosmaiEffects.getActiveFilterInfo())
        } else {
            null
        }
        val activeEffectInfo = if (!activeEffectPath.isNullOrBlank()) {
            filterInfoToMap(NosmaiEffects.getActiveEffectInfo())
        } else {
            null
        }
        val hasBeautyEffectPackage =
            normalizeFilterType(activeEffectInfo?.get("filterType")?.toString()) == "beauty_effect"

        return mapOf(
            "mode" to (mode?.value ?: 0),
            "modeName" to modeName(mode),
            "activeFilterPath" to activeFilterPath,
            "activeEffectPath" to activeEffectPath,
            "activeBackgroundPath" to state.activeBackgroundPackagePath,
            "activeBackgroundPackagePath" to state.activeBackgroundPackagePath,
            "hasBackground" to state.isBackgroundActive,
            "backgroundActive" to state.isBackgroundActive,
            "backgroundSource" to (source?.value ?: 0),
            "backgroundSourceName" to backgroundSourceName(source),
            "hasBeautyEffect" to hasBeautyEffectPackage,
            "hasBuiltInBeauty" to NosmaiEffectsEngine.hasActiveBeautyFilters(),
            "hasManualBackground" to (state.activeBackgroundConfig != null),
            "hasManualBackgroundConfig" to (state.activeBackgroundConfig != null),
            "activeFilterInfo" to activeFilterInfo,
            "activeEffectInfo" to activeEffectInfo
        )
    }

    private fun handleGetActiveEffects(result: Result) {
        try {
            result.success(pipelineStateToMap(NosmaiEffects.getCurrentPipelineState()))
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getActiveEffects error", t)
            result.error("ACTIVE_EFFECTS_ERROR", t.message, null)
        }
    }

    private fun handleGetActiveFilterInfo(result: Result) {
        try {
            result.success(filterInfoToMap(NosmaiEffects.getActiveFilterInfo()))
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getActiveFilterInfo error", t)
            result.error("ACTIVE_FILTER_ERROR", t.message, null)
        }
    }

    private fun handleGetActiveEffectInfo(result: Result) {
        try {
            result.success(filterInfoToMap(NosmaiEffects.getActiveEffectInfo()))
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getActiveEffectInfo error", t)
            result.error("ACTIVE_EFFECT_ERROR", t.message, null)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun handleRemoveEffect(call: MethodCall, result: Result) {
        try {
            val raw = call.argument<Map<String, Any?>>("filter")
                ?: (call.arguments as? Map<String, Any?>)
                ?: emptyMap()
            val normalized = HashMap<String, Any>()
            raw.forEach { entry ->
                val value = entry.value
                if (value != null) normalized[entry.key] = value
            }
            val filterType = normalizeFilterType(
                raw["filterType"]?.toString()
                    ?: raw["sourceType"]?.toString()
                    ?: raw["filterCategory"]?.toString()
            )
            normalized["filterType"] = filterType
            NosmaiEffects.removeEffect(NosmaiFilterInfo.fromMap(normalized))
            completeWhenPackageSlotCleared(filterType, result, booleanResult = true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "removeEffect error", t)
            result.error("REMOVE_EFFECT_ERROR", t.message, null)
        }
    }

    // --- Local Filters ---
    private fun updateFlutterAssetPaths(call: MethodCall) {
        val paths = call.argument<List<*>>("assetPaths") ?: return
        flutterAssetPaths = paths.mapNotNull { value ->
            (value as? String)?.takeIf { it.isNotBlank() }
        }
    }

    private fun handleGetLocalFilters(call: MethodCall, result: Result) {
        try {
            updateFlutterAssetPaths(call)
            val forceRefresh = call.argument<Boolean>("forceRefresh") ?: false
            if (forceRefresh) clearFilterCache()

            val filters = getNosmaiFilters()
            result.success(filters)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getLocalFilters error", t)
            result.error("FILTER_LOAD_ERROR", t.message, null)
        }
    }

    private fun handleGetAllLocalFilters(call: MethodCall, result: Result) {
        try {
            updateFlutterAssetPaths(call)
            val forceRefresh = call.argument<Boolean>("forceRefresh") ?: false
            if (forceRefresh) clearFilterCache()

            val grouped = linkedMapOf<String, MutableList<Map<String, Any?>>>(
                "filter" to mutableListOf(),
                "effect" to mutableListOf(),
                "background" to mutableListOf(),
                "beauty_effect" to mutableListOf(),
                "game" to mutableListOf()
            )
            getNosmaiFilters().forEach { filter ->
                val type = normalizeFilterType(filter["filterType"]?.toString())
                grouped.getOrPut(type) { mutableListOf() }.add(filter)
            }
            result.success(grouped)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getAllLocalFilters error", t)
            result.error("FILTER_LOAD_ERROR", t.message, null)
        }
    }

    private fun handleGetDebugFilters(call: MethodCall, result: Result) {
        try {
            updateFlutterAssetPaths(call)
            val requestedType = call.argument<String>("filterType")
                ?: call.argument<String>("type")
            val normalizedType = requestedType
                ?.takeIf { it.isNotBlank() && !it.equals("all", ignoreCase = true) }
                ?.let(::normalizeFilterType)
            val filters = getNosmaiFilters().filter { filter ->
                filter["debug"] == true &&
                    (normalizedType == null ||
                        normalizeFilterType(filter["filterType"]?.toString()) == normalizedType)
            }
            result.success(filters)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getDebugFilters error", t)
            result.error("DEBUG_FILTER_LOAD_ERROR", t.message, null)
        }
    }

    private fun handleGetLocalFiltersByType(call: MethodCall, filterType: String, result: Result) {
        try {
            updateFlutterAssetPaths(call)
            val normalizedType = normalizeFilterType(filterType)
            val filters = getNosmaiFilters().filter {
                normalizeFilterType(it["filterType"]?.toString()) == normalizedType
            }
            result.success(filters)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getLocalFiltersByType error", t)
            result.error("FILTER_LOAD_ERROR", t.message, null)
        }
    }

    private fun handleApplyNosmaiPackage(call: MethodCall, preferredKey: String, result: Result) {
        val effectPathArg = call.argument<String>(preferredKey)
            ?: call.argument<String>("effectPath")
            ?: call.argument<String>("filterPath")
            ?: call.argument<String>("path")
        if (effectPathArg.isNullOrBlank()) {
            result.success(false)
            return
        }

        try {
            val file = resolveEffectToFile(effectPathArg)
            if (file == null || !file.exists()) {
                NosmaiLog.w(TAG, "Effect file not found for: $effectPathArg")
                result.success(false)
                return
            }

            NosmaiEffects.applyEffect(file.absolutePath, object : NosmaiEffects.EffectCallback {
                override fun onSuccess() {
                    mainHandler.post { result.success(true) }
                }

                override fun onError(errorMessage: String?) {
                    NosmaiLog.w(TAG, "Package apply failed: ${errorMessage ?: "unknown error"}")
                    mainHandler.post { result.success(false) }
                }
            })

        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "applyEffect error", t)
            result.success(false)
        }
    }

    // --- Initialization ---
    private fun handleInitWithLicense(call: MethodCall, result: Result) {
        try {
            val key = call.argument<String>("licenseKey").orEmpty()
            val act = activity
            if (act == null) {
                pendingLicenseKey = key
                result.success(true)
                return
            }
            initializeSdk(act, key)
            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "initWithLicense error", t)
            result.success(false)
        }
    }

    private fun setupLicenseCallback() {
        try {
            com.nosmai.effect.internal.Nosmai.setLicenseStatusCallback { isValid, status ->
                runOnMain {
                    val statusString = when {
                        isValid && status.equals("VALID", ignoreCase = true) -> "valid"
                        status.equals("EXPIRED", ignoreCase = true) -> "expired"
                        status.equals("INVALID", ignoreCase = true) -> "invalid"
                        else -> return@runOnMain
                    }
                    channel.invokeMethod("onLicenseStatusChanged", mapOf("status" to statusString))
                }
            }
        } catch (_: Throwable) {}
    }

    private fun parseCloudFilterVersion(value: String?): NosmaiCloudFilterVersion {
        return when (value?.trim()) {
            "2.0.0", null, "" -> NosmaiCloudFilterVersion.V2
            else -> throw IllegalArgumentException("Unsupported cloud filter version: $value")
        }
    }

    private fun initializeSdk(act: Activity, key: String) {
        if (isSdkInitialized) return

        setupLicenseCallback()

        NosmaiSDK.initialize(act, key)

        previewView?.let { pv ->
            configurePreviewViewForCamera(pv)
            if (!usingPlatformView && pv.parent == null) {
                val root = act.findViewById<ViewGroup>(android.R.id.content)
                val lp = ViewGroup.LayoutParams(1, 1)
                root.addView(pv, lp)
                pv.alpha = 0f
            }
            try {
                if (!isSwitchingCamera && pendingMirrorForNextFrame == null) {
                    NosmaiSDK.setMirrorX(isFrontCamera)
                } else {
                    pendingMirrorForNextFrame = isFrontCamera
                }
            } catch (_: Throwable) {}

            try {
                pv.initializePipeline()
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "⚠️ Pipeline initialization warning: ${e.message}")
            }
        }

        isSdkInitialized = true

        if (usingPlatformView && pendingStartProcessing && !isProcessingActive && previewView != null) {
            Handler(Looper.getMainLooper()).post {
                try { attemptDeferredStart() } catch (t: Throwable) {
                    NosmaiLog.e(TAG, "PlatformView start after SDK init failed", t)
                }
            }
        }


        try {
            val w = pendingSurfaceWidth
            val h = pendingSurfaceHeight
            if (surface != null && w != null && h != null) {
                NosmaiSDK.setRenderSurface(surface!!, w, h)
                if (!isSwitchingCamera && pendingMirrorForNextFrame == null) {
                    NosmaiSDK.setMirrorX(isFrontCamera)
                } else {
                    pendingMirrorForNextFrame = isFrontCamera
                }
                pendingSurfaceWidth = null
                pendingSurfaceHeight = null
                isSurfaceReady = true
                if (pendingStartProcessing && !isProcessingActive && previewView != null) {
                    try {
                        NosmaiSDK.startProcessing(previewView!!)
                        isProcessingActive = true
                        ensureCameraPermissionThenStart()
                    } catch (_: Throwable) {}
                    pendingStartProcessing = false
                }
            }
        } catch (_: Throwable) {}
    }


    private fun handleCreateTexture(result: Result) {
        try {
            textureEntry = textures.createSurfaceTexture()
            surfaceReboundOnce = false
            isSurfaceReady = false
            result.success(textureEntry!!.id().toInt())
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "createTexture error", t)
            result.error("TEXTURE_ERROR", t.message, null)
        }
    }

    private fun handleSetRenderSurface(call: MethodCall, result: Result) {
        try {
            val texId = call.argument<Number>("textureId")?.toInt()
            val w = call.argument<Number>("width")?.toInt() ?: 720
            val h = call.argument<Number>("height")?.toInt() ?: 1280
            if (texId == null) {
                result.error("ARG_ERROR", "textureId required", null)
                return
            }
            val entry = textureEntry
            if (entry == null) {
                result.success(false)
                return
            }
            val st = entry.surfaceTexture()
            st.setDefaultBufferSize(w, h)
            surface = Surface(st)

            if (isSdkInitialized) {
                NosmaiSDK.setRenderSurface(surface!!, w, h)
                try {
                    if (!isSwitchingCamera && pendingMirrorForNextFrame == null) {
                        NosmaiSDK.setMirrorX(isFrontCamera)
                    } else {
                        pendingMirrorForNextFrame = isFrontCamera
                    }
                } catch (_: Throwable) {}
                isSurfaceReady = true
                if (pendingStartProcessing && !isProcessingActive) {
                    try {
                        previewView?.let {
                            NosmaiSDK.startProcessing(it)
                            isProcessingActive = true
                            ensureCameraPermissionThenStart()
                        }
                    } catch (e: Throwable) { NosmaiLog.e(TAG, "deferred startProcessing error", e) }
                    pendingStartProcessing = false
                }
                result.success(true)
            } else {
                pendingSurfaceWidth = w
                pendingSurfaceHeight = h
                isSurfaceReady = true
                result.success(true)
            }
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setRenderSurface error", t)
            result.success(false)
        }
    }

    // --- Camera / Processing ---
    private var isFrontCamera: Boolean = true
    @Volatile private var isSwitchingCamera: Boolean = false
    private var lastSwitchAtMs: Long = 0L
    private var isProcessingActive: Boolean = false
    @Volatile private var suppressPreviewUntilMirrored: Boolean = false
    @Volatile private var pendingMirrorForNextFrame: Boolean? = null

    private fun handleConfigureCamera(call: MethodCall, result: Result) {
        try {
            val pos = call.argument<String>("position") ?: "front"
            isFrontCamera = (pos == "front")
            NosmaiLog.d(TAG, "ConfigureCamera: position=$pos, isFrontCamera=$isFrontCamera")
            try { NosmaiSDK.setCameraFacing(isFrontCamera) } catch (_: Throwable) {}
            try { NosmaiSDK.setMirrorX(isFrontCamera) } catch (_: Throwable) {}
            NosmaiLog.d(TAG, "SetMirrorX called with: $isFrontCamera")
            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "configureCamera error", t)
            result.error("CONFIG_ERROR", t.message, null)
        }
    }

    private fun handleStartProcessing(result: Result) {
        try {
            if (usingPlatformView && isProcessingActive) {
                NosmaiLog.i(TAG, "PlatformView already active, skipping duplicate start")
                pendingStartProcessing = false
                if (!isCameraRunning) {
                    ensureCameraPermissionThenStart()
                }
                result.success(null)
                return
            }

            if (usingPlatformView) {
                cleanupInProgress = false
            } else {
                val now = System.currentTimeMillis()
                if (cleanupInProgress || (now - lastCleanupAtMs) < 700) {
                    NosmaiLog.d(TAG, "Cleanup in progress, deferring start...")
                    pendingStartProcessing = true
                    val delay = (700 - (now - lastCleanupAtMs)).coerceAtLeast(100)
                    Handler(Looper.getMainLooper()).postDelayed({
                        try { attemptDeferredStart() } catch (_: Throwable) {}
                    }, delay)
                    result.success(null)
                    return
                }
            }

            val act = activity
            if (act != null && previewView == null && !usingPlatformView) {
                if (textureEntry == null && surface == null) {
                    NosmaiLog.d(TAG, "Preview view not ready yet, deferring start until AndroidView is created")
                    pendingStartProcessing = true
                    Handler(Looper.getMainLooper()).postDelayed({
                        try { attemptDeferredStart() } catch (_: Throwable) {}
                    }, 100)
                    result.success(null)
                    return
                }
                NosmaiLog.d(TAG, "   Creating off-screen NosmaiPreviewView (texture mode)")
                previewView = NosmaiPreviewView(act)
                previewView?.let { configurePreviewViewForCamera(it) }
                val root = act.findViewById<ViewGroup>(android.R.id.content)
                if (previewView?.parent == null) {
                    val lp = ViewGroup.LayoutParams(1, 1)
                    root.addView(previewView, lp)
                    previewView?.alpha = 0f
                }
                try { previewView?.initializePipeline() } catch (_: Throwable) {}
            }
            if (previewView == null) {
                result.error("NO_PREVIEW", "Preview not initialized", null)
                return
            }
            if (!usingPlatformView && (!isSurfaceReady || surface == null || !(surface?.isValid ?: false))) {
                pendingStartProcessing = true
                result.success(null)
                return
            }
            try { previewView?.initializePipeline() } catch (_: Throwable) {}


            NosmaiSDK.startProcessing(previewView!!)
            isProcessingActive = true
            cameraReadyNotified = false
            pendingStartProcessing = false
            try { NosmaiSDK.setCameraFacing(isFrontCamera) } catch (_: Throwable) {}
            try { NosmaiSDK.setMirrorX(isFrontCamera) } catch (_: Throwable) {}


            ensureCameraPermissionThenStart()
            try { previewView?.requestRenderUpdate() } catch (_: Throwable) {}
            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "startProcessing error", t)
            result.error("START_ERROR", t.message, null)
        }
    }

    private fun handleStopProcessing(result: Result) {
        try {
            cleanupInProgress = true
            lastCleanupAtMs = System.currentTimeMillis()
            stopCameraHelper(true)
            NosmaiSDK.stopProcessing()
            isProcessingActive = false
            oesReadySurfaceTexture = null
            oesReadyView = null
            result.success(null)
            Handler(Looper.getMainLooper()).postDelayed({ cleanupInProgress = false }, 400)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "stopProcessing error", t)
            result.error("STOP_ERROR", t.message, null)
        }
    }

    private fun handlePauseCamera(result: Result) {
        try {
            NosmaiLog.d(TAG, "⏸️ pauseCamera called (isProcessingActive=$isProcessingActive, isCameraPaused=$isCameraPaused)")

            if (!isProcessingActive) {
                NosmaiLog.w(TAG, "   ⚠️ Processing not active, cannot pause")
                result.success(false)
                return
            }

            if (isCameraPaused) {
                NosmaiLog.w(TAG, "   ⚠️ Camera already paused")
                result.success(true)
                return
            }

            // Only stop camera hardware - SDK processing stays active
            try {
                stopCameraHelper(false)
                NosmaiLog.d(TAG, "Camera hardware stopped")
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "Camera stop warning: ${e.message}")
            }

            isCameraPaused = true
            NosmaiLog.d(TAG, "Camera paused successfully")
            result.success(true)

        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "pauseCamera error", t)
            result.error("PAUSE_ERROR", t.message, null)
        }
    }

    private fun handleResumeCamera(result: Result) {
        try {

            if (!isProcessingActive) {
                NosmaiLog.w(TAG, "Processing not active, cannot resume")
                result.success(false)
                return
            }

            if (!isCameraPaused) {
                NosmaiLog.w(TAG, "Camera not paused, nothing to resume")
                result.success(true)
                return
            }

            try {
                startCamera()
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "Camera restart warning: ${e.message}")
            }

            result.success(true)

        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "resumeCamera error", t)
            result.error("RESUME_ERROR", t.message, null)
        }
    }

    private fun handleDetachCameraView(result: Result) {
        try {
            try { camera2Helper?.cancelRetry() } catch (_: Throwable) {}
            stopCameraHelper(true)
            isProcessingActive = false
            pendingStartProcessing = false
            surfaceReboundOnce = false
            oesReadySurfaceTexture = null
            oesReadyView = null
            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "detachCameraView error", t)
            result.success(null)
        }
    }

    private fun handleSetFlashMode(call: MethodCall, result: Result) {
        try {
            val flashModeString = call.argument<String>("flashMode")
            if (flashModeString.isNullOrBlank()) {
                result.error("INVALID_PARAMETER", "Flash mode is required", null)
                return
            }

            val flashMode = when (flashModeString) {
                "on" -> android.hardware.camera2.CaptureRequest.FLASH_MODE_SINGLE
                "off" -> android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF
                "auto" -> android.hardware.camera2.CaptureRequest.FLASH_MODE_SINGLE
                else -> android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF
            }

            camera2Helper?.setFlashMode(flashMode)
            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setFlashMode error", t)
            result.error("FLASH_ERROR", "Failed to set flash mode: ${t.message}", null)
        }
    }

    private fun handleGetFlashMode(result: Result) {
        try {
            val flashMode = camera2Helper?.getFlashMode() ?: android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF

            val modeString = when (flashMode) {
                android.hardware.camera2.CaptureRequest.FLASH_MODE_SINGLE -> "on"
                android.hardware.camera2.CaptureRequest.FLASH_MODE_TORCH -> "on"
                else -> "off"
            }

            result.success(modeString)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getFlashMode error", t)
            result.success("off")
        }
    }

    private fun handleSetTorchMode(call: MethodCall, result: Result) {
        try {
            val torchModeString = call.argument<String>("torchMode")
            if (torchModeString.isNullOrBlank()) {
                result.error("INVALID_PARAMETER", "Torch mode is required", null)
                return
            }

            val torchMode = when (torchModeString) {
                "on" -> android.hardware.camera2.CaptureRequest.FLASH_MODE_TORCH
                "off" -> android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF
                "auto" -> android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF
                else -> android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF
            }

            camera2Helper?.setTorchMode(torchMode)
            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setTorchMode error", t)
            result.error("TORCH_ERROR", "Failed to set torch mode: ${t.message}", null)
        }
    }

    private fun handleGetTorchMode(result: Result) {
        try {
            val torchMode = camera2Helper?.getTorchMode() ?: android.hardware.camera2.CaptureRequest.FLASH_MODE_OFF

            val modeString = when (torchMode) {
                android.hardware.camera2.CaptureRequest.FLASH_MODE_TORCH -> "on"
                else -> "off"
            }

            result.success(modeString)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getTorchMode error", t)
            result.success("off")
        }
    }

    private fun handleHasTorch(result: Result) {
        try {
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val cameraIdList = cameraManager.cameraIdList

            for (cameraId in cameraIdList) {
                val characteristics = cameraManager.getCameraCharacteristics(cameraId)
                val flashAvailable = characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE)

                if (flashAvailable == true) {
                    result.success(true)
                    return
                }
            }

            result.success(false)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "hasTorch error", t)
            result.success(false)
        }
    }

    private fun handleHasFlash(result: Result) {
        handleHasTorch(result)
    }

    private fun handleSwitchCamera(result: Result) {
        try {
            val now = System.currentTimeMillis()
            if (isSwitchingCamera || (now - lastSwitchAtMs) < 700) {
                result.success(false)
                return
            }
            isSwitchingCamera = true
            suppressPreviewUntilMirrored = true
            runOnMain {
                try {
                    switchOverlayView?.let { ov ->
                        ov.clearAnimation()
                        ov.alpha = 0f
                        ov.visibility = android.view.View.VISIBLE
                        ov.animate().alpha(1f).setDuration(40).start()
                    }
                } catch (_: Throwable) {}
            }
            lastSwitchAtMs = now

            val act = activity
            if (act == null) {
                isSwitchingCamera = false
                result.error("NO_ACTIVITY", "Activity not available", null)
                return
            }

            act.runOnUiThread {
                try {
                    isFrontCamera = !isFrontCamera

                    stopCameraHelper(true)

                    surfaceReboundOnce = false

                    try {
                        NosmaiSDK.setCameraFacing(isFrontCamera)
                        pendingMirrorForNextFrame = isFrontCamera
                    } catch (_: Throwable) {}

                    Handler(Looper.getMainLooper()).postDelayed({
                        try {
                            ensureCameraPermissionThenStart()
                            try {
                                if (!isProcessingActive && previewView != null) {
                                    if (isSurfaceReady && surface != null && surface!!.isValid) {
                                        NosmaiSDK.startProcessing(previewView!!)
                                        isProcessingActive = true
                                    } else {
                                        pendingStartProcessing = true
                                    }
                                }
                            } catch (_: Throwable) {}
                            result.success(true)
                        } catch (e: Throwable) {
                            NosmaiLog.e(TAG, "switchCamera delayed open error", e)
                            result.success(false)
                        } finally {
                            isSwitchingCamera = false
                        }
                    }, 120)
                } catch (t: Throwable) {
                    NosmaiLog.e(TAG, "switchCamera error", t)
                    result.success(false)
                    isSwitchingCamera = false
                }
            }
        } catch (t: Throwable) {
            isSwitchingCamera = false
            NosmaiLog.e(TAG, "switchCamera error", t)
            result.success(false)
        }
    }

    private fun handleRemoveAllFilters(result: Result) {
        try {
            val success = NosmaiSDK.clearAllEffects()
            result.success(success)

        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "removeAllFilters error", t)
            result.error("REMOVE_FILTERS_ERROR", t.message, null)
        }
    }

    private fun handleClearAREffect(result: Result) {
        try {
            NosmaiEffects.clearAREffect()
            completeWhenPackageSlotCleared("effect", result)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "clearAREffect error", t)
            result.error("CLEAR_AR_ERROR", t.message, null)
        }
    }

    private fun handleClearFilter(result: Result) {
        try {
            NosmaiEffects.clearFilter()
            completeWhenPackageSlotCleared("filter", result)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "clearFilter error", t)
            result.error("CLEAR_FILTER_ERROR", t.message, null)
        }
    }

    private fun completeWhenPackageSlotCleared(
        filterType: String,
        result: Result,
        booleanResult: Boolean = false
    ) {
        val normalized = normalizeFilterType(filterType)
        val deadline = android.os.SystemClock.uptimeMillis() + 2_000L
        val poll = object : Runnable {
            override fun run() {
                try {
                    val state = NosmaiEffects.getCurrentPipelineState()
                    val cleared = when (normalized) {
                        "filter" -> state.activeFilterPath.isNullOrBlank()
                        "background" -> state.activeBackgroundPackagePath.isNullOrBlank()
                        "beauty_effect", "effect", "game" ->
                            state.activeEffectPath.isNullOrBlank()
                        else -> !NosmaiEffectsEngine.hasActiveEffect()
                    }
                    if (cleared) {
                        result.success(if (booleanResult) true else null)
                    } else if (android.os.SystemClock.uptimeMillis() >= deadline) {
                        if (booleanResult) {
                            result.success(false)
                        } else {
                            result.error(
                                "CLEAR_TIMEOUT",
                                "Package slot did not clear in time",
                                normalized
                            )
                        }
                    } else {
                        mainHandler.postDelayed(this, 16L)
                    }
                } catch (t: Throwable) {
                    result.error("CLEAR_ERROR", t.message, normalized)
                }
            }
        }
        mainHandler.post(poll)
    }

    private fun handleClearAll(result: Result) {
        try {
            val success = NosmaiSDK.clearAllEffects()
            result.success(success)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "clearAll error", t)
            result.error("CLEAR_ALL_ERROR", t.message, null)
        }
    }

    // --- Recording ---
    private var isRecording: Boolean = false
    private var recordingStartMs: Long = 0L
    private var recordingPath: String? = null
    private var audioRecorder: MediaRecorder? = null
    private var audioPath: String? = null
    private val REQ_AUDIO = 2002

    private fun handleStartRecording(result: Result) {
        try {
            val pv = previewView
            if (pv == null) {
                result.success(false)
                return
            }

            // Check audio permission
            val act = activity
            if (act != null && ContextCompat.checkSelfPermission(act, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.RECORD_AUDIO), REQ_AUDIO)
                result.success(false)
                return
            }

            val outDir = File(context.cacheDir, "NosmaiRecordings")
            if (!outDir.exists()) outDir.mkdirs()
            val timestamp = java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US).format(java.util.Date())
            val videoFile = File(outDir, "nosmai_video_$timestamp.mp4")
            val audioFile = File(outDir, "nosmai_audio_$timestamp.m4a")
            audioPath = audioFile.absolutePath

            // Start audio recording with MediaRecorder
            try {
                audioRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    MediaRecorder(context)
                } else {
                    @Suppress("DEPRECATION")
                    MediaRecorder()
                }
                audioRecorder?.apply {
                    setAudioSource(MediaRecorder.AudioSource.MIC)
                    setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                    setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                    setAudioSamplingRate(44100)
                    setAudioEncodingBitRate(128000)
                    setOutputFile(audioFile.absolutePath)
                    prepare()
                    start()
                }
            } catch (e: Exception) {
                NosmaiLog.e(TAG, "Failed to start audio recording", e)
                audioRecorder = null
            }

            // Start video recording with NosmaiSDK
            NosmaiSDK.startRecording(pv, videoFile.absolutePath, object : com.nosmai.effect.api.NosmaiSDK.RecordingCallback {
                override fun onStarted(success: Boolean, error: String?) {
                    if (success) {
                        isRecording = true
                        recordingStartMs = System.currentTimeMillis()
                        recordingPath = videoFile.absolutePath
                        result.success(true)
                    } else {
                        // Stop audio recording if video fails
                        try {
                            audioRecorder?.stop()
                            audioRecorder?.release()
                            audioRecorder = null
                        } catch (_: Throwable) {}
                        result.success(false)
                    }
                }
            })
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "startRecording error", t)
            result.success(false)
        }
    }

    private fun handleStopRecording(result: Result) {
        try {
            if (!isRecording) {
                result.success(mapOf(
                    "success" to false,
                    "duration" to 0.0,
                    "fileSize" to 0,
                    "error" to "Not currently recording"
                ))
                return
            }

            val audioFilePath = audioPath
            try {
                audioRecorder?.stop()
                audioRecorder?.release()
                audioRecorder = null
            } catch (e: Exception) {
                NosmaiLog.e(TAG, "Failed to stop audio recording", e)
            }

            val start = recordingStartMs
            val pathAtStop = recordingPath
            com.nosmai.effect.api.NosmaiSDK.stopRecording(object : com.nosmai.effect.api.NosmaiSDK.RecordingCallback {
                override fun onCompleted(outputPath: String?, success: Boolean, error: String?) {
                    isRecording = false
                    val videoPath = outputPath ?: pathAtStop
                    val durationSec = if (start > 0) ((System.currentTimeMillis() - start) / 1000.0) else 0.0

                    if (success && videoPath != null && audioFilePath != null && File(audioFilePath).exists()) {
                        // Merge audio and video
                        Thread {
                            try {
                                val outDir = File(context.cacheDir, "NosmaiRecordings")
                                val timestamp = java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US).format(java.util.Date())
                                val mergedFile = File(outDir, "nosmai_final_$timestamp.mp4")

                                val merged = mergeAudioVideo(videoPath, audioFilePath, mergedFile.absolutePath)

                                if (merged) {
                                    // Delete temporary files
                                    try { File(videoPath).delete() } catch (_: Throwable) {}
                                    try { File(audioFilePath).delete() } catch (_: Throwable) {}

                                    val size = try { mergedFile.length().toInt() } catch (_: Throwable) { 0 }
                                    val map = mutableMapOf<String, Any?>(
                                        "success" to true,
                                        "duration" to durationSec,
                                        "fileSize" to size,
                                        "videoPath" to mergedFile.absolutePath
                                    )
                                    Handler(Looper.getMainLooper()).post { result.success(map) }
                                } else {
                                    // Return video without audio if merge fails
                                    val size = try { File(videoPath).length().toInt() } catch (_: Throwable) { 0 }
                                    val map = mutableMapOf<String, Any?>(
                                        "success" to true,
                                        "duration" to durationSec,
                                        "fileSize" to size,
                                        "videoPath" to videoPath
                                    )
                                    Handler(Looper.getMainLooper()).post { result.success(map) }
                                }
                            } catch (e: Exception) {
                                NosmaiLog.e(TAG, "Failed to merge audio/video", e)
                                // Return video without audio
                                val size = try { File(videoPath).length().toInt() } catch (_: Throwable) { 0 }
                                val map = mutableMapOf<String, Any?>(
                                    "success" to true,
                                    "duration" to durationSec,
                                    "fileSize" to size,
                                    "videoPath" to videoPath
                                )
                                Handler(Looper.getMainLooper()).post { result.success(map) }
                            }
                        }.start()
                    } else {
                        // No audio or recording failed
                        val size = try { if (videoPath != null) File(videoPath).length().toInt() else 0 } catch (_: Throwable) { 0 }
                        val map = mutableMapOf<String, Any?>(
                            "success" to success,
                            "duration" to durationSec,
                            "fileSize" to size
                        )
                        if (videoPath != null) map["videoPath"] = videoPath
                        if (!success && !error.isNullOrBlank()) map["error"] = error
                        result.success(map)
                    }
                }
            })
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "stopRecording error", t)
            isRecording = false
            result.success(mapOf(
                "success" to false,
                "duration" to 0.0,
                "fileSize" to 0,
                "error" to (t.message ?: "Unknown error")
            ))
        }
    }

    private fun getCurrentRecordingDurationSeconds(): Double {
        return if (isRecording && recordingStartMs > 0) {
            (System.currentTimeMillis() - recordingStartMs) / 1000.0
        } else 0.0
    }

    /** Execute a beauty operation and preserve native license enforcement. */
    private inline fun executeBeautyFilter(
        filterName: String,
        operation: () -> Unit,
        result: Result
    ) {
        try {
            operation()
            NosmaiLog.d(TAG, "$filterName applied successfully")
            result.success(null)
        } catch (licenseError: IllegalStateException) {
            NosmaiLog.e(TAG, "$filterName error: ${licenseError.message}", licenseError)
            val code = if (licenseError.message?.contains(
                    "license",
                    ignoreCase = true
                ) == true
            ) "INVALID_LICENSE" else "FILTER_ERROR"
            result.error(code, licenseError.message, null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "$filterName error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun normalizedUnit(value: Number?, defaultValue: Double = 0.5): Float {
        val raw = value?.toDouble() ?: defaultValue
        val unit = if (raw > 1.0) raw / 100.0 else raw
        return unit.coerceIn(0.0, 1.0).toFloat()
    }

    private fun requireSdkReady(result: Result): Boolean {
        if (isSdkInitialized) return true
        result.error("FILTER_ERROR", "SDK not initialized. Call initWithLicense first.", null)
        return false
    }

    private fun handleApplySkinSmoothing(call: MethodCall, result: Result) {
        NosmaiLog.d("[FilterTest]", "Apply Smoothing")
        if (!isSdkInitialized) {
            result.error("FILTER_ERROR", "SDK not initialized. Call initWithLicense first.", null)
            return
        }
        val level = call.argument<Number>("level")?.toDouble() ?: 0.0
        val normalized = (level / 10.0).coerceIn(0.0, 1.0)
        executeBeautyFilter("SkinSmoothing", {
            NosmaiBeauty.applySkinSmoothing(normalized.toFloat())
        }, result)
    }

    private fun handleApplySkinWhitening(call: MethodCall, result: Result) {
        try {
            if (!isSdkInitialized) {
                result.error("FILTER_ERROR", "SDK not initialized.", null)
                return
            }

            val level = call.argument<Number>("level")?.toDouble() ?: 0.0
            val normalized = (level / 10.0).coerceIn(0.0, 1.0)
            NosmaiBeauty.applySkinWhitening(normalized.toFloat())
            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "SkinWhitening error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleApplyFaceSlimming(call: MethodCall, result: Result) {
        try {
            if (!isSdkInitialized) {
                result.error("FILTER_ERROR", "SDK not initialized.", null)
                return
            }

            val level = call.argument<Number>("level")?.toDouble() ?: 0.0
            val normalized = (level / 10.0).coerceIn(0.0, 1.0)
            NosmaiBeauty.applyFaceSlimming(normalized.toFloat())
            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "FaceSlimming error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleApplyEyeEnlargement(call: MethodCall, result: Result) {
        try {
            val level = call.argument<Number>("level")?.toDouble() ?: 0.0
            val normalized = (level / 10.0).coerceIn(0.0, 1.0)
            NosmaiBeauty.applyEyeEnlargement(normalized.toFloat())
            result.success(null)
        } catch (t: Throwable) { result.error("FILTER_ERROR", t.message, null) }
    }

    private fun handleApplyNoseSize(call: MethodCall, result: Result) {
        try {
            val level = call.argument<Number>("level")?.toDouble() ?: 0.0
            val normalized = (level / 100.0).coerceIn(0.0, 1.0)
            NosmaiBeauty.applyNoseSize(normalized.toFloat())
            result.success(null)
        } catch (t: Throwable) { result.error("FILTER_ERROR", t.message, null) }
    }

    private fun handleApplyBrightness(call: MethodCall, result: Result) {
        try {
            val brightness = call.argument<Number>("brightness")?.toDouble() ?: 0.0
            val clamped = brightness.coerceIn(-1.0, 1.0)
            NosmaiBeauty.applyBrightness(clamped.toFloat())
            result.success(null)
        } catch (t: Throwable) { result.error("FILTER_ERROR", t.message, null) }
    }

    private fun handleApplyContrast(call: MethodCall, result: Result) {
        try {
            val contrast = call.argument<Number>("contrast")?.toDouble() ?: 1.0
            val clamped = contrast.coerceIn(0.0, 2.0)
            NosmaiBeauty.applyContrast(clamped.toFloat())
            result.success(null)
        } catch (t: Throwable) { result.error("FILTER_ERROR", t.message, null) }
    }

    private fun handleApplyHue(call: MethodCall, result: Result) {
        try {
            val hue = call.argument<Number>("hueAngle")?.toDouble() ?: 0.0
            NosmaiBeauty.applyHue(hue.toFloat())
            result.success(null)
        } catch (t: Throwable) { result.error("FILTER_ERROR", t.message, null) }
    }

    private fun handleApplyRGBFilter(call: MethodCall, result: Result) {
        try {
            if (!isSdkInitialized) {
                result.error("FILTER_ERROR", "SDK not initialized.", null)
                return
            }

            val red = call.argument<Number>("red")?.toFloat() ?: 1.0f
            val green = call.argument<Number>("green")?.toFloat() ?: 1.0f
            val blue = call.argument<Number>("blue")?.toFloat() ?: 1.0f

            NosmaiBeauty.applyRGB(red, green, blue)

            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "RGB filter error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleApplySharpening(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)
        executeBeautyFilter("Sharpening", {
            NosmaiBeauty.applySharpen(intensity)
        }, result)
    }

    private fun handleApplyTeethWhitening(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.0)
        executeBeautyFilter("TeethWhitening", {
            NosmaiBeauty.applyTeethWhitening(intensity)
        }, result)
    }

    private fun handleApplyGrayscaleFilter(result: Result) {
        if (!requireSdkReady(result)) return
        executeBeautyFilter("Grayscale", {
            NosmaiBeauty.setGrayscaleEnabled(true)
        }, result)
    }

    private fun handleApplyLipstick(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return

            val style = call.argument<Number>("style")?.toInt() ?: NosmaiBeauty.LIPSTICK_MATTE
            val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)

            NosmaiBeauty.applyLipstickStyle(style, 0.72f, 0.08f, 0.12f)
            NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_LIPSTICK, intensity)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Lipstick error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleGetLipstickColors(result: Result) {
        result.success(listOf(
            mapOf("name" to "Classic Red", "r" to 0.72, "g" to 0.08, "b" to 0.12),
            mapOf("name" to "Rose", "r" to 0.70, "g" to 0.24, "b" to 0.28),
            mapOf("name" to "Natural", "r" to 0.58, "g" to 0.22, "b" to 0.18)
        ))
    }

    private fun handleApplyEyeshadow(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return

            val style = call.argument<Number>("style")?.toInt() ?: NosmaiBeauty.EYESHADOW_NATURAL
            val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)

            NosmaiBeauty.applyEyeshadowStyle(style, 0.42f, 0.30f, 0.48f)
            NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_EYESHADOW, intensity)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Eyeshadow error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleApplyBlusher(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return

            val style = call.argument<Number>("style")?.toInt() ?: NosmaiBeauty.BLUSHER_NATURAL
            val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)

            NosmaiBeauty.applyBlusherStyle(style, 0.95f, 0.38f, 0.42f)
            NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_BLUSHER, intensity)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Blusher error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleApplyEyelash(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return

            val style = call.argument<Number>("style")?.toInt() ?: 0
            val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)

            NosmaiBeauty.applyEyelashStyle(style)
            NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_EYELASH, intensity)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Eyelash error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleApplyEyebrow(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return

            val style = call.argument<Number>("style")?.toInt() ?: 0
            val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)

            NosmaiBeauty.applyEyebrowStyle(style, 0.16f, 0.11f, 0.08f)
            NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_EYEBROW, intensity)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Eyebrow error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleSetMakeupIntensity(category: Int, call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)
        executeBeautyFilter("SetMakeupIntensity", {
            NosmaiBeauty.setMakeupIntensity(category, intensity)
        }, result)
    }

    private fun handleRemoveMakeup(category: Int, result: Result) {
        if (!requireSdkReady(result)) return
        executeBeautyFilter("RemoveMakeup", {
            NosmaiBeauty.removeMakeup(category)
        }, result)
    }

    private fun handleHasMakeup(category: Int, result: Result) {
        try {
            result.success(NosmaiBeauty.isMakeupActive(category))
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "hasMakeup error: ${t.message}", t)
            result.success(false)
        }
    }

    private fun handleApplyMakeupBlendLevel(call: MethodCall, result: Result) {
        try {
            if (!isSdkInitialized) {
                result.error("FILTER_ERROR", "SDK not initialized.", null)
                return
            }

            val filterName = call.argument<String>("filterName") ?: ""
            val level = call.argument<Number>("level")?.toDouble() ?: 0.0

            when (filterName.lowercase()) {
                "lipstickfilter", "lipstick" -> {
                    NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_LIPSTICK, normalizedUnit(level))
                }
                "blusherfilter", "blusher" -> {
                    NosmaiBeauty.setMakeupIntensity(NosmaiBeauty.MAKEUP_BLUSHER, normalizedUnit(level))
                }
                "skinsmoothing", "smoothing" -> {
                    val normalized = (level / 100.0).coerceIn(0.0, 1.0)
                    NosmaiBeauty.applySkinSmoothing(normalized.toFloat())
                }
                "skinwhitening", "whitening" -> {
                    val normalized = (level / 100.0).coerceIn(0.0, 1.0)
                    NosmaiBeauty.applySkinWhitening(normalized.toFloat())
                }
                else -> {
                    NosmaiLog.w(TAG, "Unknown makeup filter: $filterName")
                    result.error("FILTER_ERROR", "Unsupported makeup filter: $filterName", null)
                    return
                }
            }

            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "MakeupBlendLevel error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleRemoveBuiltInBeautyFilters(result: Result) {
        executeBeautyFilter("RemoveAllBeautyFilters", {
            NosmaiBeauty.clearAllBeautyFilters()
        }, result)
    }

    private fun handleRemoveBuiltInFilterByName(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val name = call.argument<String>("filterName")?.lowercase().orEmpty()
        executeBeautyFilter("RemoveBuiltInFilterByName", {
            when {
                name.contains("lip") -> NosmaiBeauty.removeMakeup(NosmaiBeauty.MAKEUP_LIPSTICK)
                name.contains("eye") && name.contains("shadow") -> NosmaiBeauty.removeMakeup(NosmaiBeauty.MAKEUP_EYESHADOW)
                name.contains("lash") -> NosmaiBeauty.removeMakeup(NosmaiBeauty.MAKEUP_EYELASH)
                name.contains("brow") -> NosmaiBeauty.removeMakeup(NosmaiBeauty.MAKEUP_EYEBROW)
                name.contains("blush") -> NosmaiBeauty.removeMakeup(NosmaiBeauty.MAKEUP_BLUSHER)
                else -> NosmaiBeauty.clearAllBeautyFilters()
            }
        }, result)
    }

    private fun handleSetFaceSlimLevel(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val level = normalizedUnit(call.argument<Number>("level"), 0.0)
        executeBeautyFilter("FaceSlimMorph", {
            NosmaiBeauty.applyMorphFaceSlim(level)
        }, result)
    }

    private fun handleSetEyeSizeLevel(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val level = normalizedUnit(call.argument<Number>("level"), 0.0)
        executeBeautyFilter("EyeSizeMorph", {
            NosmaiBeauty.applyMorphEyeSize(level)
        }, result)
    }

    private fun handleSetNoseSlimLevel(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val level = normalizedUnit(call.argument<Number>("level"), 0.0)
        executeBeautyFilter("NoseSlimMorph", {
            NosmaiBeauty.applyMorphNoseSlim(level)
        }, result)
    }

    private fun handleRemoveAllMorphing(result: Result) {
        if (!requireSdkReady(result)) return
        executeBeautyFilter("RemoveAllMorphing", {
            NosmaiBeauty.clearReshapes()
        }, result)
    }

    private fun handleSetEyeColor(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return
            val r = normalizedUnit(call.argument<Number>("r"), 0.3)
            val g = normalizedUnit(call.argument<Number>("g"), 0.6)
            val b = normalizedUnit(call.argument<Number>("b"), 1.0)
            val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)

            com.nosmai.effect.internal.Nosmai.enableEyeColoringFilter(true)
            com.nosmai.effect.internal.Nosmai.setEyeColor(r, g, b)
            com.nosmai.effect.internal.Nosmai.setEyeColorIntensity(intensity)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setEyeColor error: ${t.message}", t)
            result.success(false)
        }
    }

    private fun handleSetEyeColorIntensity(call: MethodCall, result: Result) {
        if (!requireSdkReady(result)) return
        val intensity = normalizedUnit(call.argument<Number>("intensity"), 0.5)
        executeBeautyFilter("SetEyeColorIntensity", {
            com.nosmai.effect.internal.Nosmai.setEyeColorIntensity(intensity)
        }, result)
    }

    private fun handleRemoveEyeColoring(result: Result) {
        if (!requireSdkReady(result)) return
        executeBeautyFilter("RemoveEyeColoring", {
            com.nosmai.effect.internal.Nosmai.enableEyeColoringFilter(false)
        }, result)
    }

    private fun handleRemoveAllMakeup(result: Result) {
        if (!requireSdkReady(result)) return
        executeBeautyFilter("RemoveAllMakeup", {
            NosmaiBeauty.removeMakeup(NosmaiBeauty.MAKEUP_ALL)
        }, result)
    }

    private fun handleRemoveAllBeautyEffects(result: Result) {
        if (!requireSdkReady(result)) return
        executeBeautyFilter("RemoveAllBeautyEffects", {
            NosmaiBeauty.clearAllBeautyFilters()
        }, result)
    }

    private fun handleResetHSBFilter(result: Result) {
        if (!isSdkInitialized) {
            result.error("FILTER_ERROR", "SDK not initialized.", null)
            return
        }
        // Reset HSB by applying default values (hue=0)
        executeBeautyFilter("ResetHSBFilter", {
            NosmaiBeauty.applyHue(0f)
        }, result)
    }

    private fun handleAdjustHSB(call: MethodCall, result: Result) {
        if (!isSdkInitialized) {
            result.error("FILTER_ERROR", "SDK not initialized.", null)
            return
        }
        val hue = call.argument<Number>("hue")?.toDouble() ?: 0.0
        val saturation = call.argument<Number>("saturation")?.toDouble() ?: 1.0
        val brightness = call.argument<Number>("brightness")?.toDouble() ?: 1.0

        // Android SDK doesn't have combined HSB adjust, so we apply hue only
        // Saturation and brightness would need custom implementation
        NosmaiLog.d(TAG, "Adjusting HSB - hue: $hue, saturation: $saturation, brightness: $brightness")
        executeBeautyFilter("AdjustHSB", {
            NosmaiBeauty.applyHue(hue.toFloat())
        }, result)
    }

    private fun handleApplyWhiteBalance(call: MethodCall, result: Result) {
        try {
            if (!isSdkInitialized) {
                result.error("FILTER_ERROR", "SDK not initialized.", null)
                return
            }
            val temperature = call.argument<Number>("temperature")?.toDouble() ?: 5000.0
            val tint = call.argument<Number>("tint")?.toDouble() ?: 0.0

            NosmaiBeauty.applyWhiteBalance(temperature.toFloat(), tint.toFloat())
            result.success(null)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "applyWhiteBalance error: ${t.message}", t)
            result.error("FILTER_ERROR", t.message, null)
        }
    }

    private fun handleIsCloudFilterEnabled(result: Result) {
        try {
            result.success(NosmaiCloud.isEnabled())
        } catch (t: Throwable) { result.success(false) }
    }

    private fun handleIsBeautyEffectEnabled(result: Result) {
        try {
            // Check if beauty features are enabled by license
            // This matches iOS behavior: checks license feature enablement
            val isEnabled = com.nosmai.effect.internal.Nosmai.isBeautyEnabled()
            NosmaiLog.d(TAG, "isBeautyEffectEnabled called: $isEnabled")
            result.success(isEnabled)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "isBeautyEffectEnabled error: ${t.message}", t)
            result.success(false)
        }
    }

    private fun handleSetBackgroundSegmentation(call: MethodCall, result: Result) {
        try {
            if (!requireSdkReady(result)) return

            val modeArg = call.argument<String>("mode")?.lowercase().orEmpty()
            val config = NosmaiBackgroundSegmentationConfig()
            config.mode = when (modeArg) {
                "color" -> NosmaiBackgroundSegmentationConfig.Mode.COLOR
                "image" -> NosmaiBackgroundSegmentationConfig.Mode.IMAGE
                "video" -> NosmaiBackgroundSegmentationConfig.Mode.VIDEO
                "blur" -> NosmaiBackgroundSegmentationConfig.Mode.BLUR
                else -> NosmaiBackgroundSegmentationConfig.Mode.COLOR
            }

            config.blurStrength = call.argument<Number>("blurStrength")?.toFloat() ?: config.blurStrength

            val r = normalizedUnit(call.argument<Number>("colorRed"), 0.0)
            val g = normalizedUnit(call.argument<Number>("colorGreen"), 1.0)
            val b = normalizedUnit(call.argument<Number>("colorBlue"), 0.0)
            val a = normalizedUnit(call.argument<Number>("colorAlpha"), 1.0)
            config.replacementColor = Color.argb(
                (a * 255f).toInt(),
                (r * 255f).toInt(),
                (g * 255f).toInt(),
                (b * 255f).toInt()
            )

            val imageData = call.argument<ByteArray>("imageData")
            if (imageData != null && imageData.isNotEmpty()) {
                config.replacementImage = android.graphics.BitmapFactory.decodeByteArray(imageData, 0, imageData.size)
            }

            config.replacementVideoPath = call.argument<String>("videoPath")

            NosmaiEffects.setBackgroundSegmentation(config)
            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setBackgroundSegmentation error", t)
            result.success(false)
        }
    }

    private fun handleClearBackgroundSegmentation(result: Result) {
        try {
            if (!requireSdkReady(result)) return
            NosmaiEffects.clearBackgroundSegmentation()
            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "clearBackgroundSegmentation error", t)
            result.success(false)
        }
    }

    private fun mapCategoryToFilterType(cat: String?): String {
        val c = cat?.trim()?.lowercase()?.replace('-', '_') ?: ""
        return when (c) {
            "fx_and_filters", "filter" -> "filter"
            "special_effects", "effect" -> "effect"
            "beauty", "beauty_effects", "beauty_effect", "makeup" -> "beauty_effect"
            "background", "backgrounds", "bg" -> "background"
            "game", "games" -> "game"
            else -> "effect"
        }
    }

    private fun handleGetCloudFilters(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val filterTypeArg = call.argument<String>("filterType")?.trim()?.takeIf { it.isNotEmpty() }
                val versionArg = call.argument<String>("version")
                val pageArg = call.argument<Number>("page")?.toInt()
                val limitArg = call.argument<Number>("limit")?.toInt()
                val fetchAllPagesArg = call.argument<Boolean>("fetchAllPages")
                val query = NosmaiCloud.FilterQuery().apply {
                    page = (pageArg ?: 1).coerceAtLeast(1)
                    limit = (limitArg ?: 20).coerceAtLeast(1)
                    version = parseCloudFilterVersion(versionArg)
                    filterType = normalizeCloudFilterType(filterTypeArg)
                    fetchAllPages = fetchAllPagesArg ?: (pageArg == null)
                    cleanupRemoved = false
                }

                val fetchOk = NosmaiCloud.fetch(query)
                val list = NosmaiCloud.cachedList()
                val pagination = NosmaiCloud.pagination()
                val requestedOutputType = when (query.filterType) {
                    "effects" -> "effect"
                    "filter" -> "filter"
                    "bg" -> "background"
                    "beauty_effect" -> "beauty_effect"
                    "games" -> "game"
                    else -> null
                }
                val out = ArrayList<Map<String, Any?>>()
                for (it in list) {
                    val id = it.id
                    val name = it.name
                    val displayName = toTitleCase(if (name.isNotBlank()) name else id)
                    val type = "cloud"
                    val downloaded = it.isDownloaded
                    val localPath = it.localPath
                    // A filtered endpoint is authoritative. Category is a display
                    // grouping (for example "Makeup"), not always the package type.
                    val filterType = requestedOutputType
                        ?: mapCategoryToFilterType(it.category)
                    val fileSize = try {
                        if (downloaded && localPath.isNotBlank()) File(localPath).length().toInt() else 0
                    } catch (_: Throwable) {
                        0
                    }

                    val m = HashMap<String, Any?>()
                    m["id"] = id
                    m["filterId"] = id
                    m["name"] = name
                    m["displayName"] = displayName
                    m["type"] = type
                    m["filterType"] = filterType
                    m["isDownloaded"] = downloaded
                    m["fileSize"] = fileSize
                    m["isFree"] = true

                    if (downloaded && localPath.isNotBlank()) {
                        m["path"] = localPath
                        m["localPath"] = localPath
                        try {
                            val bmp = com.nosmai.effect.NosmaiFilterManager.loadPreviewImageForFilter(localPath)
                            if (bmp != null) {
                                m["previewImageBase64"] = bitmapToBase64(bmp)
                            }
                        } catch (_: Throwable) {}
                    }

                    if (it.thumbnailUrl.isNotBlank()) {
                        m["previewUrl"] = it.thumbnailUrl
                        m["thumbnailUrl"] = it.thumbnailUrl
                    }

                    out.add(m)
                }
                mainHandler.post {
                    result.success(mapOf(
                        "filters" to out,
                        "pagination" to mapOf(
                            "currentPage" to pagination.currentPage,
                            "totalPages" to pagination.totalPages,
                            "totalItems" to pagination.totalFilters,
                            "itemsPerPage" to pagination.limit,
                            "hasNextPage" to pagination.hasNextPage,
                            "hasPreviousPage" to pagination.hasPreviousPage
                        ),
                        "success" to fetchOk
                    ))
                }
            } catch (t: Throwable) {
                mainHandler.post {
                    result.error("CLOUD_FILTERS_ERROR", t.message, null)
                }
            }
        }
    }

    private fun normalizeCloudFilterType(type: String?): String? {
        val normalized = type?.trim()?.lowercase()?.replace('_', '-') ?: return null
        return when (normalized) {
            "", "all" -> null
            "effect", "effects", "special-effect", "special-effects" -> "effects"
            "filter", "filters", "fx-and-filter", "fx-and-filters", "cloud-filter", "cloud-filters" -> "filter"
            "background", "backgrounds", "bg" -> "bg"
            "beauty", "beauty-effect", "beauty-effects", "beautyeffect" -> "beauty_effect"
            "game", "games" -> "games"
            else -> normalized
        }
    }

    private fun handleDownloadCloudFilter(call: MethodCall, result: Result) {
        val filterId = call.argument<String>("filterId")
        if (filterId.isNullOrBlank()) { result.error("ARG_ERROR", "filterId required", null); return }

        val waiters = cloudDownloadWaiters.computeIfAbsent(filterId) {
            CopyOnWriteArrayList()
        }
        waiters.add(result)
        if (waiters.size > 1) return

        try {
            backgroundExecutor.execute {
                try {
                    val latch = java.util.concurrent.CountDownLatch(1)
                    var ok = false
                    var path: String? = null
                    NosmaiCloud.download(filterId, object : NosmaiCloud.DownloadCallback {
                        override fun onComplete(id: String, success: Boolean, localPath: String?, error: String?) {
                            ok = success
                            path = localPath
                            latch.countDown()
                        }
                    })
                    val completed = latch.await(60, TimeUnit.SECONDS)
                    val map = HashMap<String, Any?>()
                    map["success"] = completed && ok
                    if (completed && ok && !path.isNullOrBlank()) {
                        map["path"] = path
                        map["localPath"] = path
                    } else {
                        map["error"] = if (!completed) {
                            "Cloud filter download timed out"
                        } else {
                            "Cloud filter download failed"
                        }
                    }

                    completeCloudDownload(filterId, map)
                } catch (t: Throwable) {
                    completeCloudDownload(
                        filterId,
                        mapOf("success" to false, "error" to "Cloud filter download failed")
                    )
                }
            }
        } catch (t: Throwable) {
            completeCloudDownload(
                filterId,
                mapOf("success" to false, "error" to "Cloud filter download unavailable")
            )
        }
    }

    private fun completeCloudDownload(filterId: String, response: Map<String, Any?>) {
        mainHandler.post {
            val callbacks = cloudDownloadWaiters.remove(filterId) ?: return@post
            if (!isEngineAttached) return@post
            callbacks.forEach { callback ->
                callback.success(response)
            }
        }
    }

    private fun handleRemoveCloudFilter(call: MethodCall, result: Result) {
        val filterId = call.argument<String>("filterId")
        if (filterId.isNullOrBlank()) {
            result.error("ARG_ERROR", "filterId required", null)
            return
        }

        try {
            var removed = false
            val downloadedPaths = linkedSetOf<String>()
            try {
                com.nosmai.effect.internal.NosmaiCloudFilter
                    .getFilterLocalPath(filterId)
                    ?.takeIf { it.isNotBlank() }
                    ?.let(downloadedPaths::add)
            } catch (_: Throwable) {}
            try {
                NosmaiCloud.cachedList()
                    .firstOrNull { it.id.equals(filterId, ignoreCase = true) }
                    ?.localPath
                    ?.takeIf { it.isNotBlank() }
                    ?.let(downloadedPaths::add)
            } catch (_: Throwable) {}
            downloadedPaths.forEach { downloadedPath ->
                try {
                    val file = File(downloadedPath)
                    val canonical = file.canonicalFile
                    val allowedRoots = listOf(
                        context.filesDir.canonicalFile,
                        context.cacheDir.canonicalFile
                    )
                    val insideAppStorage = allowedRoots.any { root ->
                        canonical.path == root.path ||
                            canonical.path.startsWith(root.path + File.separator)
                    }
                    if (insideAppStorage && canonical.exists()) {
                        removed = canonical.delete() || removed
                    }
                } catch (_: Throwable) {}
            }
            listOf(
                File(context.filesDir, "cloud_filters"),
                File(context.cacheDir, "cloud_filters"),
                File(context.cacheDir, "NosmaiCloudFilters"),
                File(context.cacheDir, CACHE_DIR_NAME)
            ).forEach { dir ->
                if (!dir.exists() || !dir.isDirectory) return@forEach
                dir.listFiles()?.forEach { file ->
                    if (file.name.contains(filterId, ignoreCase = true)) {
                        removed = file.delete() || removed
                    }
                }
            }
            result.success(removed)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "removeCloudFilter error", t)
            result.error("REMOVE_CLOUD_FILTER_ERROR", t.message, null)
        }
    }

    private fun handleGetFilters(call: MethodCall, result: Result) {
        try {
            updateFlutterAssetPaths(call)
            result.success(getNosmaiFilters())
        } catch (t: Throwable) {
            result.error("GET_FILTERS_ERROR", t.message, null)
        }
    }

    private fun handleClearRenderSurface(result: Result) {
        try {
            try { NosmaiSDK.clearRenderSurface() } catch (_: Throwable) {}

            surface?.release()
            surface = null
            oesReadySurfaceTexture = null
            oesReadyView = null

            surfaceReboundOnce = false
            isSurfaceReady = false
            pendingStartProcessing = false
            cleanupInProgress = true
            lastCleanupAtMs = System.currentTimeMillis()
            Handler(Looper.getMainLooper()).postDelayed({ cleanupInProgress = false }, 700)

            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "clearRenderSurface error", t)
            result.success(false)
        }
    }

    // --- Photo Capture and Gallery Functions ---
    /**
     * Helper function to save captured photo to temporary file and build result map
     * @param imageData JPEG compressed image bytes
     * @param width Image width
     * @param height Image height
     * @return Map with success, imageData, imagePath, width, height
     */
    private fun buildCapturePhotoResult(imageData: ByteArray, width: Int, height: Int): Map<String, Any?> {
        return try {
            val tempFile = File(context.cacheDir, "nosmai_photo_${System.currentTimeMillis()}.jpg")
            FileOutputStream(tempFile).use { it.write(imageData) }

            hashMapOf(
                "success" to true,
                "width" to width,
                "height" to height,
                "imageData" to imageData,
                "imagePath" to tempFile.absolutePath
            )
        } catch (e: Throwable) {
            NosmaiLog.e(TAG, "Failed to save photo to temp file", e)
            hashMapOf(
                "success" to true,
                "width" to width,
                "height" to height,
                "imageData" to imageData,
                "imagePath" to null
            )
        }
    }

    private fun handleCapturePhoto(result: Result) {
        try {
            if (usingPlatformView) {
                val pvLocal = previewView
                if (pvLocal == null) {
                    result.success(mapOf("success" to false, "error" to "Preview not ready")); return
                }
                val tv = findTextureView(pvLocal)
                if (tv != null) {
                    try {
                        val bmp = tv.bitmap
                        if (bmp != null) {
                            Thread {
                                try {
                                    val baos = ByteArrayOutputStream()
                                    bmp.compress(Bitmap.CompressFormat.JPEG, 85, baos)
                                    val data = baos.toByteArray()
                                    val map = buildCapturePhotoResult(data, bmp.width, bmp.height)
                                    Handler(Looper.getMainLooper()).post { result.success(map) }
                                } catch (e: Throwable) {
                                    Handler(Looper.getMainLooper()).post { result.success(mapOf("success" to false, "error" to e.message)) }
                                }
                            }.start()
                            return
                        }
                    } catch (e: Throwable) { NosmaiLog.w(TAG, "TextureView capture failed", e) }
                }
                val sv = findSurfaceView(pvLocal)
                if (sv != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    try {
                        val w = if (sv.width > 0) sv.width else (pendingSurfaceWidth ?: 720)
                        val h = if (sv.height > 0) sv.height else (pendingSurfaceHeight ?: 1280)
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        android.view.PixelCopy.request(sv, bmp, android.view.PixelCopy.OnPixelCopyFinishedListener { copyResult ->
                            if (copyResult == android.view.PixelCopy.SUCCESS) {
                                Thread {
                                    try {
                                        val baos = ByteArrayOutputStream()
                                        bmp.compress(Bitmap.CompressFormat.JPEG, 85, baos)
                                        val data = baos.toByteArray()
                                        val map = buildCapturePhotoResult(data, bmp.width, bmp.height)
                                        Handler(Looper.getMainLooper()).post { result.success(map) }
                                    } catch (e: Throwable) {
                                        Handler(Looper.getMainLooper()).post { result.success(mapOf("success" to false, "error" to e.message)) }
                                    }
                                }.start()
                            } else {
                                val fw = w; val fh = h
                                captureUsingOpenGL(fw, fh, result)
                            }
                        }, Handler(Looper.getMainLooper()))
                        return
                    } catch (e: Throwable) { NosmaiLog.w(TAG, "SurfaceView PixelCopy failed", e) }
                }
                val w = pendingSurfaceWidth ?: pvLocal.width.takeIf { it > 0 } ?: 720
                val h = pendingSurfaceHeight ?: pvLocal.height.takeIf { it > 0 } ?: 1280
                captureUsingOpenGL(w, h, result)
                return
            }

            val surf = surface
            val entry = textureEntry
            if (surf == null || entry == null) {
                result.success(mapOf("success" to false, "error" to "Surface not initialized for capture"))
                return
            }
            val width = pendingSurfaceWidth ?: 720
            val height = pendingSurfaceHeight ?: 1280
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                try {
                    android.view.PixelCopy.request(surf, bitmap, { copyResult ->
                        if (copyResult == android.view.PixelCopy.SUCCESS) {
                            Thread {
                                try {
                                    val baos = ByteArrayOutputStream()
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 80, baos)
                                    val imageData = baos.toByteArray()
                                    val resultMap = buildCapturePhotoResult(imageData, bitmap.width, bitmap.height)
                                    Handler(Looper.getMainLooper()).post { result.success(resultMap) }
                                } catch (e: Throwable) {
                                    Handler(Looper.getMainLooper()).post { result.success(mapOf("success" to false, "error" to "Failed to process image: ${e.message}")) }
                                }
                            }.start()
                        } else {
                            captureUsingOpenGL(width, height, result)
                        }
                    }, Handler(Looper.getMainLooper()))
                } catch (e: Throwable) {
                    NosmaiLog.e(TAG, "PixelCopy error", e)
                    captureUsingOpenGL(width, height, result)
                }
            } else {
                captureUsingOpenGL(width, height, result)
            }
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "capturePhoto error", t)
            result.success(mapOf(
                "success" to false,
                "error" to "Failed to capture photo: ${t.message}"
            ))
        }
    }

    private fun captureUsingOpenGL(width: Int, height: Int, result: Result) {
        try {
            val buffer = java.nio.ByteBuffer.allocateDirect(width * height * 4)
            buffer.order(java.nio.ByteOrder.nativeOrder())

            android.opengl.GLES20.glReadPixels(0, 0, width, height,
                android.opengl.GLES20.GL_RGBA,
                android.opengl.GLES20.GL_UNSIGNED_BYTE,
                buffer)

            buffer.rewind()

            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            bitmap.copyPixelsFromBuffer(buffer)

            val matrix = android.graphics.Matrix()
            matrix.postScale(1f, -1f, width / 2f, height / 2f)
            val flippedBitmap = Bitmap.createBitmap(bitmap, 0, 0, width, height, matrix, true)

            Thread {
                try {
                    val baos = ByteArrayOutputStream()
                    flippedBitmap.compress(Bitmap.CompressFormat.JPEG, 80, baos)
                    val imageData = baos.toByteArray()

                    val resultMap = buildCapturePhotoResult(imageData, flippedBitmap.width, flippedBitmap.height)

                    Handler(Looper.getMainLooper()).post {
                        result.success(resultMap)
                    }
                } catch (e: Throwable) {
                    Handler(Looper.getMainLooper()).post {
                        result.success(mapOf(
                            "success" to false,
                            "error" to "Failed to process captured image: ${e.message}"
                        ))
                    }
                }
            }.start()
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "OpenGL capture error", t)
            result.success(mapOf(
                "success" to false,
                "error" to "Failed to capture using OpenGL: ${t.message}"
            ))
        }
    }

    private fun findTextureView(root: android.view.View): android.view.TextureView? {
        if (root is android.view.TextureView) return root
        if (root is android.view.ViewGroup) {
            for (i in 0 until root.childCount) {
                val child = root.getChildAt(i)
                val found = findTextureView(child)
                if (found != null) return found
            }
        }
        return null
    }

    private fun findSurfaceView(root: android.view.View): android.view.SurfaceView? {
        if (root is android.view.SurfaceView) return root
        if (root is android.view.ViewGroup) {
            for (i in 0 until root.childCount) {
                val child = root.getChildAt(i)
                val found = findSurfaceView(child)
                if (found != null) return found
            }
        }
        return null
    }

    private fun handleSaveImageToGallery(call: MethodCall, result: Result) {
        try {
            val imageData = call.argument<ByteArray>("imageData")
            val imageName = call.argument<String>("name") ?: "nosmai_photo_${System.currentTimeMillis()}"

            if (imageData == null) {
                result.error("INVALID_ARGUMENTS", "Image data is required", null)
                return
            }

            val bitmap = android.graphics.BitmapFactory.decodeByteArray(imageData, 0, imageData.size)
            if (bitmap == null) {
                result.error("INVALID_IMAGE", "Could not create image from data", null)
                return
            }

            val saved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveImageToGalleryQ(bitmap, imageName)
            } else {
                saveImageToGalleryLegacy(bitmap, imageName)
            }

            if (saved) {
                result.success(mapOf(
                    "isSuccess" to true,
                    "message" to "Image saved to gallery"
                ))
            } else {
                result.error("SAVE_FAILED", "Failed to save image to gallery", null)
            }
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "saveImageToGallery error", t)
            result.error("SAVE_ERROR", "Error saving image: ${t.message}", null)
        }
    }

    private fun handleSaveVideoToGallery(call: MethodCall, result: Result) {
        try {
            val videoPath = call.argument<String>("videoPath")
            val videoName = call.argument<String>("name") ?: "nosmai_video_${System.currentTimeMillis()}"

            if (videoPath == null) {
                result.error("INVALID_ARGUMENTS", "Video path is required", null)
                return
            }

            val videoFile = File(videoPath)
            if (!videoFile.exists()) {
                result.error("FILE_NOT_FOUND", "Video file not found", null)
                return
            }

            val saved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveVideoToGalleryQ(videoFile, videoName)
            } else {
                saveVideoToGalleryLegacy(videoFile, videoName)
            }

            if (saved) {
                result.success(mapOf(
                    "isSuccess" to true,
                    "message" to "Video saved to gallery"
                ))
            } else {
                result.error("SAVE_FAILED", "Failed to save video to gallery", null)
            }
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "saveVideoToGallery error", t)
            result.error("SAVE_ERROR", "Error saving video: ${t.message}", null)
        }
    }

    private fun saveImageToGalleryQ(bitmap: Bitmap, imageName: String): Boolean {
        val resolver = context.contentResolver
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "$imageName.jpg")
            put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Nosmai")
        }

        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
        return if (uri != null) {
            try {
                resolver.openOutputStream(uri)?.use { outputStream ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
                }
                true
            } catch (e: IOException) {
                NosmaiLog.e(TAG, "Failed to save image", e)
                false
            }
        } else {
            false
        }
    }

    private fun saveImageToGalleryLegacy(bitmap: Bitmap, imageName: String): Boolean {
        val picturesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
        val nosmaiDir = File(picturesDir, "Nosmai")
        if (!nosmaiDir.exists()) {
            nosmaiDir.mkdirs()
        }

        val imageFile = File(nosmaiDir, "$imageName.jpg")
        return try {
            FileOutputStream(imageFile).use { outputStream ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 90, outputStream)
            }

            MediaScannerConnection.scanFile(
                context,
                arrayOf(imageFile.absolutePath),
                arrayOf("image/jpeg"),
                null
            )

            true
        } catch (e: IOException) {
            NosmaiLog.e(TAG, "Failed to save image", e)
            false
        }
    }

    private fun saveVideoToGalleryQ(videoFile: File, videoName: String): Boolean {
        val resolver = context.contentResolver
        val contentValues = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "$videoName.mp4")
            put(MediaStore.MediaColumns.MIME_TYPE, "video/mp4")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/Nosmai")
        }

        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)
        return if (uri != null) {
            try {
                resolver.openOutputStream(uri)?.use { outputStream ->
                    videoFile.inputStream().use { inputStream ->
                        inputStream.copyTo(outputStream)
                    }
                }
                true
            } catch (e: IOException) {
                NosmaiLog.e(TAG, "Failed to save video", e)
                false
            }
        } else {
            false
        }
    }

    private fun saveVideoToGalleryLegacy(videoFile: File, videoName: String): Boolean {
        val moviesDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES)
        val nosmaiDir = File(moviesDir, "Nosmai")
        if (!nosmaiDir.exists()) {
            nosmaiDir.mkdirs()
        }

        val destFile = File(nosmaiDir, "$videoName.mp4")
        return try {
            videoFile.copyTo(destFile, overwrite = true)

            MediaScannerConnection.scanFile(
                context,
                arrayOf(destFile.absolutePath),
                arrayOf("video/mp4"),
                null
            )

            true
        } catch (e: IOException) {
            NosmaiLog.e(TAG, "Failed to save video", e)
            false
        }
    }

    // --- SDK Cleanup and Management ---
    private fun handleCleanup(result: Result) {
        try {
            if (isSdkInitialized) {
                try {
                    cleanupInProgress = true
                    lastCleanupAtMs = System.currentTimeMillis()
                    if (isProcessingActive) {
                        NosmaiSDK.stopProcessing()
                        isProcessingActive = false
                    }

                    stopCameraHelper(true)

                    NosmaiEffects.removeEffect()
                    NosmaiBeauty.removeAllBeautyFilters()

                    NosmaiSDK.clearRenderSurface()

                    surfaceReboundOnce = false

                    if (isRecording) {
                        try {
                            com.nosmai.effect.api.NosmaiSDK.stopRecording(object : com.nosmai.effect.api.NosmaiSDK.RecordingCallback {
                                override fun onCompleted(outputPath: String?, success: Boolean, error: String?) {
                                }
                            })
                            isRecording = false
                        } catch (_: Throwable) {}
                    }
                } catch (e: Throwable) {
                    NosmaiLog.w(TAG, "Cleanup warning", e)
                }
            }


            result.success(null)
            Handler(Looper.getMainLooper()).postDelayed({ cleanupInProgress = false }, 700)
        } catch (t: Throwable) {
            result.error("CLEANUP_ERROR", t.message, null)
        }
    }

    private fun handleDispose(result: Result) {
        try {
            NosmaiLog.d(TAG, "🗑️ handleDispose: Full plugin disposal")
            cleanupInProgress = true
            setGameEventsEnabled(false)

            try {
                // 1. Stop camera hardware first
                stopCameraHelper(true)
                NosmaiLog.d(TAG, "   ✓ Camera stopped")
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ Camera stop warning: ${e.message}")
            }

            try {
                // 2. Stop processing if active
                if (isProcessingActive) {
                    NosmaiSDK.stopProcessing()
                    isProcessingActive = false
                    NosmaiLog.d(TAG, "   ✓ Processing stopped")
                }
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ Stop processing warning: ${e.message}")
            }

            try {
                // 3. Stop recording if active
                if (isRecording) {
                    NosmaiSDK.stopRecording(object : NosmaiSDK.RecordingCallback {
                        override fun onCompleted(outputPath: String?, success: Boolean, error: String?) {
                            NosmaiLog.d(TAG, "   ✓ Recording stopped during dispose")
                        }
                    })
                    isRecording = false
                }
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ Stop recording warning: ${e.message}")
            }

            try {
                // 4. Remove all filters and effects
                NosmaiEffects.removeEffect()
                NosmaiBeauty.removeAllBeautyFilters()
                NosmaiLog.d(TAG, "   ✓ Filters removed")
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ Filter removal warning: ${e.message}")
            }

            try {
                // 5. Clear render surface
                NosmaiSDK.clearRenderSurface()
                NosmaiLog.d(TAG, "   ✓ Render surface cleared")
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ Surface clear warning: ${e.message}")
            }

            try {
                // 6. Release texture entry and surface
                surface?.release()
                surface = null
                textureEntry?.release()
                textureEntry = null
                NosmaiLog.d(TAG, "   ✓ Texture/Surface released")
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ Texture release warning: ${e.message}")
            }

            try {
                // 7. Full SDK cleanup - this releases native resources
                if (isSdkInitialized) {
                    NosmaiSDK.cleanup()
                    NosmaiLog.d(TAG, "   ✓ SDK cleanup completed")
                }
            } catch (e: Throwable) {
                NosmaiLog.w(TAG, "   ⚠️ SDK cleanup warning: ${e.message}")
            }

            // 8. Reset all plugin state flags
            isProcessingActive = false
            pendingStartProcessing = false
            isSdkInitialized = false
            usingPlatformView = false
            surfaceReboundOnce = false
            oesReadySurfaceTexture = null
            oesReadyView = null
            oesListenersBoundView = null

            // 9. Clear view references
            previewView = null
            platformContainer = null
            switchOverlayView = null

            NosmaiLog.d(TAG, "✅ Full disposal complete")
            result.success(null)

        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "dispose error", t)
            result.error("DISPOSE_ERROR", t.message, null)
        } finally {
            // Reset cleanup flag immediately - no delay needed for full disposal
            cleanupInProgress = false
        }
    }

    private fun attemptDeferredStart() {
        if (!pendingStartProcessing) {
            return
        }
        if (usingPlatformView) {
            cleanupInProgress = false
        } else if (cleanupInProgress) {
            return
        }

        if (isProcessingActive) {
            pendingStartProcessing = false
            if (!isCameraRunning) {
                ensureCameraPermissionThenStart()
            }
            return
        }

        val pv = previewView ?: return

        if (usingPlatformView) {
            NosmaiLog.i(
                TAG,
                "Attempting PlatformView start: sdk=$isSdkInitialized processing=$isProcessingActive camera=$isCameraRunning"
            )
            if (!isSdkInitialized) {
                NosmaiLog.i(TAG, "PlatformView start deferred until Nosmai SDK initializes")
                Handler(Looper.getMainLooper()).postDelayed({
                    try { attemptDeferredStart() } catch (_: Throwable) {}
                }, 100)
                return
            }
            try {
                try { pv.initializePipeline() } catch (_: Throwable) {}
                NosmaiSDK.startProcessing(pv)
                isProcessingActive = true
                cameraReadyNotified = false
                try { NosmaiSDK.setCameraFacing(isFrontCamera) } catch (_: Throwable) {}
                try { NosmaiSDK.setMirrorX(isFrontCamera) } catch (_: Throwable) {}
                ensureCameraPermissionThenStart()
                try { pv.requestRenderUpdate() } catch (_: Throwable) {}
            } catch (e: Throwable) {
                isProcessingActive = false
                NosmaiLog.e(TAG, "PlatformView deferred start error", e)
            } finally {
                pendingStartProcessing = false
            }
            return
        }
        if (isSurfaceReady && surface?.isValid == true) {
            try {
                NosmaiSDK.startProcessing(pv)
                isProcessingActive = true
                cameraReadyNotified = false
                ensureCameraPermissionThenStart()
            } catch (e: Throwable) {
                NosmaiLog.e(TAG, "attemptDeferredStart (texture) error", e)
            } finally {
                pendingStartProcessing = false
            }
        }
    }

    private fun handleClearFilterCache(result: Result) {
        try {
            clearFilterCache()
            result.success(true)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Clear filter cache error", t)
            result.error("CLEAR_CACHE_ERROR", t.message, null)
        }
    }

    private fun handleValidateLocalFilters(call: MethodCall, result: Result) {
        try {
            updateFlutterAssetPaths(call)
            val filters = getNosmaiFilters()
            val validations = filters.map { filter ->
                val path = filter["path"]?.toString()
                val name = filter["name"]?.toString().orEmpty()
                val errors = mutableListOf<String>()
                val warnings = mutableListOf<String>()

                if (name.isBlank()) warnings.add("Missing filter name")
                if (path.isNullOrBlank()) {
                    errors.add("Missing .nosmai path")
                } else if (!File(path).exists()) {
                    errors.add(".nosmai file not found")
                }
                if (filter["hasPreview"] != true) warnings.add("Missing preview image")

                mapOf(
                    "folderName" to name,
                    "isValid" to errors.isEmpty(),
                    "errors" to errors,
                    "warnings" to warnings,
                    "nosmaiPath" to path,
                    "manifestPath" to null,
                    "previewPath" to null
                )
            }
            result.success(validations)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "validateLocalFilters error", t)
            result.error("VALIDATE_FILTERS_ERROR", t.message, null)
        }
    }

    private fun clearFilterCache() {
        try {
            val cacheDir = File(context.cacheDir, CACHE_DIR_NAME)
            if (cacheDir.exists() && cacheDir.isDirectory) {
                cacheDir.listFiles()?.forEach { file ->
                    if (file.name.endsWith(".nosmai")) {
                        file.delete()
                    }
                }
            }

            val cloudCacheDir = File(context.filesDir, "cloud_filters")
            if (cloudCacheDir.exists() && cloudCacheDir.isDirectory) {
                cloudCacheDir.listFiles()?.forEach { file ->
                    file.delete()
                }
            }
        } catch (e: Exception) {
            NosmaiLog.w(TAG, "Failed to clear filter cache", e)
        }
    }

    private fun handleReinitializePreview(result: Result) {
        try {
            if (usingPlatformView) {
                try {
                    runOnMain {
                        try {
                            val container = platformContainer
                            if (container != null) {
                                try {
                                    previewView?.let { old -> container.removeView(old) }
                                } catch (_: Throwable) {}
                                oesReadySurfaceTexture = null
                                oesReadyView = null
                                oesListenersBoundView = null
                                val ctx = container.context
                                val newPv = NosmaiPreviewView(ctx)
                                configurePreviewViewForCamera(newPv)
                                previewView = newPv
                                container.addView(
                                    newPv,
                                    0,
                                    android.widget.FrameLayout.LayoutParams(
                                        android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                                        android.widget.FrameLayout.LayoutParams.MATCH_PARENT
                                    )
                                )
                                try { newPv.initializePipeline() } catch (_: Throwable) {}
                            }
                        } catch (_: Throwable) {}
                    }

                    if (!cleanupInProgress) {
                        val latest = previewView
                        if (latest != null) {
                            if (!isProcessingActive) {
                                NosmaiSDK.startProcessing(latest)
                                isProcessingActive = true
                            }
                            try { NosmaiSDK.setCameraFacing(isFrontCamera) } catch (_: Throwable) {}
                            try { NosmaiSDK.setMirrorX(isFrontCamera) } catch (_: Throwable) {}
                            ensureCameraPermissionThenStart()
                            try { latest.requestRenderUpdate() } catch (_: Throwable) {}
                        }
                    } else {
                        pendingStartProcessing = true
                        Handler(Looper.getMainLooper()).postDelayed({
                            try { attemptDeferredStart() } catch (_: Throwable) {}
                        }, 350)
                    }
                } catch (_: Throwable) {}
                result.success(null)
                return
            }

            if (textureEntry == null || surface == null) {
                result.success(null)
                return
            }

            try {
                NosmaiSDK.clearRenderSurface()
            } catch (_: Throwable) {}

            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    val entry = textureEntry
                    val surf = surface
                    if (entry != null && surf != null && !surf.isValid) {
                        val st = entry.surfaceTexture()
                        val w = pendingSurfaceWidth ?: 720
                        val h = pendingSurfaceHeight ?: 1280
                        st.setDefaultBufferSize(w, h)
                        surface = Surface(st)
                    }

                    surface?.let { s ->
                        if (s.isValid) {
                            val w = pendingSurfaceWidth ?: 720
                            val h = pendingSurfaceHeight ?: 1280
                            NosmaiSDK.setRenderSurface(s, w, h)
                            if (!isSwitchingCamera && pendingMirrorForNextFrame == null) {
                                NosmaiSDK.setMirrorX(isFrontCamera)
                            } else {
                                pendingMirrorForNextFrame = isFrontCamera
                            }
                            surfaceReboundOnce = false
                            isSurfaceReady = true
                            if (pendingStartProcessing && !isProcessingActive && previewView != null) {
                                try {
                                    NosmaiSDK.startProcessing(previewView!!)
                                    isProcessingActive = true
                                    ensureCameraPermissionThenStart()
                                } catch (_: Throwable) {}
                                pendingStartProcessing = false
                            }
                        }
                    }
                    result.success(null)
                } catch (e: Throwable) {
                    NosmaiLog.e(TAG, "Failed to reinitialize preview", e)
                    result.success(null)
                }
            }, 100)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "Reinitialize preview error", t)
            result.success(null)
        }
    }


    private fun getNosmaiFilters(): List<Map<String, Any?>> {
        val filters = mutableListOf<Map<String, Any?>>()
        val seenPaths = mutableSetOf<String>()

        try {
            val filterFolders = mutableSetOf<String>()
            val flatFilters = mutableSetOf<String>()

            for (assetPath in flutterAssetPaths) {
                if (assetPath.startsWith(NOSMAI_FILTERS_PREFIX)) {
                    val relativePath = assetPath.removePrefix(NOSMAI_FILTERS_PREFIX)
                    val parts = relativePath.split("/")
                    if (parts.size >= 2) {
                        filterFolders.add(parts[0])
                    }
                } else if (assetPath.startsWith(FILTERS_PREFIX) && assetPath.endsWith(".nosmai")) {
                    flatFilters.add(File(assetPath).nameWithoutExtension)
                }
            }

            for (filterName in filterFolders.sorted()) {
                val filterInfo = loadNosmaiFilter(filterName) ?: continue
                val path = filterInfo["path"]?.toString().orEmpty()
                if (seenPaths.add(path)) filters.add(filterInfo)
            }

            for (filterName in flatFilters.sorted()) {
                val filterInfo = loadFlatNosmaiFilter(filterName) ?: continue
                val path = filterInfo["path"]?.toString().orEmpty()
                if (seenPaths.add(path)) filters.add(filterInfo)
            }

        } catch (e: Exception) {
            NosmaiLog.e(TAG, "Error discovering Nosmai filters", e)
        }

        return filters
    }

    private fun loadNosmaiFilter(filterName: String): Map<String, Any?>? {
        try {
            val manifestPath = "flutter_assets/${NOSMAI_FILTERS_PREFIX}${filterName}/${filterName}_manifest.json"
            val nosmaiPath = "flutter_assets/${NOSMAI_FILTERS_PREFIX}${filterName}/${filterName}.nosmai"
            val previewPath = "flutter_assets/${NOSMAI_FILTERS_PREFIX}${filterName}/${filterName}_preview.png"

            // Validate .nosmai file exists
            val nosmaiFile = ensureAssetCached(nosmaiPath)
            if (nosmaiFile == null || !nosmaiFile.exists()) {
                NosmaiLog.e(TAG, "Error: Missing .nosmai file for filter '$filterName'")
                return null
            }

            val filterInfo = mutableMapOf<String, Any?>()

            // Read manifest.json for metadata
            val manifestText = readAssetText(manifestPath)
            if (manifestText != null) {
                try {
                    val manifest = JSONObject(manifestText)
                    filterInfo["id"] = manifest.optString("id", filterName)
                    filterInfo["name"] = manifest.optString("id", filterName)
                    filterInfo["displayName"] = manifest.optString("displayName", toTitleCase(filterName))
                    filterInfo["description"] = manifest.optString("description", "")
                    filterInfo["filterType"] = normalizeFilterType(manifest.optString("filterType", "effect"))
                    filterInfo["version"] = manifest.optString("version", "1.0.0")
                    filterInfo["author"] = manifest.optString("author", "")
                    filterInfo["minSDKVersion"] = manifest.optString("minSDKVersion", "1.0.0")
                    filterInfo["created"] = manifest.optString("created", "")

                    // Parse tags array
                    val tagsArray = manifest.optJSONArray("tags")
                    val tags = mutableListOf<String>()
                    if (tagsArray != null) {
                        for (i in 0 until tagsArray.length()) {
                            tags.add(tagsArray.getString(i))
                        }
                    }
                    filterInfo["tags"] = tags

                } catch (e: Exception) {
                    NosmaiLog.w(TAG, "Warning: Failed to parse manifest.json for filter '$filterName': ${e.message}")
                    // Use defaults
                    filterInfo["id"] = filterName
                    filterInfo["name"] = filterName
                    filterInfo["displayName"] = toTitleCase(filterName)
                    filterInfo["filterType"] = "effect"
                }
            } else {
                NosmaiLog.w(TAG, "Warning: Missing manifest.json for filter '$filterName', using defaults")
                // Use defaults
                filterInfo["id"] = filterName
                filterInfo["name"] = filterName
                filterInfo["displayName"] = toTitleCase(filterName)
                filterInfo["filterType"] = "effect"
            }

            filterInfo["path"] = nosmaiFile.absolutePath
            filterInfo["effectPath"] = nosmaiFile.absolutePath
            filterInfo["fileSize"] = nosmaiFile.length().toInt()
            filterInfo["type"] = "local"
            filterInfo["isDownloaded"] = true

            // Load preview image
            try {
                val previewStream = context.assets.open(previewPath)
                val previewBitmap = android.graphics.BitmapFactory.decodeStream(previewStream)
                previewStream.close()

                if (previewBitmap != null) {
                    filterInfo["previewImageBase64"] = bitmapToBase64(previewBitmap)
                    filterInfo["hasPreview"] = true
                } else {
                    filterInfo["hasPreview"] = false
                }
            } catch (e: Exception) {
                NosmaiLog.w(TAG, "Warning: No preview image available for filter '$filterName'")
                filterInfo["hasPreview"] = false
            }

            return filterInfo

        } catch (e: Exception) {
            NosmaiLog.e(TAG, "Error loading filter '$filterName'", e)
            return null
        }
    }

    private fun loadFlatNosmaiFilter(filterName: String): Map<String, Any?>? {
        return try {
            val nosmaiPath = "flutter_assets/${FILTERS_PREFIX}${filterName}.nosmai"
            val nosmaiFile = ensureAssetCached(nosmaiPath) ?: return null
            if (!nosmaiFile.exists()) return null

            val manifestFields = extractManifestFieldsFromNosmai(filterName)
            val filterType = normalizeFilterType(manifestFields.first ?: "effect")
            val previewBase64 = tryExtractPreviewBase64(filterName)

            val filterInfo = mutableMapOf<String, Any?>()
            filterInfo["id"] = filterName
            filterInfo["name"] = filterName
            filterInfo["displayName"] = manifestFields.second?.takeIf { it.isNotBlank() } ?: toTitleCase(filterName)
            filterInfo["description"] = manifestFields.third ?: ""
            filterInfo["filterType"] = filterType
            filterInfo["category"] = filterType
            filterInfo["path"] = nosmaiFile.absolutePath
            filterInfo["effectPath"] = nosmaiFile.absolutePath
            filterInfo["fileSize"] = nosmaiFile.length().toInt()
            filterInfo["type"] = "local"
            filterInfo["isDownloaded"] = true
            filterInfo["debug"] = true

            if (!previewBase64.isNullOrBlank()) {
                filterInfo["previewImageBase64"] = previewBase64
                filterInfo["hasPreview"] = true
            } else {
                filterInfo["hasPreview"] = manifestFields.fourth
            }

            filterInfo
        } catch (t: Throwable) {
            NosmaiLog.w(TAG, "Failed to load flat filter '$filterName': ${t.message}")
            null
        }
    }

    private fun readAssetText(assetPath: String): String? {
        return try {
            context.assets.open(assetPath).use { ins ->
                ins.bufferedReader(Charsets.UTF_8).readText()
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun ensureAssetCached(assetPath: String): File? {
        return try {
            val cacheDir = File(context.cacheDir, CACHE_DIR_NAME)
            if (!cacheDir.exists()) cacheDir.mkdirs()

            val fileName = File(assetPath).name
            val outFile = File(cacheDir, fileName)

            if (!outFile.exists() || outFile.length() == 0L) {
                openAnyAsset(assetPath).use { ins ->
                    FileOutputStream(outFile).use { fos ->
                        ins.copyTo(fos)
                    }
                }
            }
            outFile
        } catch (e: Exception) {
            NosmaiLog.w(TAG, "Failed to cache asset: $assetPath", e)
            null
        }
    }

    private fun openAnyAsset(assetPath: String): InputStream {
        return try {
            context.assets.open(assetPath)
        } catch (_: Exception) {
            val candidate = if (assetPath.startsWith("flutter_assets/")) assetPath else "flutter_assets/$assetPath"
            context.assets.open(candidate)
        }
    }

    private fun toTitleCase(name: String): String {
        val cleaned = name.replace('_', ' ').replace('-', ' ')
        return cleaned.split(" ")
            .filter { it.isNotBlank() }
            .joinToString(" ") { it.replaceFirstChar { c -> c.titlecase() } }
    }

    private fun normalizeFilterType(type: String?): String {
        val normalized = type?.trim()?.lowercase()?.replace('-', '_') ?: ""
        return when (normalized) {
            "filter" -> "filter"
            "effect" -> "effect"
            "background", "bg" -> "background"
            "beauty_effect", "beautyeffect", "beauty_effects", "beauty" -> "beauty_effect"
            "game", "games" -> "game"
            else -> "effect"
        }
    }

    private fun extractManifestFieldsFromNosmai(filterName: String): Quad<String?, String?, String?, Boolean> {
        val candidates = listOf(
            "flutter_assets/assets/filters/$filterName.nosmai",
            "assets/filters/$filterName.nosmai",
            "filters/$filterName.nosmai"
        )
        var ftype: String? = null
        var display: String? = null
        var desc: String? = null
        var hasPrev = false
        for (p in candidates) {
            try {
                val cls = Class.forName("com.nosmai.effect.internal.NosmaiFilter")
                val m = cls.getMethod("nativeExtractManifestFromAssets", Context::class.java, String::class.java)
                val jsonStr = m.invoke(null, context, p) as? String
                if (!jsonStr.isNullOrBlank()) {
                    val json = JSONObject(jsonStr)
                    val t = normalizeFilterType(json.optString("filterType", json.optString("type", "")))
                    if (t == "filter" || t == "effect" || t == "beauty_effect" || t == "background" || t == "game") ftype = t
                    json.optString("displayName").takeIf { it.isNotBlank() }?.let { display = it }
                    json.optString("description").takeIf { it.isNotBlank() }?.let { desc = it }
                    if (json.has("preview")) hasPrev = true
                    break
                }
            } catch (_: Throwable) { }
        }
        return Quad(ftype, display, desc, hasPrev)
    }

    private fun tryExtractPreviewBase64(filterName: String): String? {
        val candidates = listOf(
            "flutter_assets/assets/filters/$filterName.nosmai",
            "assets/filters/$filterName.nosmai",
            "filters/$filterName.nosmai"
        )
        for (p in candidates) {
            try {
                val cls = Class.forName("com.nosmai.effect.internal.NosmaiFilter")
                val m = cls.getMethod("nativeExtractPreviewFromAssets", Context::class.java, String::class.java)
                val bmp = m.invoke(null, context, p) as? Bitmap
                if (bmp != null) {
                    return bitmapToBase64(bmp)
                }
            } catch (_: Throwable) { }
        }
        return null
    }

    data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)

    private fun bitmapToBase64(bmp: Bitmap): String {
        val baos = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 70, baos)
        val data = baos.toByteArray()
        return Base64.encodeToString(data, Base64.NO_WRAP)
    }

    private fun resolveEffectToFile(effectPathArg: String): File? {
        val arg = effectPathArg.trim()

        val direct = File(arg)
        if (direct.exists()) return direct

        val assetCandidates = mutableListOf<String>()
        if (arg.endsWith(".nosmai")) {
            assetCandidates.add(arg)
            if (!arg.startsWith("flutter_assets/")) {
                assetCandidates.add("flutter_assets/$arg")
            }
        } else if (arg.startsWith(FILTERS_PREFIX)) {
            assetCandidates.add("flutter_assets/$arg")
            assetCandidates.add(arg)
        } else if (arg.startsWith("filters/")) {
            assetCandidates.add("flutter_assets/$arg")
            assetCandidates.add(arg)
        } else {
            val name = if (arg.endsWith(".nosmai")) arg.substringBeforeLast(".nosmai") else arg
            assetCandidates.add("flutter_assets/${NOSMAI_FILTERS_PREFIX}${name}/${name}.nosmai")
            assetCandidates.add("${NOSMAI_FILTERS_PREFIX}${name}/${name}.nosmai")
            assetCandidates.add("flutter_assets/${FILTERS_PREFIX}${name}.nosmai")
            assetCandidates.add("${FILTERS_PREFIX}${name}.nosmai")
            assetCandidates.add("flutter_assets/filters/${name}.nosmai")
            assetCandidates.add("filters/${name}.nosmai")
        }

        for (asset in assetCandidates) {
            try {
                context.assets.open(asset).use { _ ->
                    val cached = ensureAssetCached(asset)
                    if (cached != null && cached.exists()) return cached
                }
            } catch (_: Exception) {
            }
        }

        for (key in flutterAssetPaths) {
            if (key.startsWith(FILTERS_PREFIX) && key.endsWith(".nosmai")) {
                val name = File(key).nameWithoutExtension
                if (name.equals(arg, ignoreCase = true)) {
                    val cached = ensureAssetCached("flutter_assets/$key") ?: ensureAssetCached(key)
                    if (cached != null && cached.exists()) return cached
                }
            }
        }

        return null
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        activityBinding?.addRequestPermissionsResultListener(this)
        val key = pendingLicenseKey
        if (key != null && !isSdkInitialized) {
            try {
                initializeSdk(binding.activity, key)
            } catch (_: Throwable) {}
            pendingLicenseKey = null
        }
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null; activityBinding = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity; activityBinding = binding }
    override fun onDetachedFromActivity() { activity = null; activityBinding = null }

    private fun ensureCameraPermissionThenStart() {
        val act = activity ?: return
        if (ContextCompat.checkSelfPermission(act, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            if (isProcessingActive && (usingPlatformView || (isSurfaceReady && !cleanupInProgress))) {
                startCamera()
            }
        } else {
            activityBinding?.addRequestPermissionsResultListener(this)
            ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
        }
    }

    private fun stopCameraHelper(clearReference: Boolean) {
        oesFirstFrameWatchdogGeneration++
        try {
            camera2Helper?.stopCamera()
        } catch (_: Throwable) {}
        cameraReadyNotified = false
        if (clearReference) {
            camera2Helper = null
            isCameraPaused = false
        }
        isCameraRunning = false
    }

    private fun handleFirstVisibleCameraFrame() {
        if (!cameraReadyNotified) {
            cameraReadyNotified = true
            oesFirstFrameWatchdogGeneration++
            runOnMain {
                try {
                    NosmaiLog.i(TAG, "Native camera ready; notifying Flutter")
                    channel.invokeMethod("onCameraReady", null)
                } catch (t: Throwable) {
                    NosmaiLog.w(TAG, "Failed to notify Flutter camera ready", t)
                }
            }
        }

        val mirror = pendingMirrorForNextFrame
        if (mirror != null) {
            try { NosmaiSDK.setMirrorX(mirror) } catch (_: Throwable) {}
            pendingMirrorForNextFrame = null
        }

        if (!suppressPreviewUntilMirrored && mirror == null) {
            return
        }

        suppressPreviewUntilMirrored = false
        runOnMain {
            try {
                switchOverlayView?.let { ov ->
                    ov.clearAnimation()
                    ov.animate().alpha(0f).setDuration(80).withEndAction {
                        ov.visibility = android.view.View.GONE
                    }.start()
                }
            } catch (_: Throwable) {}
        }
    }

    private fun armOesFirstFrameWatchdog(
        sourceView: NosmaiPreviewView,
        surfaceTexture: SurfaceTexture
    ) {
        val generation = ++oesFirstFrameWatchdogGeneration
        mainHandler.postDelayed({
            if (generation != oesFirstFrameWatchdogGeneration) return@postDelayed
            if (!useOesCameraInput ||
                sourceView !== previewView ||
                surfaceTexture !== oesReadySurfaceTexture ||
                !isProcessingActive ||
                !isCameraRunning ||
                isCameraPaused ||
                isSwitchingCamera ||
                cameraReadyNotified
            ) {
                return@postDelayed
            }

            NosmaiLog.e(
                TAG,
                "No processed OES frame within timeout; recovering with YUV camera input"
            )
            fallbackToYuvCamera("OES first-frame timeout")
        }, 2500)
    }

    private fun attachCameraFrameCallback(helper: Camera2Helper, pv: NosmaiPreviewView) {
        helper.setFrameCallback(object : Camera2Helper.FrameCallback {
            override fun onFrameAvailable(
                y: java.nio.ByteBuffer?, u: java.nio.ByteBuffer?, v: java.nio.ByteBuffer?,
                width: Int, height: Int,
                yStride: Int, uStride: Int, vStride: Int,
                uPixelStride: Int, vPixelStride: Int
            ) {
                if (y == null || u == null || v == null) return

                handleFirstVisibleCameraFrame()

                if (usingPlatformView) {
                    if (suppressPreviewUntilMirrored) {
                        return
                    }
                    pv.processYuvFrame(
                        y, u, v,
                        width, height,
                        yStride, uStride, vStride,
                        uPixelStride, vPixelStride,
                        calculateFrameRotation(helper.sensorOrientation, helper.isFrontCamera)
                    )
                    pv.requestRenderUpdate()
                    return
                }

                val s = surface
                if (s == null || !s.isValid) return
                if (!surfaceReboundOnce) {
                    try {
                        textureEntry?.surfaceTexture()?.setDefaultBufferSize(width, height)
                        NosmaiSDK.setRenderSurface(s, width, height)
                        if (pendingMirrorForNextFrame == null) {
                            NosmaiSDK.setMirrorX(isFrontCamera)
                        }
                        surfaceReboundOnce = true
                    } catch (_: Throwable) {}
                }

                if (suppressPreviewUntilMirrored) {
                    return
                }

                pv.processYuvFrame(
                    y, u, v,
                    width, height,
                    yStride, uStride, vStride,
                    uPixelStride, vPixelStride,
                    calculateFrameRotation(helper.sensorOrientation, helper.isFrontCamera)
                )
                pv.requestRenderUpdate()
            }
        })
    }

    private fun configureCameraHelperForCurrentInput(
        helper: Camera2Helper,
        pv: NosmaiPreviewView
    ): Boolean {
        helper.setTargetDimensions(1280, 720)

        helper.setFacing(isFrontCamera)
        helper.setPreviewSizeCallback { width, height ->
            if (useOesCameraInput) {
                val rotation = calculateFrameRotation(helper.sensorOrientation, helper.isFrontCamera)
                NosmaiLog.i(
                    TAG,
                    "OES frame config: camera=${width}x$height, sensor=${helper.sensorOrientation}, front=${helper.isFrontCamera}, rotation=$rotation"
                )
                try { pv.setOesInputFrameInfo(width, height, rotation) } catch (_: Throwable) {}
            }
        }
        helper.setCameraReadyCallback {
            runOnMain {
                isCameraRunning = true
                isCameraPaused = false
            }
        }
        helper.setCameraErrorCallback { reason ->
            runOnMain {
                isCameraRunning = false
                if (useOesCameraInput) {
                    fallbackToYuvCamera(reason ?: "Camera2 OES error")
                } else {
                    NosmaiLog.w(TAG, "Camera2 error: $reason")
                }
            }
        }

        pv.setCameraOrientation(helper.isFrontCamera, helper.sensorOrientation)

        if (useOesCameraInput) {
            val st = currentOesSurfaceTexture(pv)
            if (st == null) {
                NosmaiLog.i(TAG, "Waiting for OES SurfaceTexture before camera start")
                return false
            }
            helper.setInputMode(Camera2Helper.InputMode.OES)
            helper.setOesPreviewSurfaceTexture(st)
            helper.setFrameCallback(null)
        } else {
            helper.setInputMode(Camera2Helper.InputMode.YUV)
            attachCameraFrameCallback(helper, pv)
        }

        return true
    }

    private fun currentOesSurfaceTexture(pv: NosmaiPreviewView): SurfaceTexture? {
        if (oesReadyView !== null && oesReadyView !== pv) {
            NosmaiLog.i(TAG, "Clearing stale OES SurfaceTexture before camera start")
            oesReadySurfaceTexture = null
            oesReadyView = null
        }

        val cachedSt = if (oesReadyView === pv) oesReadySurfaceTexture else null
        val st = cachedSt ?: try {
            pv.getCameraSurfaceTexture()
        } catch (_: Throwable) {
            null
        }

        if (st != null) {
            oesReadySurfaceTexture = st
            oesReadyView = pv
        }

        return st
    }

    private fun startCamera() {
        val act = activity ?: return
        val pv = previewView ?: return
        val existingHelper = camera2Helper

        NosmaiLog.i(
            TAG,
            "startCamera requested: oes=$useOesCameraInput running=$isCameraRunning paused=$isCameraPaused existing=${existingHelper != null}"
        )

        if (useOesCameraInput && currentOesSurfaceTexture(pv) == null) {
            NosmaiLog.i(TAG, "Waiting for OES SurfaceTexture before camera helper creation")
            return
        }

        if (existingHelper != null) {
            if (!configureCameraHelperForCurrentInput(existingHelper, pv)) {
                return
            }

            if (isCameraPaused) {
                try {
                    val started = existingHelper.startCamera()
                    isCameraRunning = started
                    isCameraPaused = !started
                    if (started && useOesCameraInput) {
                        currentOesSurfaceTexture(pv)?.let {
                            armOesFirstFrameWatchdog(pv, it)
                        }
                    }
                    if (!started && useOesCameraInput) {
                        fallbackToYuvCamera("OES camera restart failed")
                    }
                } catch (e: Throwable) {
                    NosmaiLog.w(TAG, "Camera restart warning: ${e.message}")
                    if (useOesCameraInput) fallbackToYuvCamera("OES camera restart exception")
                }
                return
            }

            if (isCameraRunning && existingHelper.isValidState()) {
                return
            }

            if (existingHelper.isCameraStarting()) {
                return
            }
        }

        if (isCameraStarting) {
            return
        }

        isCameraStarting = true
        try {
            if (existingHelper != null && !existingHelper.isValidState()) {
                stopCameraHelper(true)
            }

            if (camera2Helper == null) {
                camera2Helper = Camera2Helper(act, isFrontCamera)
            }

            val helper = camera2Helper ?: return
            if (!configureCameraHelperForCurrentInput(helper, pv)) {
                return
            }

            val started = helper.startCamera()
            NosmaiLog.i(TAG, "Camera helper start result=$started")
            isCameraRunning = started
            isCameraPaused = false
            if (started && useOesCameraInput) {
                currentOesSurfaceTexture(pv)?.let {
                    armOesFirstFrameWatchdog(pv, it)
                }
            }
            if (!started && useOesCameraInput) {
                fallbackToYuvCamera("OES camera start failed")
            }
        } finally {
            isCameraStarting = false
        }
    }

    private fun calculateFrameRotation(sensorOrientation: Int, front: Boolean): Int {
        return if (front) { if (sensorOrientation == 270) 1 else 6 } else { if (sensorOrientation == 90) 2 else 1 }
    }

    private fun mergeAudioVideo(videoPath: String, audioPath: String, outputPath: String): Boolean {
        try {
            val videoExtractor = MediaExtractor()
            videoExtractor.setDataSource(videoPath)

            val audioExtractor = MediaExtractor()
            audioExtractor.setDataSource(audioPath)

            val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

            // Add video track
            var videoTrackIndex = -1
            for (i in 0 until videoExtractor.trackCount) {
                val format = videoExtractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime != null && mime.startsWith("video/")) {
                    videoExtractor.selectTrack(i)
                    videoTrackIndex = muxer.addTrack(format)
                    break
                }
            }

            // Add audio track
            var audioTrackIndex = -1
            for (i in 0 until audioExtractor.trackCount) {
                val format = audioExtractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime != null && mime.startsWith("audio/")) {
                    audioExtractor.selectTrack(i)
                    audioTrackIndex = muxer.addTrack(format)
                    break
                }
            }

            if (videoTrackIndex == -1) {
                NosmaiLog.e(TAG, "No video track found")
                return false
            }

            muxer.start()

            // Write video data
            val videoBuf = java.nio.ByteBuffer.allocate(1024 * 1024)
            val videoBufferInfo = MediaCodec.BufferInfo()

            while (true) {
                val sampleSize = videoExtractor.readSampleData(videoBuf, 0)
                if (sampleSize < 0) break

                videoBufferInfo.offset = 0
                videoBufferInfo.size = sampleSize
                videoBufferInfo.presentationTimeUs = videoExtractor.sampleTime
                videoBufferInfo.flags = videoExtractor.sampleFlags

                muxer.writeSampleData(videoTrackIndex, videoBuf, videoBufferInfo)
                videoExtractor.advance()
            }

            // Write audio data if available
            if (audioTrackIndex != -1) {
                val audioBuf = java.nio.ByteBuffer.allocate(1024 * 1024)
                val audioBufferInfo = MediaCodec.BufferInfo()

                while (true) {
                    val sampleSize = audioExtractor.readSampleData(audioBuf, 0)
                    if (sampleSize < 0) break

                    audioBufferInfo.offset = 0
                    audioBufferInfo.size = sampleSize
                    audioBufferInfo.presentationTimeUs = audioExtractor.sampleTime
                    audioBufferInfo.flags = audioExtractor.sampleFlags

                    muxer.writeSampleData(audioTrackIndex, audioBuf, audioBufferInfo)
                    audioExtractor.advance()
                }
            }

            // Clean up
            muxer.stop()
            muxer.release()
            videoExtractor.release()
            audioExtractor.release()

            return true
        } catch (e: Exception) {
            NosmaiLog.e(TAG, "Failed to merge audio/video", e)
            return false
        }
    }

    // --- Effect Parameter Control Methods ---

    private fun handleGetEffectParameters(result: Result) {
        try {
            val parameters = NosmaiEffects.getEffectParameters()
            val paramsList = mutableListOf<Map<String, Any?>>()

            for (param in parameters) {
                try {
                    val paramName = param.name ?: ""
                    val paramType = param.type ?: "float"
                    val floatVal = param.floatValue
                    val intVal = param.intValue
                    val stringVal = param.stringValue
                    val vectorVal = param.vectorValue

                    val currentValue: Any? = when (paramType) {
                        "float" -> floatVal
                        "int", "bool" -> intVal
                        "string" -> stringVal
                        "vector" -> vectorVal?.toList()
                        else -> null
                    }
                    val defaultValue: Any? = when (paramType) {
                        "float" -> param.defaultFloatValue
                        "int", "bool" -> param.defaultIntValue
                        "string" -> param.defaultStringValue
                        "vector" -> param.defaultVectorValue?.toList()
                        else -> null
                    }

                    val paramMap = hashMapOf<String, Any?>(
                        "name" to paramName,
                        "type" to paramType,
                        "displayName" to param.displayName,
                        "description" to param.description,
                        "currentValue" to currentValue,
                        "defaultValue" to defaultValue,
                        "hasRange" to param.hasRange,
                        "minValue" to param.minValue,
                        "maxValue" to param.maxValue,
                        "options" to param.options?.toList().orEmpty(),
                        "passId" to 0
                    )
                    paramsList.add(paramMap)
                } catch (e: Exception) {
                    NosmaiLog.w(TAG, "Failed to parse parameter: ${e.message}", e)
                }
            }

            result.success(paramsList)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getEffectParameters error", t)
            result.error("EFFECT_PARAMETER_ERROR", "Failed to get effect parameters: ${t.message}", null)
        }
    }

    private fun handleGetEffectParameterValue(call: MethodCall, result: Result) {
        try {
            val parameterName = call.argument<String>("parameterName")
            if (parameterName.isNullOrBlank()) {
                result.error("INVALID_PARAMETER", "Parameter name is required", null)
                return
            }

            val value = NosmaiEffects.getEffectParameterValue(parameterName)

            // Check if value is NaN (indicates error)
            if (value.isNaN()) {
                result.error("INVALID_PARAMETER", "Parameter '$parameterName' was not found", null)
            } else {
                result.success(value.toDouble())
            }
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "getEffectParameterValue error", t)
            result.error("EFFECT_PARAMETER_ERROR", "Failed to get parameter value: ${t.message}", null)
        }
    }

    private fun handleSetEffectParameter(call: MethodCall, result: Result) {
        try {
            val parameterName = call.argument<String>("parameterName")
            val value = call.argument<Number>("value")

            if (parameterName.isNullOrBlank()) {
                result.error("INVALID_PARAMETER", "Parameter name is required", null)
                return
            }

            if (value == null) {
                result.error("INVALID_PARAMETER", "Parameter value is required", null)
                return
            }

            val success = NosmaiEffects.setEffectParameter(parameterName, value.toFloat())
            result.success(success)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setEffectParameter error", t)
            result.error("EFFECT_PARAMETER_ERROR", "Failed to set parameter: ${t.message}", null)
        }
    }

    private fun handleSetEffectParameterString(call: MethodCall, result: Result) {
        try {
            val parameterName = call.argument<String>("parameterName")
            val value = call.argument<String>("value")

            if (parameterName.isNullOrBlank()) {
                result.error("INVALID_PARAMETER", "Parameter name is required", null)
                return
            }

            if (value == null) {
                result.error("INVALID_PARAMETER", "Parameter value is required", null)
                return
            }

            val success = NosmaiEffects.setEffectParameter(parameterName, value)
            result.success(success)
        } catch (t: Throwable) {
            NosmaiLog.e(TAG, "setEffectParameterString error", t)
            result.error("EFFECT_PARAMETER_ERROR", "Failed to set parameter string: ${t.message}", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        when (requestCode) {
            REQ_CAMERA -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    if (isProcessingActive && (usingPlatformView || (isSurfaceReady && !cleanupInProgress))) {
                        startCamera()
                    }
                } else {
                    NosmaiLog.e(TAG, "Camera permission denied")
                }
                return true
            }
            REQ_AUDIO -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    NosmaiLog.i(TAG, "Audio permission granted")
                } else {
                    NosmaiLog.e(TAG, "Audio permission denied")
                }
                return true
            }
        }
        return false
    }
}
