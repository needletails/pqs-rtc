package pqsrtc.module

import android.graphics.Outline
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import org.webrtc.AudioTrack
import org.webrtc.EglBase
import org.webrtc.FrameCryptor
import org.webrtc.FrameCryptorAlgorithm
import org.webrtc.FrameCryptorFactory
import org.webrtc.FrameCryptorKeyProvider
import org.webrtc.JavaI420Buffer
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RendererCommon
import org.webrtc.RtpReceiver
import org.webrtc.RtpSender
import org.webrtc.RtpTransceiver
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoFrame
import org.webrtc.VideoTrack
import org.webrtc.YuvHelper
import skip.foundation.ProcessInfo
import java.util.ConcurrentModificationException
import java.util.WeakHashMap

/**
 * FrameCryptor reuse policy for Android SFU renegotiation.
 *
 * SFU renegotiation can swap the live [RtpReceiver] while the negotiated track id stays stable.
 * Reuse only when both the track id and receiver wrapper identity still match.
 */
internal object AndroidReceiverCryptorPolicy {
    fun shouldReuseReceiverCryptorBinding(
        existingTrackId: String?,
        newTrackId: String,
        existingReceiverKey: String?,
        newReceiverKey: String,
    ): Boolean {
        if (newTrackId.isEmpty() || newReceiverKey.isEmpty()) return false
        return existingTrackId == newTrackId && existingReceiverKey == newReceiverKey
    }
}

/**
 * Holds the MediaProjection consent result entirely on the Kotlin side.
 *
 * The consent `Intent` is an arbitrary Java object that SkipBridge cannot bridge into native
 * Swift (`Fatal error: Unable to bridge Kotlin/Java instance`). The app's consent launcher
 * stores it here, only the bridge-safe `resultCode` crosses into Swift, and the screen
 * capturer consumes the intent directly from this holder when it starts.
 */
object AndroidMediaProjectionResultHolder {
    private var resultCode: Int = 0
    private var intent: android.content.Intent? = null

    @Synchronized
    fun store(code: Int, data: android.content.Intent) {
        resultCode = code
        intent = data
    }

    /** One-shot read: MediaProjection consent intents are single-use. */
    @Synchronized
    fun consume(): android.content.Intent? {
        val data = intent
        intent = null
        return data
    }

    @Synchronized
    fun hasResult(): Boolean = intent != null

    @Synchronized
    fun clear() {
        resultCode = 0
        intent = null
    }
}

/**
 * Cached call-UI prefs for capture/render hot paths. Avoids per-frame Swift/UserDefaults bridging
 * and keeps Compose update blocks from synchronously re-reading preferences on the main thread.
 */
object AndroidCaptureUIPreferenceCache {
    private const val KEY_SOFTENING = "PQSRTC.videoAppearanceSoftening"
    private const val KEY_MIRROR = "PQSRTC.localVideoMirrored"
    private const val MIN_REFRESH_MS = 250L

    @Volatile
    private var softeningEnabled: Boolean = true

    @Volatile
    private var localMirrored: Boolean = true

    @Volatile
    private var lastRefreshUptimeMs: Long = 0L

    fun refreshFromStoredPreferences() {
        val ctx = ProcessInfo.processInfo.androidContext
        val prefs = ctx.getSharedPreferences(
            "${ctx.packageName}_preferences",
            android.content.Context.MODE_PRIVATE,
        )
        softeningEnabled =
            if (!prefs.contains(KEY_SOFTENING)) {
                true
            } else {
                prefs.getBoolean(KEY_SOFTENING, true)
            }
        localMirrored =
            if (!prefs.contains(KEY_MIRROR)) {
                true
            } else {
                prefs.getBoolean(KEY_MIRROR, true)
            }
        lastRefreshUptimeMs = android.os.SystemClock.uptimeMillis()
    }

    private fun refreshIfStale() {
        val now = android.os.SystemClock.uptimeMillis()
        if (now - lastRefreshUptimeMs < MIN_REFRESH_MS) return
        refreshFromStoredPreferences()
    }

    fun isVideoAppearanceSofteningEnabled(): Boolean {
        refreshIfStale()
        return softeningEnabled
    }

    fun isLocalVideoMirroredEnabled(): Boolean {
        refreshIfStale()
        return localMirrored
    }
}

internal object AndroidRemoteVideoTrackAttachPolicy {
    fun tracksShareEffectiveSource(lhs: RTCVideoTrack, rhs: RTCVideoTrack): Boolean {
        if (lhs.platformTrack === rhs.platformTrack) return true
        if (!AndroidRTCViewSupport.isLiveVideoTrack(lhs) || !AndroidRTCViewSupport.isLiveVideoTrack(rhs)) {
            return false
        }
        val leftId = lhs.platformTrack.id()?.trim().orEmpty()
        val rightId = rhs.platformTrack.id()?.trim().orEmpty()
        return leftId.isNotEmpty() && leftId == rightId
    }

    fun tracksShareRendererSinkSource(lhs: RTCVideoTrack, rhs: RTCVideoTrack): Boolean {
        return lhs.platformTrack === rhs.platformTrack
    }
}

internal object AndroidRendererLayoutPolicy {
    fun shouldReconcileAfterLayoutChange(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
        hasPendingTrack: Boolean,
        rendererHasSink: Boolean,
        hasAttachedTrack: Boolean,
    ): Boolean {
        if (newWidth <= 0 || newHeight <= 0) return false
        val dimensionsChanged = previousWidth != newWidth || previousHeight != newHeight
        if (dimensionsChanged) return true
        if (!hasPendingTrack && rendererHasSink) return false
        if (!hasPendingTrack && !hasAttachedTrack) return false
        if (hasPendingTrack || !rendererHasSink) return true
        return false
    }
}

class CustomSurfaceViewRenderer : SurfaceViewRenderer {
    private var extraRotation: Int = 0
    private var normalizeToUpright: Boolean = false
    var renderedFrameObserver: (() -> Unit)? = null

    constructor(context: android.content.Context?) : super(context)
    constructor(context: android.content.Context?, attrs: android.util.AttributeSet?) : super(context, attrs)

    fun setExtraRotation(degrees: Int) {
        extraRotation = ((degrees % 360) + 360) % 360
    }

    fun setNormalizeToUpright(normalize: Boolean) {
        normalizeToUpright = normalize
    }

    override fun onFrame(frame: VideoFrame) {
        renderedFrameObserver?.invoke()
        val rot = (frame.rotation + extraRotation) % 360
        if (normalizeToUpright && rot != 0) {
            val src = frame.buffer.toI420() ?: run {
                super.onFrame(frame)
                return
            }
            val w = src.width
            val h = src.height
            val wouldSwap = rot == 90 || rot == 270
            if (wouldSwap && w > h) {
                super.onFrame(VideoFrame(frame.buffer, 0, frame.timestampNs))
                src.release()
                return
            }
            val outW = if (wouldSwap) h else w
            val outH = if (wouldSwap) w else h
            val dst = JavaI420Buffer.allocate(outW, outH)
            YuvHelper.I420Rotate(
                src.dataY, src.strideY,
                src.dataU, src.strideU,
                src.dataV, src.strideV,
                dst.dataY, dst.strideY,
                dst.dataU, dst.strideU,
                dst.dataV, dst.strideV,
                w, h, rot
            )
            src.release()
            val upright = VideoFrame(dst, 0, frame.timestampNs)
            super.onFrame(upright)
            dst.release()
            return
        }
        if (rot == frame.rotation) {
            super.onFrame(frame)
            return
        }
        val corrected = VideoFrame(frame.buffer, rot, frame.timestampNs)
        super.onFrame(corrected)
        corrected.release()
    }
}

object AndroidRTCViewSupport {
    private val rendererFirstFrameCallbacks = WeakHashMap<SurfaceViewRenderer, () -> Unit>()
    private val rendererFirstFrameHandlerGenerations = WeakHashMap<SurfaceViewRenderer, Int>()
    private val rendererFirstFrameHandlers = WeakHashMap<SurfaceViewRenderer, (Int) -> Unit>()

    fun createSurfaceViewRenderer(
        normalizeToUpright: Boolean,
        extraRotation: Int = 0,
        logTag: String
    ): SurfaceViewRenderer {
        val renderer = CustomSurfaceViewRenderer(ProcessInfo.processInfo.androidContext)
        renderer.setNormalizeToUpright(normalizeToUpright)
        renderer.setExtraRotation(extraRotation)
        renderer.setId(android.view.View.generateViewId())
        Log.d(logTag, "INITIALIZED")
        return renderer
    }

    fun releaseRenderer(renderer: SurfaceViewRenderer, logTag: String) {
        try {
            renderer.release()
        } catch (e: Exception) {
            Log.w(logTag, "Error releasing renderer (context may be destroyed): ${e.message}")
        }
    }

    /// Hides a view during call-chrome minimize without destroying its SurfaceView holder.
    /// `View.GONE` tears down surfaces; off-screen translation does not move SurfaceView layers.
    /// `INVISIBLE` keeps EGL sinks live while removing the layer from the screen.
    fun setViewHiddenForCallChromeMinimize(view: android.view.View, hidden: Boolean, logTag: String) {
        view.translationX = 0f
        view.translationY = 0f
        if (hidden) {
            view.alpha = 0f
            view.visibility = android.view.View.INVISIBLE
        } else {
            view.alpha = 1f
            view.visibility = android.view.View.VISIBLE
            view.requestLayout()
        }
        Log.d(
            logTag,
            "[CallChromeMinimize] setViewHiddenForCallChromeMinimize hidden=$hidden " +
                "visibility=${view.visibility} alpha=${view.alpha}"
        )
    }

    fun isSurfaceReady(renderer: SurfaceViewRenderer): Boolean {
        return try {
            val surface = renderer.holder?.surface
            surface != null && surface.isValid && renderer.width > 0 && renderer.height > 0
        } catch (_: Exception) {
            false
        }
    }

    fun currentSurfaceDimensions(renderer: SurfaceViewRenderer): Pair<Int, Int>? {
        return try {
            val frame = renderer.holder?.surfaceFrame
            val frameWidth = frame?.width() ?: 0
            val frameHeight = frame?.height() ?: 0
            if (frameWidth > 0 && frameHeight > 0) {
                Pair(frameWidth, frameHeight)
            } else if (renderer.width > 0 && renderer.height > 0) {
                Pair(renderer.width, renderer.height)
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    fun installSurfaceReadyCallback(
        renderer: SurfaceViewRenderer,
        logTag: String,
        onReady: () -> Unit,
        onDimensionsChanged: ((Int, Int) -> Unit)? = null,
        onDestroyed: (() -> Unit)? = null,
    ): Boolean {
        return try {
            renderer.holder?.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    Log.d(logTag, "Surface created")
                    onReady()
                }

                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    Log.d(logTag, "Surface changed: ${width}x${height}")
                    onDimensionsChanged?.invoke(width, height)
                    onReady()
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    Log.d(logTag, "Surface destroyed")
                    onDestroyed?.invoke()
                }
            })
            if (isSurfaceReady(renderer)) {
                val dimensions = currentSurfaceDimensions(renderer)
                postToMainThread {
                    if (dimensions != null) {
                        onDimensionsChanged?.invoke(dimensions.first, dimensions.second)
                    }
                    onReady()
                }
            }
            true
        } catch (e: Exception) {
            Log.w(logTag, "Failed to setup surface callback: ${e.message}")
            false
        }
    }

    fun isLiveVideoTrack(track: RTCVideoTrack): Boolean {
        return try {
            track.platformTrack.state() == MediaStreamTrack.State.LIVE
        } catch (_: IllegalStateException) {
            false
        }
    }

    fun trackIdIfAvailable(track: RTCVideoTrack): String? {
        return try {
            track.platformTrack.id()
        } catch (_: IllegalStateException) {
            null
        }
    }

    fun trackIdIfAvailable(track: RTCAudioTrack): String? {
        return try {
            track.platformTrack.id()
        } catch (_: IllegalStateException) {
            null
        }
    }

    fun addTrackSink(track: RTCVideoTrack, renderer: SurfaceViewRenderer, logTag: String, message: String): Boolean {
        return try {
            track.platformTrack.addSink(renderer)
            Log.d(logTag, message)
            true
        } catch (e: IllegalStateException) {
            Log.w(logTag, "Attempted to attach disposed track: ${e.message}")
            false
        }
    }

    fun removeTrackSink(track: RTCVideoTrack, renderer: SurfaceViewRenderer) {
        try {
            track.platformTrack.removeSink(renderer)
        } catch (_: IllegalStateException) {
            // Ignore receivers that were already detached or disposed during renegotiation.
        }
    }

    fun configureRenderer(
        renderer: SurfaceViewRenderer,
        mirror: Boolean,
        scalingType: RendererCommon.ScalingType = RendererCommon.ScalingType.SCALE_ASPECT_FIT
    ) {
        try {
            renderer.setMirror(mirror)
            renderer.setScalingType(scalingType)
            (renderer as? CustomSurfaceViewRenderer)?.setExtraRotation(0)
        } catch (_: Throwable) {
        }
    }

    fun initializeSurfaceRenderer(
        renderer: SurfaceViewRenderer,
        eglBase: EglBase,
        mirror: Boolean,
        releaseBeforeInit: Boolean,
        logTag: String
    ) {
        if (releaseBeforeInit) {
            try {
                renderer.clearImage()
                renderer.release()
            } catch (_: Throwable) {
                // Safe to ignore if the renderer was not initialized yet.
            }
        }
        val handlerGeneration = synchronized(rendererFirstFrameHandlerGenerations) {
            rendererFirstFrameHandlerGenerations[renderer] ?: 0
        }
        renderer.init(
            eglBase.eglBaseContext,
            object : RendererCommon.RendererEvents {
                override fun onFirstFrameRendered() {
                    Log.d(logTag, "Renderer first frame rendered")
                    notifyRendererFirstFrame(renderer, handlerGeneration)
                    rendererFirstFrameCallback(renderer)?.invoke()
                }

                override fun onFrameResolutionChanged(width: Int, height: Int, rotation: Int) {
                    Log.d(logTag, "Renderer resolution: ${width}x${height}, rot=${rotation}")
                }
            }
        )
        configureRenderer(renderer, mirror)
    }

    fun registerRendererFirstFrameHandler(
        renderer: SurfaceViewRenderer,
        handlerGeneration: Int,
        onFirstFrame: (Int) -> Unit,
    ) {
        synchronized(rendererFirstFrameHandlers) {
            rendererFirstFrameHandlerGenerations[renderer] = handlerGeneration
            rendererFirstFrameHandlers[renderer] = onFirstFrame
        }
    }

    fun notifyRendererFirstFrame(renderer: SurfaceViewRenderer, handlerGeneration: Int) {
        synchronized(rendererFirstFrameHandlers) {
            val expected = rendererFirstFrameHandlerGenerations[renderer]
            if (expected != handlerGeneration) return
            rendererFirstFrameHandlers[renderer]?.invoke(handlerGeneration)
        }
    }

    fun setRendererFirstFrameCallback(renderer: SurfaceViewRenderer, callback: () -> Unit) {
        synchronized(rendererFirstFrameCallbacks) {
            rendererFirstFrameCallbacks[renderer] = callback
        }
    }

    private fun rendererFirstFrameCallback(renderer: SurfaceViewRenderer): (() -> Unit)? {
        return synchronized(rendererFirstFrameCallbacks) {
            rendererFirstFrameCallbacks[renderer]
        }
    }

    fun applyRoundedOutline(view: View, radiusDp: Float) {
        val radiusPx = radiusDp * view.resources.displayMetrics.density
        view.clipToOutline = true
        view.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(v: View, outline: Outline) {
                outline.setRoundRect(0, 0, v.width, v.height, radiusPx)
            }
        }
        view.invalidateOutline()
    }

    /// Removes a previously applied rounded outline. Renderers are pooled across Compose
    /// remounts, so a renderer that used to carry the tile outline must be reset when the
    /// outline moves to its aspect-fit host container.
    fun clearRoundedOutline(view: View) {
        view.clipToOutline = false
        view.outlineProvider = ViewOutlineProvider.BACKGROUND
        view.invalidateOutline()
    }

    fun detachFromParent(view: View) {
        val parent = view.parent
        if (parent is ViewGroup) {
            parent.removeView(view)
        }
    }

    private val rendererAspectFitContainers =
        WeakHashMap<SurfaceViewRenderer, android.widget.FrameLayout>()

    /// EglRenderer always crops the frame to the renderer view's layout aspect ratio, so a
    /// SurfaceViewRenderer measured EXACTLY (Compose fillMaxSize) aspect-fills regardless of
    /// setScalingType(SCALE_ASPECT_FIT). Hosting the renderer wrap-content + centered inside a
    /// black container lets VideoLayoutMeasure size the view to the rotated frame aspect
    /// (SurfaceViewRenderer requestLayouts on onFrameResolutionChanged), producing letterboxed
    /// remote tiles that match Apple's aspect-fit policy. One container per renderer, reused
    /// across Compose remounts.
    fun aspectFitContainer(renderer: SurfaceViewRenderer): android.widget.FrameLayout {
        val container = synchronized(rendererAspectFitContainers) {
            rendererAspectFitContainers[renderer] ?: android.widget.FrameLayout(
                renderer.context
            ).also { created ->
                created.setBackgroundColor(android.graphics.Color.BLACK)
                rendererAspectFitContainers[renderer] = created
            }
        }
        if (renderer.parent !== container) {
            detachFromParent(renderer)
            container.addView(
                renderer,
                android.widget.FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    android.view.Gravity.CENTER
                )
            )
        }
        return container
    }

    fun aspectFitContainerOrNull(renderer: SurfaceViewRenderer): android.widget.FrameLayout? {
        return synchronized(rendererAspectFitContainers) { rendererAspectFitContainers[renderer] }
    }

    fun clearRendererImage(renderer: SurfaceViewRenderer) {
        try {
            renderer.clearImage()
        } catch (_: Exception) {
            // Ignore if the GL context was already destroyed.
        }
    }

    fun setZOrderMediaOverlay(renderer: SurfaceViewRenderer) {
        renderer.setZOrderMediaOverlay(true)
    }

    fun postToMainThread(action: () -> Unit) {
        Handler(Looper.getMainLooper()).post { action() }
    }

    fun runOnMainThreadSync(action: () -> Boolean): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return action()
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        val result = booleanArrayOf(false)
        Handler(Looper.getMainLooper()).post {
            try {
                result[0] = action()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return result[0]
    }

    fun runOnMainThreadSyncStringNullable(action: () -> String?): String? {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return action()
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        val result = arrayOf<String?>(null)
        Handler(Looper.getMainLooper()).post {
            try {
                result[0] = action()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return result[0]
    }

    fun runOnMainThreadSyncInt(action: () -> Int): Int {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return action()
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        val result = intArrayOf(0)
        Handler(Looper.getMainLooper()).post {
            try {
                result[0] = action()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return result[0]
    }

    fun runOnMainThreadSyncUnit(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
            return
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            try {
                action()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    fun safeReleaseRenderer(renderer: SurfaceViewRenderer, eglBase: EglBase?) {
        if (eglBase?.eglBaseContext != null) {
            releaseRenderer(renderer, "AndroidRTCClient")
        } else {
            Log.w("AndroidRTCClient", "Skipping renderer release - EGL context already destroyed")
        }
    }

    fun logSurfaceRendererInitFailure() {
        Log.e("AndroidRTCClient", "Surface renderer init failed; keeping Compose alive")
    }
}

class AndroidFrameCryptorSupport {
    private var keyProvider: FrameCryptorKeyProvider? = null
    private var generation: Long = 0
    var videoReceiverFrameCryptorReadyHandler: ((String) -> Unit)? = null

    private var videoSenderCryptor: FrameCryptor? = null
    private var audioSenderCryptor: FrameCryptor? = null
    private var screenSenderCryptor: FrameCryptor? = null

    private var videoReceiverCryptor: FrameCryptor? = null
    private var audioReceiverCryptor: FrameCryptor? = null
    private var screenReceiverCryptor: FrameCryptor? = null
    private val videoReceiverCryptorsByParticipantId = mutableMapOf<String, FrameCryptor>()
    private val audioReceiverCryptorsByParticipantId = mutableMapOf<String, FrameCryptor>()
    private val screenReceiverCryptorsByParticipantId = mutableMapOf<String, FrameCryptor>()
    private val videoReceiverKeysByParticipantId = mutableMapOf<String, String>()
    private val audioReceiverKeysByParticipantId = mutableMapOf<String, String>()
    private val screenReceiverKeysByParticipantId = mutableMapOf<String, String>()
    private val videoReceiverTrackIdsByParticipantId = mutableMapOf<String, String>()
    private val audioReceiverTrackIdsByParticipantId = mutableMapOf<String, String>()
    private val screenReceiverTrackIdsByParticipantId = mutableMapOf<String, String>()

    @Synchronized
    fun setKeyProvider(provider: FrameCryptorKeyProvider?) {
        if (keyProvider !== provider) {
            disposeAll()
        }
        keyProvider = provider
    }

    @Synchronized
    fun clearKeyProvider() {
        disposeAll()
        keyProvider = null
    }

    @Synchronized
    fun disposeAll() {
        generation += 1
        videoSenderCryptor?.dispose()
        audioSenderCryptor?.dispose()
        screenSenderCryptor?.dispose()
        videoReceiverCryptorsByParticipantId.values.forEach { it.dispose() }
        audioReceiverCryptorsByParticipantId.values.forEach { it.dispose() }
        screenReceiverCryptorsByParticipantId.values.forEach { it.dispose() }

        videoSenderCryptor = null
        audioSenderCryptor = null
        screenSenderCryptor = null
        videoReceiverCryptor = null
        audioReceiverCryptor = null
        screenReceiverCryptor = null
        videoReceiverCryptorsByParticipantId.clear()
        audioReceiverCryptorsByParticipantId.clear()
        screenReceiverCryptorsByParticipantId.clear()
        videoReceiverKeysByParticipantId.clear()
        audioReceiverKeysByParticipantId.clear()
        screenReceiverKeysByParticipantId.clear()
        videoReceiverTrackIdsByParticipantId.clear()
        audioReceiverTrackIdsByParticipantId.clear()
        screenReceiverTrackIdsByParticipantId.clear()
        videoReceiverFrameCryptorReadyHandler = null
    }

    @Synchronized
    fun disposeScreenSender() {
        generation += 1
        screenSenderCryptor?.dispose()
        screenSenderCryptor = null
    }

    fun attachSenderCryptors(
        factory: PeerConnectionFactory,
        peerConnection: PeerConnection,
        participant: String
    ) {
        val attachGeneration = currentGeneration()
        runOnMain {
            attachSenderCryptorsOnMain(factory, peerConnection, participant, attachGeneration)
        }
    }

    fun attachScreenSenderCryptor(
        factory: PeerConnectionFactory,
        peerConnection: PeerConnection,
        participant: String,
        trackId: String?
    ) {
        val attachGeneration = currentGeneration()
        runOnMain {
            attachScreenSenderCryptorOnMain(factory, peerConnection, participant, trackId, attachGeneration)
        }
    }

    fun attachReceiverCryptors(
        factory: PeerConnectionFactory,
        peerConnection: PeerConnection,
        participant: String,
        trackKind: String?,
        trackId: String?
    ) {
        val attachGeneration = currentGeneration()
        runOnMain {
            attachReceiverCryptorsOnMain(factory, peerConnection, participant, trackKind, trackId, attachGeneration)
        }
    }

    @Synchronized
    private fun attachSenderCryptorsOnMain(
        factory: PeerConnectionFactory,
        peerConnection: PeerConnection,
        participant: String,
        attachGeneration: Long
    ) {
        if (attachGeneration != generation) return
        val provider = keyProvider ?: run {
            Log.e("AndroidRTCClient", "FrameCryptor key provider not initialized")
            return
        }
        val senders = snapshotSenders(peerConnection) ?: return
        val videoSender = senders.firstOrNull {
            try {
                val track = it.track()
                track?.kind() == "video" && !(track.id()?.startsWith("screen_") ?: false)
            } catch (_: IllegalStateException) {
                false
            }
        }
        val audioSender = senders.firstOrNull {
            try { it.track()?.kind() == "audio" } catch (_: IllegalStateException) { false }
        }

        if (videoSenderCryptor != null) {
            Log.i("AndroidRTCClient", "Video sender cryptor already attached; keeping live cryptor")
        } else if (videoSender != null) {
            videoSenderCryptor = createSenderCryptor(
                factory = factory,
                sender = videoSender,
                participant = participant,
                provider = provider,
                tag = "video-sender"
            )
            Log.i("AndroidRTCClient", "✅ Video sender cryptor attached")
        }

        if (audioSenderCryptor != null) {
            Log.i("AndroidRTCClient", "Audio sender cryptor already attached; keeping live cryptor")
        } else if (audioSender != null) {
            audioSenderCryptor = createSenderCryptor(
                factory = factory,
                sender = audioSender,
                participant = participant,
                provider = provider,
                tag = "audio-sender"
            )
            Log.i("AndroidRTCClient", "✅ Audio sender cryptor attached")
        }
    }

    @Synchronized
    private fun attachScreenSenderCryptorOnMain(
        factory: PeerConnectionFactory,
        peerConnection: PeerConnection,
        participant: String,
        trackId: String?,
        attachGeneration: Long
    ) {
        if (attachGeneration != generation) return
        val provider = keyProvider ?: run {
            Log.e("AndroidRTCClient", "FrameCryptor key provider not initialized")
            return
        }
        val senders = snapshotSenders(peerConnection) ?: return
        val sender = senders.firstOrNull { sender ->
            try {
                val track = sender.track()
                if (track?.kind() != "video") return@firstOrNull false
                if (trackId != null) return@firstOrNull track.id() == trackId
                track.id()?.startsWith("screen_") ?: false
            } catch (_: IllegalStateException) {
                false
            }
        } ?: run {
            Log.w("AndroidRTCClient", "No screen sender found for FrameCryptor attach (trackId=${trackId ?: "<auto>"})")
            return
        }

        screenSenderCryptor?.dispose()
        screenSenderCryptor = createSenderCryptor(
            factory = factory,
            sender = sender,
            participant = participant,
            provider = provider,
            tag = "screen-sender"
        )
        Log.i("AndroidRTCClient", "✅ Screen sender cryptor attached (trackId=${sender.track()?.id() ?: "unknown"})")
    }

    @Synchronized
    private fun attachReceiverCryptorsOnMain(
        factory: PeerConnectionFactory,
        peerConnection: PeerConnection,
        participant: String,
        trackKind: String?,
        trackId: String?,
        attachGeneration: Long
    ) {
        if (attachGeneration != generation) return
        val provider = keyProvider ?: run {
            Log.e("AndroidRTCClient", "FrameCryptor key provider not initialized")
            return
        }
        val receivers = snapshotReceivers(peerConnection) ?: return
        val normalizedTrackKind = trackKind?.trim()?.lowercase()
        // Snapshot wrappers can be disposed behind us; treat disposed as non-matching.
        fun receiverTrackId(receiver: RtpReceiver): String =
            try { receiver.track()?.id() ?: "" } catch (_: IllegalStateException) { "" }
        fun receiverTrackKind(receiver: RtpReceiver): String? =
            try { receiver.track()?.kind() } catch (_: IllegalStateException) { null }
        fun matchesRequestedTrack(receiver: RtpReceiver): Boolean =
            trackId == null || receiverTrackId(receiver) == trackId

        val videoReceiver = if (normalizedTrackKind == null || normalizedTrackKind == "video") {
            receivers.firstOrNull {
                val id = receiverTrackId(it)
                receiverTrackKind(it) == "video" && matchesRequestedTrack(it) && !id.startsWith("screen_")
            }
        } else {
            null
        }
        val screenReceiver = if (normalizedTrackKind == null || normalizedTrackKind == "screen") {
            receivers.firstOrNull {
                val id = receiverTrackId(it)
                receiverTrackKind(it) == "video" &&
                    matchesRequestedTrack(it) &&
                    (normalizedTrackKind == "screen" || id.startsWith("screen_"))
            }
        } else {
            null
        }
        val audioReceiver = if (normalizedTrackKind == null || normalizedTrackKind == "audio") {
            receivers.firstOrNull {
                receiverTrackKind(it) == "audio" && matchesRequestedTrack(it)
            }
        } else {
            null
        }

        if ((normalizedTrackKind == null || normalizedTrackKind == "video") && videoReceiver != null) {
            attachVideoReceiverCryptor(factory, videoReceiver, participant, provider)
        }
        if ((normalizedTrackKind == null || normalizedTrackKind == "screen") && screenReceiver != null) {
            attachScreenReceiverCryptor(factory, screenReceiver, participant, provider)
        }
        if ((normalizedTrackKind == null || normalizedTrackKind == "audio") && audioReceiver != null) {
            attachAudioReceiverCryptor(factory, audioReceiver, participant, provider)
        }
    }

    private fun attachVideoReceiverCryptor(
        factory: PeerConnectionFactory,
        receiver: RtpReceiver,
        participant: String,
        provider: FrameCryptorKeyProvider
    ) {
        val receiverKey = System.identityHashCode(receiver).toString()
        val trackId = try { receiver.track()?.id() ?: "" } catch (_: IllegalStateException) { "" }
        val existingCryptor = videoReceiverCryptorsByParticipantId[participant]
        val existingReceiverKey = videoReceiverKeysByParticipantId[participant]
        val existingTrackId = videoReceiverTrackIdsByParticipantId[participant]
        if (existingCryptor != null &&
            AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
                existingTrackId,
                trackId,
                existingReceiverKey,
                receiverKey,
            )
        ) {
            videoReceiverCryptor = existingCryptor
            Log.i("AndroidRTCClient", "Video receiver cryptor already attached for '$participant' receiverKey=$receiverKey trackId=$trackId; keeping live cryptor")
            return
        }

        existingCryptor?.dispose()
        if (existingCryptor != null) {
            Log.i("AndroidRTCClient", "Rebinding video receiver cryptor for '$participant' oldReceiverKey=${existingReceiverKey ?: "<nil>"} oldTrackId=${existingTrackId ?: "<nil>"} newReceiverKey=$receiverKey newTrackId=$trackId")
        }

        val cryptor = FrameCryptorFactory.createFrameCryptorForRtpReceiver(
            factory,
            receiver,
            participant,
            FrameCryptorAlgorithm.AES_GCM,
            provider
        )
        attachObserver("video-receiver", cryptor)
        cryptor?.setEnabled(true)
        if (cryptor != null) {
            videoReceiverCryptorsByParticipantId[participant] = cryptor
            videoReceiverKeysByParticipantId[participant] = receiverKey
            videoReceiverTrackIdsByParticipantId[participant] = trackId
            videoReceiverCryptor = cryptor
            Log.i("AndroidRTCClient", "✅ Video receiver cryptor attached receiverKey=$receiverKey trackId=$trackId")
        }
    }

    private fun attachAudioReceiverCryptor(
        factory: PeerConnectionFactory,
        receiver: RtpReceiver,
        participant: String,
        provider: FrameCryptorKeyProvider
    ) {
        val receiverKey = System.identityHashCode(receiver).toString()
        val trackId = try { receiver.track()?.id() ?: "" } catch (_: IllegalStateException) { "" }
        val existingCryptor = audioReceiverCryptorsByParticipantId[participant]
        val existingReceiverKey = audioReceiverKeysByParticipantId[participant]
        val existingTrackId = audioReceiverTrackIdsByParticipantId[participant]
        if (existingCryptor != null &&
            AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
                existingTrackId,
                trackId,
                existingReceiverKey,
                receiverKey,
            )
        ) {
            audioReceiverCryptor = existingCryptor
            enableAndroidRemoteAudioReceiverTrack(receiver)
            Log.i("AndroidRTCClient", "Audio receiver cryptor already attached for '$participant' receiverKey=$receiverKey trackId=$trackId; keeping live cryptor")
            return
        }

        holdAndroidRemoteAudioReceiverTrack(receiver)
        existingCryptor?.dispose()
        if (existingCryptor != null) {
            Log.i("AndroidRTCClient", "Rebinding audio receiver cryptor for '$participant' oldReceiverKey=${existingReceiverKey ?: "<nil>"} oldTrackId=${existingTrackId ?: "<nil>"} newReceiverKey=$receiverKey newTrackId=$trackId")
        }

        val cryptor = FrameCryptorFactory.createFrameCryptorForRtpReceiver(
            factory,
            receiver,
            participant,
            FrameCryptorAlgorithm.AES_GCM,
            provider
        )
        attachObserver("audio-receiver", cryptor)
        cryptor?.setEnabled(true)
        if (cryptor != null) {
            audioReceiverCryptorsByParticipantId[participant] = cryptor
            audioReceiverKeysByParticipantId[participant] = receiverKey
            audioReceiverTrackIdsByParticipantId[participant] = trackId
            audioReceiverCryptor = cryptor
            enableAndroidRemoteAudioReceiverTrack(receiver)
            Log.i("AndroidRTCClient", "✅ Audio receiver cryptor attached receiverKey=$receiverKey trackId=$trackId")
        }
    }

    private fun holdAndroidRemoteAudioReceiverTrack(receiver: RtpReceiver) {
        try {
            receiver.track()?.takeIf { it.kind() == "audio" }?.setEnabled(false)
        } catch (_: IllegalStateException) {
        }
    }

    private fun enableAndroidRemoteAudioReceiverTrack(receiver: RtpReceiver) {
        try {
            receiver.track()?.takeIf { it.kind() == "audio" }?.setEnabled(true)
        } catch (_: IllegalStateException) {
        }
    }

    private fun attachScreenReceiverCryptor(
        factory: PeerConnectionFactory,
        receiver: RtpReceiver,
        participant: String,
        provider: FrameCryptorKeyProvider
    ) {
        val receiverKey = System.identityHashCode(receiver).toString()
        val trackId = try { receiver.track()?.id() ?: "" } catch (_: IllegalStateException) { "" }
        val existingCryptor = screenReceiverCryptorsByParticipantId[participant]
        val existingReceiverKey = screenReceiverKeysByParticipantId[participant]
        val existingTrackId = screenReceiverTrackIdsByParticipantId[participant]
        if (existingCryptor != null &&
            AndroidReceiverCryptorPolicy.shouldReuseReceiverCryptorBinding(
                existingTrackId,
                trackId,
                existingReceiverKey,
                receiverKey,
            )
        ) {
            screenReceiverCryptor = existingCryptor
            Log.i("AndroidRTCClient", "Screen receiver cryptor already attached for '$participant' receiverKey=$receiverKey trackId=$trackId; keeping live cryptor")
            return
        }

        existingCryptor?.dispose()
        if (existingCryptor != null) {
            Log.i("AndroidRTCClient", "Rebinding screen receiver cryptor for '$participant' oldReceiverKey=${existingReceiverKey ?: "<nil>"} oldTrackId=${existingTrackId ?: "<nil>"} newReceiverKey=$receiverKey newTrackId=$trackId")
        }

        val cryptor = FrameCryptorFactory.createFrameCryptorForRtpReceiver(
            factory,
            receiver,
            participant,
            FrameCryptorAlgorithm.AES_GCM,
            provider
        )
        attachObserver("screen-receiver", cryptor)
        cryptor?.setEnabled(true)
        if (cryptor != null) {
            screenReceiverCryptorsByParticipantId[participant] = cryptor
            screenReceiverKeysByParticipantId[participant] = receiverKey
            screenReceiverTrackIdsByParticipantId[participant] = trackId
            screenReceiverCryptor = cryptor
            Log.i("AndroidRTCClient", "✅ Screen receiver cryptor attached receiverKey=$receiverKey trackId=$trackId")
        }
    }

    private fun createSenderCryptor(
        factory: PeerConnectionFactory,
        sender: RtpSender,
        participant: String,
        provider: FrameCryptorKeyProvider,
        tag: String
    ): FrameCryptor? {
        val cryptor = FrameCryptorFactory.createFrameCryptorForRtpSender(
            factory,
            sender,
            participant,
            FrameCryptorAlgorithm.AES_GCM,
            provider
        )
        attachObserver(tag, cryptor)
        cryptor?.setEnabled(true)
        return cryptor
    }

    private fun attachObserver(tag: String, cryptor: FrameCryptor?) {
        cryptor?.setObserver(object : FrameCryptor.Observer {
            override fun onFrameCryptionStateChanged(
                participantId: String,
                newState: FrameCryptor.FrameCryptionState
            ) {
                val stateDescription = when (newState) {
                    FrameCryptor.FrameCryptionState.NEW -> "new"
                    FrameCryptor.FrameCryptionState.OK -> "ok"
                    FrameCryptor.FrameCryptionState.MISSINGKEY -> "missingKey"
                    FrameCryptor.FrameCryptionState.KEYRATCHETED -> "keyRatcheted"
                    FrameCryptor.FrameCryptionState.INTERNALERROR -> "internalError"
                    FrameCryptor.FrameCryptionState.ENCRYPTIONFAILED -> "encryptionFailed"
                    FrameCryptor.FrameCryptionState.DECRYPTIONFAILED -> "decryptionFailed"
                    else -> "unknown(${newState.ordinal})"
                }
                val logLevel = if (newState == FrameCryptor.FrameCryptionState.OK) Log.INFO else Log.WARN
                Log.println(logLevel, "AndroidRTCClient", "[$tag] FrameCryptor state for '$participantId': $stateDescription")
                if (tag == "video-receiver" && newState == FrameCryptor.FrameCryptionState.OK) {
                    videoReceiverFrameCryptorReadyHandler?.invoke(participantId)
                }
                if (newState == FrameCryptor.FrameCryptionState.MISSINGKEY) {
                    Log.e("AndroidRTCClient", "[$tag] ⚠️ Missing key for '$participantId'")
                } else if (newState == FrameCryptor.FrameCryptionState.INTERNALERROR) {
                    Log.e("AndroidRTCClient", "[$tag] ❌ Internal error for '$participantId'")
                }
            }
        })
    }

    // Both snapshots must come from the shared transceiver snapshot, never from
    // `PeerConnection.getSenders()`/`getReceivers()`: those dispose every wrapper returned by
    // their previous call, so each cryptor attach would rotate the Java identity under every
    // other participant's receiver binding. That identity churn made
    // `shouldReuseReceiverCryptorBinding` always fail, dispose/recreating live FrameCryptors
    // several times per second — every gap let encrypted frames reach the decoder (garbled audio).
    private fun snapshotSenders(peerConnection: PeerConnection): List<RtpSender>? {
        return try {
            AndroidWebRTCTrackResolver.stableSenders(peerConnection)
        } catch (_: ConcurrentModificationException) {
            Log.w("AndroidRTCClient", "Sender list changed while attaching FrameCryptors; waiting for the next sender event")
            null
        }
    }

    private fun snapshotReceivers(peerConnection: PeerConnection): List<RtpReceiver>? {
        return try {
            AndroidWebRTCTrackResolver.stableReceivers(peerConnection)
        } catch (_: ConcurrentModificationException) {
            Log.w("AndroidRTCClient", "Receiver list changed while attaching FrameCryptors; waiting for the next receiver event")
            null
        }
    }

    @Synchronized
    private fun currentGeneration(): Long = generation

    private fun runOnMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            Handler(Looper.getMainLooper()).post { action() }
        }
    }
}

class AndroidPreviewCaptureViewNative(
    @Suppress("UNUSED_PARAMETER") client: AndroidRTCClient,
) {
    val surfaceViewRenderer: SurfaceViewRenderer =
        AndroidRTCViewSupport.createSurfaceViewRenderer(
            normalizeToUpright = false,
            logTag = "ANDROIDPREVIEWCAPTUREVIEW"
        )

    private var pendingTrack: RTCVideoTrack? = null
    private var surfaceCallbackSetup = false
    private var localOutlineRadiusDp = 12f

    fun setMirror(mirrored: Boolean) {
        surfaceViewRenderer.setMirror(mirrored)
    }

    // SurfaceViews composite on their own window layer, so Compose alpha/size/offset modifiers
    // cannot hide them during call-chrome minimize. Park native views off-screen instead of
    // GONE so Surface holders and track sinks stay live (Apple-style browse-while-in-call).
    fun setHidden(hidden: Boolean) {
        val onMainThread = Looper.myLooper() == Looper.getMainLooper()
        val applyHidden = {
            AndroidRTCViewSupport.setViewHiddenForCallChromeMinimize(
                view = surfaceViewRenderer,
                hidden = hidden,
                logTag = "AndroidPreviewCaptureView"
            )
        }
        if (onMainThread) {
            applyHidden()
        } else {
            Handler(Looper.getMainLooper()).post { applyHidden() }
        }
    }

    fun release() {
        pendingTrack = null
        AndroidRTCViewSupport.releaseRenderer(surfaceViewRenderer, "AndroidPreviewCaptureView")
    }

    private fun isSurfaceReady(): Boolean =
        AndroidRTCViewSupport.isSurfaceReady(surfaceViewRenderer)

    private fun setupSurfaceCallback() {
        if (surfaceCallbackSetup) return
        surfaceCallbackSetup = AndroidRTCViewSupport.installSurfaceReadyCallback(
            surfaceViewRenderer,
            "AndroidPreviewCaptureView",
            onReady = { attachPendingTrackIfReady() },
            onDimensionsChanged = { width, height ->
                if (width > 0 && height > 0) {
                    AndroidRTCViewSupport.applyRoundedOutline(
                        view = surfaceViewRenderer,
                        radiusDp = localOutlineRadiusDp
                    )
                }
            }
        )
    }

    fun configureRoundedOutline(radiusDp: Float) {
        localOutlineRadiusDp = radiusDp
        AndroidRTCViewSupport.applyRoundedOutline(view = surfaceViewRenderer, radiusDp = radiusDp)
    }

    private fun attachPendingTrackIfReady() {
        val track = pendingTrack ?: return
        if (isSurfaceReady()) {
            if (AndroidRTCViewSupport.addTrackSink(
                    track,
                    surfaceViewRenderer,
                    "AndroidPreviewCaptureView",
                    "Attached pending track after surface ready"
                )
            ) {
                pendingTrack = null
            }
        }
    }

    fun attach(track: RTCVideoTrack) {
        setupSurfaceCallback()
        if (isSurfaceReady()) {
            AndroidRTCViewSupport.addTrackSink(
                track,
                surfaceViewRenderer,
                "AndroidPreviewCaptureView",
                "Attached track immediately - surface ready"
            )
        } else {
            pendingTrack = track
            Log.d("AndroidPreviewCaptureView", "Surface not ready, queued track for later attachment")
        }
    }

    fun detach(track: RTCVideoTrack) {
        AndroidRTCViewSupport.removeTrackSink(track, surfaceViewRenderer)
        if (pendingTrack?.platformTrack == track.platformTrack) {
            pendingTrack = null
        }
    }
}

class AndroidSampleCaptureViewNative(
    private val client: AndroidRTCClient,
) {
    val surfaceViewRenderer: SurfaceViewRenderer =
        AndroidRTCViewSupport.createSurfaceViewRenderer(
            normalizeToUpright = true,
            logTag = "ANDROIDSAMPLECAPTUREVIEW"
        )

    private var pendingTrack: RTCVideoTrack? = null
    private var attachedTrack: RTCVideoTrack? = null
    private var rendererHasSink = false
    private var hasRenderedFirstFrameSinceSinkAttach = false
    private var surfaceReadyRetry: (() -> Unit)? = null
    private var sinkAttachFirstFrameObserver: (() -> Unit)? = null
    private var surfaceCallbackSetup = false
    private var lastAttachedTrackId: String? = null
    private var layoutCallbackSetup = false
    private var lastSurfaceWidth = 0
    private var lastSurfaceHeight = 0
    private var lastRendererWidth = 0
    private var lastRendererHeight = 0
    private var lastReconciledRendererWidth = 0
    private var lastReconciledRendererHeight = 0
    private var lastEglInitSurfaceWidth = 0
    private var lastEglInitSurfaceHeight = 0
    private var rendererGeneration = 0
    private var sinkBoundGeneration = 0
    private var firstFrameHandlerGeneration = 0
    private var rendererParticipantLabel = "unassigned"
    private var everConfirmedFirstFrameTrackId: String? = null
    private var lastRenderedFrameUptimeMs = 0L
    private var renderedFramesSinceSinkAttach = 0L
    private var pendingLiveWrapperRebindRequested = false

    init {
        (surfaceViewRenderer as? CustomSurfaceViewRenderer)?.renderedFrameObserver = {
            AndroidRTCViewSupport.postToMainThread {
                noteRenderedFrameOnMainThread()
            }
        }
        registerFirstFrameHandlerForCurrentEglGeneration()
    }

    fun setRendererParticipantLabel(label: String) {
        rendererParticipantLabel = label.trim().ifEmpty { "unassigned" }
    }

    // SurfaceViews composite on their own window layer, so Compose alpha/size/offset modifiers
    // cannot hide them during call-chrome minimize. Park native views off-screen instead of
    // GONE so Surface holders and track sinks stay live (Apple-style browse-while-in-call).
    fun setHidden(hidden: Boolean) {
        val onMainThread = Looper.myLooper() == Looper.getMainLooper()
        val applyHidden = {
            AndroidRTCViewSupport.setViewHiddenForCallChromeMinimize(
                view = surfaceViewRenderer,
                hidden = hidden,
                logTag = "AndroidSampleCaptureView"
            )
            AndroidRTCViewSupport.aspectFitContainerOrNull(surfaceViewRenderer)?.let { container ->
                AndroidRTCViewSupport.setViewHiddenForCallChromeMinimize(
                    view = container,
                    hidden = hidden,
                    logTag = "AndroidSampleCaptureView"
                )
            }
            Log.d(
                "AndroidSampleCaptureView",
                "[CallChromeMinimize] setHidden hidden=$hidden participant=$rendererParticipantLabel onMainThread=$onMainThread"
            )
        }
        if (onMainThread) {
            applyHidden()
        } else {
            Handler(Looper.getMainLooper()).post { applyHidden() }
        }
    }

    private fun noteRenderedFrameOnMainThread() {
        lastRenderedFrameUptimeMs = android.os.SystemClock.uptimeMillis()
        if (sinkMatchesCurrentRendererGeneration()) {
            renderedFramesSinceSinkAttach += 1
            confirmFirstFrameSinceSinkAttachIfNeeded("sink_frame_delivery")
        }
    }

    private fun confirmFirstFrameSinceSinkAttachIfNeeded(trigger: String) {
        if (hasRenderedFirstFrameSinceSinkAttach) return
        if (!sinkMatchesCurrentRendererGeneration()) return
        hasRenderedFirstFrameSinceSinkAttach = true
        lastAttachedTrackId?.let { everConfirmedFirstFrameTrackId = it }
        Log.d(
            "AndroidSampleCaptureView",
            "Confirmed first rendered frame participant=$rendererParticipantLabel trackId=${lastAttachedTrackId ?: "<unknown>"} " +
                "rendererGen=$rendererGeneration handlerGen=$firstFrameHandlerGeneration trigger=$trigger"
        )
        sinkAttachFirstFrameObserver?.invoke()
    }

    private fun notifySinkAttachWaitersOnMainThread() {
        sinkAttachFirstFrameObserver?.invoke()
    }

    fun rendererHasDeliveredFramesSinceCurrentSinkAttach(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            renderedFramesSinceSinkAttach > 0L && sinkMatchesCurrentRendererGeneration()
        }
    }

    fun rendererHadConfirmedFirstFrameSinceSinkAttach(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            hasRenderedFirstFrameSinceSinkAttach && sinkMatchesCurrentRendererGeneration()
        }
    }

    fun rendererEverConfirmedFirstFrameForAttachedTrack(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            rendererEverConfirmedFirstFrameForAttachedTrackOnMainThread()
        }
    }

    fun rendererHasPendingTrackBind(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync { rendererHasPendingTrackBindOnMainThread() }
    }

    fun forceReinitializeRendererForAttachedTrackIfPreFirstFrame(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            val track = attachedTrack ?: pendingTrack ?: return@runOnMainThreadSync false
            if (hasRenderedFirstFrameSinceSinkAttach) return@runOnMainThreadSync false
            if (!isSurfaceReady()) {
                pendingTrack = track
                attachedTrack = track
                rendererHasSink = false
                invokeSurfaceReadyRetry()
                return@runOnMainThreadSync false
            }
            if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) return@runOnMainThreadSync false
            Log.d(
                "AndroidSampleCaptureView",
                "Forcing renderer EGL reinit before first frame participant=$rendererParticipantLabel " +
                    "trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"} " +
                    "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration"
            )
            pendingTrack = track
            reinitializeRendererSurfaceForLayoutChange()
        }
    }

    fun forceReinitializeRendererForAttachedTrackIfFrameStale(staleThresholdMs: Long = 6_000L): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            val track = attachedTrack ?: pendingTrack ?: return@runOnMainThreadSync false
            if (!rendererFramesStaleWhileBoundOnMainThread(staleThresholdMs)) {
                return@runOnMainThreadSync false
            }
            if (!isSurfaceReady()) {
                pendingTrack = track
                attachedTrack = track
                rendererHasSink = false
                invokeSurfaceReadyRetry()
                return@runOnMainThreadSync false
            }
            if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) return@runOnMainThreadSync false
            Log.d(
                "AndroidSampleCaptureView",
                "Forcing renderer EGL reinit after stale frames participant=$rendererParticipantLabel " +
                    "trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"} " +
                    "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration"
            )
            pendingTrack = track
            reinitializeRendererSurfaceForLayoutChange()
        }
    }

    private fun rendererEverConfirmedFirstFrameForAttachedTrackOnMainThread(): Boolean {
        val trackId = lastAttachedTrackId ?: attachedTrackIdOnMainThread() ?: return false
        return everConfirmedFirstFrameTrackId == trackId
    }

    private fun rendererHasPendingTrackBindOnMainThread(): Boolean {
        if (pendingTrack != null) return true
        if (!isSurfaceReady() && (attachedTrack != null || pendingTrack != null)) return true
        return attachedTrack != null && !rendererHasSink
    }

    fun rendererFramesStaleWhileBound(staleThresholdMs: Long = 6_000L): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            rendererFramesStaleWhileBoundOnMainThread(staleThresholdMs)
        }
    }

    private fun rendererFramesStaleWhileBoundOnMainThread(staleThresholdMs: Long): Boolean {
        if (!hasRenderedFirstFrameSinceSinkAttach || !sinkMatchesCurrentRendererGeneration()) {
            return false
        }
        if (lastRenderedFrameUptimeMs <= 0L) return false
        return android.os.SystemClock.uptimeMillis() - lastRenderedFrameUptimeMs >= staleThresholdMs
    }

    private fun rendererHasRecentFramesForCurrentSinkOnMainThread(): Boolean {
        if (!rendererHasSink || !sinkMatchesCurrentRendererGeneration()) return false
        if (!hasRenderedFirstFrameSinceSinkAttach) return false
        if (lastRenderedFrameUptimeMs <= 0L) return false
        return !rendererFramesStaleWhileBoundOnMainThread(6_000L)
    }

    fun setMirror(mirrored: Boolean) {
        surfaceViewRenderer.setMirror(mirrored)
    }

    fun release() {
        bumpRendererGeneration()
        pendingTrack = null
        attachedTrack = null
        rendererHasSink = false
        hasRenderedFirstFrameSinceSinkAttach = false
        sinkBoundGeneration = 0
        lastAttachedTrackId = null
        everConfirmedFirstFrameTrackId = null
        renderedFramesSinceSinkAttach = 0L
        pendingLiveWrapperRebindRequested = false
        lastReconciledRendererWidth = 0
        lastReconciledRendererHeight = 0
        lastEglInitSurfaceWidth = 0
        lastEglInitSurfaceHeight = 0
        surfaceReadyRetry = null
        AndroidRTCViewSupport.releaseRenderer(surfaceViewRenderer, "AndroidSampleCaptureView")
    }

    private fun isSurfaceReady(): Boolean =
        AndroidRTCViewSupport.isSurfaceReady(surfaceViewRenderer)

    private fun bumpRendererGeneration() {
        rendererGeneration += 1
        hasRenderedFirstFrameSinceSinkAttach = false
        renderedFramesSinceSinkAttach = 0L
        pendingLiveWrapperRebindRequested = false
    }

    private fun registerFirstFrameHandlerForCurrentEglGeneration() {
        firstFrameHandlerGeneration += 1
        hasRenderedFirstFrameSinceSinkAttach = false
        val handlerGeneration = firstFrameHandlerGeneration
        AndroidRTCViewSupport.registerRendererFirstFrameHandler(
            surfaceViewRenderer,
            handlerGeneration,
        ) { generation ->
            AndroidRTCViewSupport.postToMainThread {
                onEglFirstFrameRenderedOnMainThread(generation)
            }
        }
    }

    private fun ensureFirstFrameHandlerRegistered() {
        if (firstFrameHandlerGeneration == 0) {
            registerFirstFrameHandlerForCurrentEglGeneration()
        }
    }

    private fun onEglFirstFrameRenderedOnMainThread(handlerGeneration: Int) {
        if (handlerGeneration != firstFrameHandlerGeneration) {
            Log.d(
                "AndroidSampleCaptureView",
                "Ignored stale EGL first-frame callback participant=$rendererParticipantLabel handlerGen=$handlerGeneration current=$firstFrameHandlerGeneration " +
                    "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration trackId=${lastAttachedTrackId ?: "<unknown>"}"
            )
            return
        }
        if (!sinkMatchesCurrentRendererGeneration()) {
            Log.d(
                "AndroidSampleCaptureView",
                "Ignored EGL first-frame callback for mismatched sink generation participant=$rendererParticipantLabel " +
                    "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration trackId=${lastAttachedTrackId ?: "<unknown>"}"
            )
            return
        }
        confirmFirstFrameSinceSinkAttachIfNeeded("egl_first_frame")
        if (lastRenderedFrameUptimeMs <= 0L) {
            noteRenderedFrameOnMainThread()
        }
    }

    fun setSinkAttachFirstFrameObserver(observer: (() -> Unit)?) {
        AndroidRTCViewSupport.runOnMainThreadSyncUnit {
            sinkAttachFirstFrameObserver = observer
            if (observer == null) return@runOnMainThreadSyncUnit
            if (hasRenderedFirstFrameSinceSinkAttach && sinkMatchesCurrentRendererGeneration()) {
                observer.invoke()
                return@runOnMainThreadSyncUnit
            }
            if (renderedFramesSinceSinkAttach > 0L && sinkMatchesCurrentRendererGeneration()) {
                confirmFirstFrameSinceSinkAttachIfNeeded("sink_attach_observer")
            }
        }
    }

    fun clearSinkAttachFirstFrameObserver() {
        AndroidRTCViewSupport.runOnMainThreadSyncUnit {
            sinkAttachFirstFrameObserver = null
        }
    }

    fun hasPendingLiveWrapperRebind(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync { pendingLiveWrapperRebindRequested }
    }

    fun requestPendingLiveWrapperRebind() {
        AndroidRTCViewSupport.runOnMainThreadSyncUnit { requestPendingLiveWrapperRebindOnMainThread() }
    }

    fun applyPendingLiveWrapperRebindIfEligible(track: RTCVideoTrack, forceApply: Boolean = false): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            applyPendingLiveWrapperRebindOnMainThread(track, forceApply)
        }
    }

    private fun shouldDeferLiveWrapperRebindWhileStaleHasRecentFrames(
        stale: RTCVideoTrack,
        live: RTCVideoTrack,
    ): Boolean {
        return !AndroidRTCViewSupport.isLiveVideoTrack(stale) &&
            AndroidRTCViewSupport.isLiveVideoTrack(live) &&
            rendererHasRecentFramesForCurrentSinkOnMainThread()
    }

    private fun requestPendingLiveWrapperRebindOnMainThread() {
        pendingLiveWrapperRebindRequested = true
        Log.d(
            "AndroidSampleCaptureView",
            "Deferred live wrapper rebind until stale wrapper stops delivering frames " +
                "participant=$rendererParticipantLabel trackId=${lastAttachedTrackId ?: "<unknown>"}"
        )
    }

    private fun applyPendingLiveWrapperRebindOnMainThread(track: RTCVideoTrack, forceApply: Boolean = false): Boolean {
        if (!pendingLiveWrapperRebindRequested) return false
        if (!forceApply && rendererHasRecentFramesForCurrentSinkOnMainThread()) return false
        if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) {
            Log.w(
                "AndroidSampleCaptureView",
                "Skipped pending live wrapper rebind; resolved receiver is not live " +
                    "participant=$rendererParticipantLabel trackId=${trackIdOrNull(track) ?: "<unknown>"}"
            )
            return false
        }
        pendingLiveWrapperRebindRequested = false
        val stale = attachedTrack
        Log.d(
            "AndroidSampleCaptureView",
            "Applying deferred live wrapper rebind after stale wrapper stopped delivering frames " +
                "participant=$rendererParticipantLabel trackId=${trackIdOrNull(track) ?: lastAttachedTrackId ?: "<unknown>"}"
        )
        if (stale != null &&
            !AndroidRTCViewSupport.isLiveVideoTrack(stale) &&
            shouldRebindSameTrackIdStaleWrapper(trackIdOrNull(track), lastAttachedTrackId)
        ) {
            Log.d(
                "AndroidSampleCaptureView",
                "Applying deferred live wrapper rebind via EGL reinit " +
                    "participant=$rendererParticipantLabel trackId=${trackIdOrNull(track) ?: lastAttachedTrackId ?: "<unknown>"}"
            )
            AndroidRTCViewSupport.removeTrackSink(stale, surfaceViewRenderer)
            hasRenderedFirstFrameSinceSinkAttach = false
            renderedFramesSinceSinkAttach = 0L
            rendererHasSink = false
            pendingTrack = track
            attachedTrack = track
            notifySinkAttachWaitersOnMainThread()
            return reinitializeRendererSurfaceForLayoutChange()
        }
        if (stale != null &&
            AndroidRTCViewSupport.isLiveVideoTrack(stale) &&
            !hasRenderedFirstFrameSinceSinkAttach &&
            shouldRebindSameTrackIdStaleWrapper(trackIdOrNull(track), lastAttachedTrackId)
        ) {
            pendingTrack = track
            attachedTrack = track
            return reinitializeRendererSurfaceForLayoutChange()
        }
        return attachOnMainThread(track)
    }

    private fun rememberSuccessfulSinkAttach(incomingTrackId: String? = null) {
        sinkBoundGeneration = rendererGeneration
        renderedFramesSinceSinkAttach = 0L
        val reboundTrackId = incomingTrackId ?: lastAttachedTrackId
        if (everConfirmedFirstFrameTrackId == null ||
            everConfirmedFirstFrameTrackId != reboundTrackId
        ) {
            hasRenderedFirstFrameSinceSinkAttach = false
            lastRenderedFrameUptimeMs = 0L
        }
    }

    private fun sinkMatchesCurrentRendererGeneration(): Boolean =
        rendererHasSink && sinkBoundGeneration == rendererGeneration

    private fun handleRendererSurfaceDestroyed() {
        logRendererLayoutState("surface_destroyed")
        bumpRendererGeneration()
        rendererHasSink = false
        hasRenderedFirstFrameSinceSinkAttach = false
        lastReconciledRendererWidth = 0
        lastReconciledRendererHeight = 0
        lastSurfaceWidth = 0
        lastSurfaceHeight = 0
        lastEglInitSurfaceWidth = 0
        lastEglInitSurfaceHeight = 0
        attachedTrack?.let { track ->
            if (AndroidRTCViewSupport.isLiveVideoTrack(track)) {
                pendingTrack = track
            }
        }
        invokeSurfaceReadyRetry()
    }

    private fun setupSurfaceCallback() {
        if (surfaceCallbackSetup) return
        ensureFirstFrameHandlerRegistered()
        surfaceCallbackSetup = AndroidRTCViewSupport.installSurfaceReadyCallback(
            surfaceViewRenderer,
            "AndroidSampleCaptureView",
            onReady = { reconcileAttachedSinkAfterSurfaceEvent() },
            onDestroyed = { handleRendererSurfaceDestroyed() },
            onDimensionsChanged = { width, height ->
                if (width <= 0 || height <= 0) return@installSurfaceReadyCallback
                val previousWidth = lastSurfaceWidth
                val previousHeight = lastSurfaceHeight
                val dimensionsChanged = previousWidth != width || previousHeight != height
                lastSurfaceWidth = width
                lastSurfaceHeight = height
                if (shouldReinitRendererEglForHolderResize(previousWidth, previousHeight, width, height)) {
                    logRendererLayoutState("surface_holder_resize_reinit", previousWidth, previousHeight)
                    reinitializeRendererSurfaceForLayoutChange()
                    return@installSurfaceReadyCallback
                }
                if (!AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
                        previousWidth = previousWidth,
                        previousHeight = previousHeight,
                        newWidth = width,
                        newHeight = height,
                        hasPendingTrack = pendingTrack != null,
                        rendererHasSink = rendererHasSink,
                        hasAttachedTrack = attachedTrack != null,
                    )
                ) {
                    return@installSurfaceReadyCallback
                }
                reconcileAttachedSinkAfterSurfaceEvent(
                    forceReattach = dimensionsChanged && pendingTrack != null,
                )
            }
        )
        if (surfaceCallbackSetup && isSurfaceReady()) {
            AndroidRTCViewSupport.postToMainThread { reconcileAttachedSinkAfterSurfaceEvent() }
        }
        setupLayoutCallback()
    }

    private fun setupLayoutCallback() {
        if (layoutCallbackSetup) return
        layoutCallbackSetup = true
        surfaceViewRenderer.addOnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
            reconcileAfterRendererLayout(right - left, bottom - top)
        }
    }

    private fun refreshSurfaceCallbacksAfterRendererReset() {
        surfaceCallbackSetup = false
        setupSurfaceCallback()
    }

    private fun surfaceLayoutIsDrifted(): Boolean {
        val viewWidth = surfaceViewRenderer.width
        val viewHeight = surfaceViewRenderer.height
        if (viewWidth <= 0 || viewHeight <= 0) return false
        if (lastSurfaceWidth > 0 && lastSurfaceHeight > 0 &&
            (viewWidth != lastSurfaceWidth || viewHeight != lastSurfaceHeight)
        ) {
            return true
        }
        return false
    }

    private fun eglInitMatchesCurrentSurface(): Boolean {
        if (lastSurfaceWidth <= 0 || lastSurfaceHeight <= 0) return false
        if (lastEglInitSurfaceWidth <= 0 || lastEglInitSurfaceHeight <= 0) return false
        return lastEglInitSurfaceWidth == lastSurfaceWidth &&
            lastEglInitSurfaceHeight == lastSurfaceHeight
    }

    private fun refreshCurrentSurfaceDimensionsIfAvailable() {
        val dimensions = AndroidRTCViewSupport.currentSurfaceDimensions(surfaceViewRenderer) ?: return
        if (dimensions.first <= 0 || dimensions.second <= 0) return
        lastSurfaceWidth = dimensions.first
        lastSurfaceHeight = dimensions.second
    }

    private fun isLikelyTransientFullscreenSurfaceMeasure(
        surfaceWidth: Int,
        surfaceHeight: Int,
    ): Boolean {
        val viewWidth = surfaceViewRenderer.width
        val viewHeight = surfaceViewRenderer.height
        if (viewWidth <= 0 || viewHeight <= 0 || surfaceWidth <= 0 || surfaceHeight <= 0) {
            return false
        }
        val viewArea = viewWidth.toLong() * viewHeight.toLong()
        val surfaceArea = surfaceWidth.toLong() * surfaceHeight.toLong()
        // Compose may briefly report a fullscreen holder size before tile constraints apply.
        return surfaceArea > (viewArea * 3L) / 2L
    }

    private fun hasActiveSinkFailureReasonOnMainThread(): String {
        if (!sinkMatchesCurrentRendererGeneration()) {
            return "sink_generation_mismatch(rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration)"
        }
        if (!isSurfaceReady()) return "surface_not_ready"
        if (!eglInitMatchesCurrentSurface()) {
            return "egl_init_stale(egl=${lastEglInitSurfaceWidth}x${lastEglInitSurfaceHeight} " +
                "surface=${lastSurfaceWidth}x${lastSurfaceHeight})"
        }
        val track = attachedTrack ?: return "no_attached_track"
        if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) {
            if (rendererHasRecentFramesForCurrentSinkOnMainThread()) {
                return "attached_track_not_live_recent_frames"
            }
            return "attached_track_not_live"
        }
        return "ok"
    }

    private fun rendererAttachDiagnosticSummaryOnMainThread(): String {
        val viewWidth = surfaceViewRenderer.width
        val viewHeight = surfaceViewRenderer.height
        val now = android.os.SystemClock.uptimeMillis()
        val lastFrameAgeMs = if (lastRenderedFrameUptimeMs > 0L) {
            now - lastRenderedFrameUptimeMs
        } else {
            -1L
        }
        val attached = attachedTrack
        val pending = pendingTrack
        val attachedLive = attached?.let { AndroidRTCViewSupport.isLiveVideoTrack(it) } ?: false
        val pendingLive = pending?.let { AndroidRTCViewSupport.isLiveVideoTrack(it) } ?: false
        return "participant=$rendererParticipantLabel " +
            "surface=${lastSurfaceWidth}x${lastSurfaceHeight} " +
            "view=${viewWidth}x${viewHeight} " +
            "eglInit=${lastEglInitSurfaceWidth}x${lastEglInitSurfaceHeight} " +
            "renderer=${lastRendererWidth}x${lastRendererHeight} " +
            "surfaceReady=${isSurfaceReady()} " +
            "rendererHasSink=$rendererHasSink " +
            "hasActiveSink=${hasActiveSinkOnMainThread()} " +
            "hasActiveSinkReason=${hasActiveSinkFailureReasonOnMainThread()} " +
            "eglNeedsResync=${rendererEglNeedsSurfaceResync()} " +
            "transientFullscreen=${isLikelyTransientFullscreenSurfaceMeasure(lastSurfaceWidth, lastSurfaceHeight)} " +
            "pendingTrack=${pendingTrack != null} " +
            "attachedLive=$attachedLive pendingLive=$pendingLive " +
            "trackId=${lastAttachedTrackId ?: "<none>"} " +
            "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration " +
            "firstFrame=$hasRenderedFirstFrameSinceSinkAttach " +
            "framesSinceAttach=$renderedFramesSinceSinkAttach lastFrameAgeMs=$lastFrameAgeMs"
    }

    private fun logRendererLayoutState(reason: String, previousWidth: Int = 0, previousHeight: Int = 0) {
        val transition = if (previousWidth > 0 || previousHeight > 0) {
            " transition=${previousWidth}x${previousHeight}->${lastSurfaceWidth}x${lastSurfaceHeight}"
        } else {
            ""
        }
        Log.d(
            "AndroidSampleCaptureView",
            "Renderer layout [$reason]$transition ${rendererAttachDiagnosticSummaryOnMainThread()}"
        )
    }

    fun rendererAttachDiagnosticSummary(): String {
        return AndroidRTCViewSupport.runOnMainThreadSyncStringNullable {
            rendererAttachDiagnosticSummaryOnMainThread()
        } ?: "participant=$rendererParticipantLabel diagnostics_unavailable"
    }

    private fun shouldReinitRendererEglForHolderResize(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
    ): Boolean {
        if (newWidth <= 0 || newHeight <= 0) return false
        if (isLikelyTransientFullscreenSurfaceMeasure(newWidth, newHeight)) return false
        if (previousWidth <= 0 || previousHeight <= 0) return false
        if (previousWidth == newWidth && previousHeight == newHeight) return false
        // Compose reports a fullscreen holder blip before tile constraints settle.
        if (isLikelyTransientFullscreenSurfaceMeasure(previousWidth, previousHeight)) return true
        // Multiparty grid splits resize tile width in place (e.g. 493×1213 → 1002×1213).
        if (previousHeight == newHeight && previousWidth != newWidth) return true
        return rendererEglNeedsSurfaceResync()
    }

    private fun rendererEglNeedsSurfaceResync(): Boolean {
        if (!isSurfaceReady()) return false
        refreshCurrentSurfaceDimensionsIfAvailable()
        if (lastSurfaceWidth <= 0 || lastSurfaceHeight <= 0) return false
        if (isLikelyTransientFullscreenSurfaceMeasure(lastSurfaceWidth, lastSurfaceHeight)) {
            return false
        }
        if (lastEglInitSurfaceWidth <= 0 || lastEglInitSurfaceHeight <= 0) {
            // WebRTC initialized EGL during Compose setup but we never recorded the holder size.
            return true
        }
        return !eglInitMatchesCurrentSurface()
    }

    private fun shouldReinitializeRendererEglForLayout(): Boolean {
        val viewWidth = surfaceViewRenderer.width
        val viewHeight = surfaceViewRenderer.height
        if (viewWidth <= 0 || viewHeight <= 0) return false
        return rendererEglNeedsSurfaceResync()
    }

    private fun requiresRendererEglReinitForLayout(
        previousWidth: Int,
        previousHeight: Int,
        width: Int,
        height: Int,
    ): Boolean {
        return shouldReinitRendererEglForHolderResize(previousWidth, previousHeight, width, height) &&
            (attachedTrack != null || pendingTrack != null)
    }

    private fun layoutResizeRequiresRendererReinit(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
    ): Boolean {
        return shouldReinitRendererEglForHolderResize(previousWidth, previousHeight, newWidth, newHeight)
    }

    private fun sinkRebindRequiresEglReinit(reason: String): Boolean {
        rendererEglNeedsSurfaceResync()
        if (shouldReinitializeRendererEglForLayout()) return true
        // SFU renegotiation rotates the Java track wrapper; sink-only swaps leave EGL bound to
        // a dead native receiver and the tile freezes after the next wrapper rotation.
        if (reason == "SFU track wrapper refresh" ||
            reason == "stale wrapper surface reconcile" ||
            reason == "pending live wrapper reconcile"
        ) {
            return true
        }
        if (!hasRenderedFirstFrameSinceSinkAttach) {
            return !isSurfaceReady()
        }
        return false
    }

    private fun reinitializeRendererSurfaceForLayoutChange(): Boolean {
        bumpRendererGeneration()
        registerFirstFrameHandlerForCurrentEglGeneration()
        val track = pendingTrack ?: attachedTrack
        if (track == null) {
            logRendererLayoutState("egl_reinit_idle_pool_slot")
            if (!client.reinitializeSurfaceRenderer(surfaceViewRenderer, mirror = false)) {
                logRendererLayoutState("egl_reinit_idle_pool_slot_failed")
                invokeSurfaceReadyRetry()
                return false
            }
            refreshSurfaceCallbacksAfterRendererReset()
            rememberEglInitSurfaceDimensions()
            lastRendererWidth = surfaceViewRenderer.width
            lastRendererHeight = surfaceViewRenderer.height
            rendererHasSink = false
            logRendererLayoutState("egl_reinit_idle_pool_slot_complete")
            return true
        }
        if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) {
            attachedTrack?.let { AndroidRTCViewSupport.removeTrackSink(it, surfaceViewRenderer) }
            attachedTrack = null
            pendingTrack = null
            rendererHasSink = false
            invokeSurfaceReadyRetry()
            return false
        }
        attachedTrack?.let { AndroidRTCViewSupport.removeTrackSink(it, surfaceViewRenderer) }
        rendererHasSink = false
        lastReconciledRendererWidth = 0
        lastReconciledRendererHeight = 0
        logRendererLayoutState(
            "egl_reinit_with_track trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"}"
        )
        if (!client.reinitializeSurfaceRenderer(surfaceViewRenderer, mirror = false)) {
            pendingTrack = track
            attachedTrack = track
            invokeSurfaceReadyRetry()
            return false
        }
        refreshSurfaceCallbacksAfterRendererReset()
        if (!isSurfaceReady()) {
            pendingTrack = track
            attachedTrack = track
            invokeSurfaceReadyRetry()
            return false
        }
        if (AndroidRTCViewSupport.addTrackSink(
                track,
                surfaceViewRenderer,
                "AndroidSampleCaptureView",
                "Reattached track after renderer surface reinit"
            )
        ) {
            attachedTrack = track
            rememberAttachedTrackId(track)
            rendererHasSink = true
            rememberSuccessfulSinkAttach(trackIdOrNull(track))
            pendingTrack = null
            surfaceReadyRetry = null
            rememberReconciledRendererDimensions()
            rememberEglInitSurfaceDimensions()
            lastRendererWidth = surfaceViewRenderer.width
            lastRendererHeight = surfaceViewRenderer.height
            pendingLiveWrapperRebindRequested = false
            logRendererLayoutState("egl_reinit_with_track_complete")
            return true
        }
        pendingTrack = track
        attachedTrack = track
        rendererHasSink = false
        logRendererLayoutState("egl_reinit_with_track_failed")
        invokeSurfaceReadyRetry()
        return false
    }

    private fun rebindRendererSinkForTrackRefresh(
        previousTrack: RTCVideoTrack,
        track: RTCVideoTrack,
        reason: String,
    ): Boolean {
        pendingTrack = track
        if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) {
            Log.w(
                "AndroidSampleCaptureView",
                "Aborted sink rebind with non-live incoming track participant=$rendererParticipantLabel " +
                    "trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"} reason=$reason"
            )
            if (AndroidRTCViewSupport.isLiveVideoTrack(previousTrack) &&
                rendererHasSink &&
                sinkMatchesCurrentRendererGeneration()
            ) {
                pendingTrack = previousTrack
                attachedTrack = previousTrack
                return true
            }
            attachedTrack = null
            rendererHasSink = false
            invokeSurfaceReadyRetry()
            return false
        }
        if (!AndroidRTCViewSupport.isLiveVideoTrack(previousTrack)) {
            Log.d(
                "AndroidSampleCaptureView",
                "Rebinding renderer sink after dead wrapper refresh requires renderer surface reinit " +
                    "participant=$rendererParticipantLabel trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"} " +
                    "reason=$reason rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration"
            )
            AndroidRTCViewSupport.removeTrackSink(previousTrack, surfaceViewRenderer)
            attachedTrack = null
            rendererHasSink = false
            pendingTrack = track
            return reinitializeRendererSurfaceForLayoutChange()
        }
        if (!isSurfaceReady()) {
            AndroidRTCViewSupport.removeTrackSink(previousTrack, surfaceViewRenderer)
            attachedTrack = track
            rendererHasSink = false
            invokeSurfaceReadyRetry()
            return false
        }
        if (sinkRebindRequiresEglReinit(reason)) {
            Log.d(
                "AndroidSampleCaptureView",
                "Rebinding renderer sink after $reason requires renderer surface reinit " +
                    "participant=$rendererParticipantLabel trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"} " +
                    "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration " +
                    "firstFrame=$hasRenderedFirstFrameSinceSinkAttach " +
                    "prevPlatform=${previousTrack.platformTrack.hashCode()} " +
                    "nextPlatform=${track.platformTrack.hashCode()}"
            )
            pendingTrack = track
            return reinitializeRendererSurfaceForLayoutChange()
        }

        Log.d(
            "AndroidSampleCaptureView",
            "Rebinding renderer sink after $reason with sink-only swap " +
                "participant=$rendererParticipantLabel trackId=${lastAttachedTrackId ?: trackIdOrNull(track) ?: "<unknown>"} " +
                "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration " +
                "firstFrame=$hasRenderedFirstFrameSinceSinkAttach"
        )

        AndroidRTCViewSupport.removeTrackSink(previousTrack, surfaceViewRenderer)
        if (AndroidRTCViewSupport.addTrackSink(
                track,
                surfaceViewRenderer,
                "AndroidSampleCaptureView",
                "Rebound renderer sink after $reason"
            )
        ) {
            attachedTrack = track
            rememberAttachedTrackId(track)
            rendererHasSink = true
            rememberSuccessfulSinkAttach(trackIdOrNull(track))
            pendingTrack = null
            surfaceReadyRetry = null
            rememberReconciledRendererDimensions()
            lastRendererWidth = surfaceViewRenderer.width
            lastRendererHeight = surfaceViewRenderer.height
            return true
        }

        rendererHasSink = false
        pendingTrack = track
        invokeSurfaceReadyRetry()
        return false
    }

    private fun rememberEglInitSurfaceDimensions() {
        if (lastSurfaceWidth <= 0 || lastSurfaceHeight <= 0) {
            refreshCurrentSurfaceDimensionsIfAvailable()
        }
        if (lastSurfaceWidth <= 0 || lastSurfaceHeight <= 0) return
        lastEglInitSurfaceWidth = lastSurfaceWidth
        lastEglInitSurfaceHeight = lastSurfaceHeight
    }

    private fun reconcileAfterRendererLayout(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        val previousWidth = lastRendererWidth
        val previousHeight = lastRendererHeight
        val dimensionsChanged = previousWidth != width || previousHeight != height
        if (requiresRendererEglReinitForLayout(previousWidth, previousHeight, width, height)) {
            lastRendererWidth = width
            lastRendererHeight = height
            reinitializeRendererSurfaceForLayoutChange()
            return
        }
        if (!AndroidRendererLayoutPolicy.shouldReconcileAfterLayoutChange(
                previousWidth = previousWidth,
                previousHeight = previousHeight,
                newWidth = width,
                newHeight = height,
                hasPendingTrack = pendingTrack != null,
                rendererHasSink = rendererHasSink,
                hasAttachedTrack = attachedTrack != null,
            )
        ) {
            return
        }
        lastRendererWidth = width
        lastRendererHeight = height
        reconcileAttachedSinkAfterSurfaceEvent(forceReattach = dimensionsChanged)
    }

    fun detachCurrentTrack() {
        attachedTrack?.let { AndroidRTCViewSupport.removeTrackSink(it, surfaceViewRenderer) }
        attachedTrack = null
        pendingTrack = null
        rendererHasSink = false
        hasRenderedFirstFrameSinceSinkAttach = false
        sinkBoundGeneration = 0
        lastAttachedTrackId = null
        lastReconciledRendererWidth = 0
        lastReconciledRendererHeight = 0
        lastEglInitSurfaceWidth = 0
        lastEglInitSurfaceHeight = 0
    }

    private fun reconcileAttachedSinkAfterSurfaceEvent(forceReattach: Boolean = false) {
        val track = pendingTrack ?: attachedTrack ?: run {
            invokeSurfaceReadyRetry()
            return
        }
        if (!AndroidRTCViewSupport.isLiveVideoTrack(track)) {
            AndroidRTCViewSupport.removeTrackSink(track, surfaceViewRenderer)
            attachedTrack = null
            pendingTrack = null
            rendererHasSink = false
            hasRenderedFirstFrameSinceSinkAttach = false
            invokeSurfaceReadyRetry()
            return
        }
        if (!isSurfaceReady()) {
            pendingTrack = track
            rendererHasSink = false
            invokeSurfaceReadyRetry()
            return
        }
        val attached = attachedTrack
        if (attached != null &&
            !AndroidRTCViewSupport.isLiveVideoTrack(attached) &&
            AndroidRTCViewSupport.isLiveVideoTrack(track) &&
            !AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
        ) {
            rebindRendererSinkForTrackRefresh(
                attached,
                track,
                "stale wrapper surface reconcile"
            )
            return
        }
        if (rendererEglNeedsSurfaceResync()) {
            reinitializeRendererSurfaceForLayoutChange()
            return
        }
        val pending = pendingTrack
        if (pending != null &&
            attached != null &&
            AndroidRTCViewSupport.isLiveVideoTrack(pending) &&
            !AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, pending)
        ) {
            rebindRendererSinkForTrackRefresh(
                attached,
                pending,
                "pending live wrapper reconcile"
            )
            return
        }
        if (rendererHasSink && pendingTrack == null && !forceReattach && isSurfaceReady()) {
            val liveAttached = attachedTrack
            if (liveAttached != null &&
                AndroidRTCViewSupport.isLiveVideoTrack(liveAttached) &&
                !rendererEglNeedsSurfaceResync() &&
                !shouldReinitializeRendererEglForLayout()
            ) {
                return
            }
        }
        if (forceReattach && shouldReinitializeRendererEglForLayout()) {
            reinitializeRendererSurfaceForLayoutChange()
            return
        }
        rendererHasSink = false
        AndroidRTCViewSupport.removeTrackSink(track, surfaceViewRenderer)
        if (AndroidRTCViewSupport.addTrackSink(
                track,
                surfaceViewRenderer,
                "AndroidSampleCaptureView",
                "Reattached track after surface event"
            )
        ) {
            attachedTrack = track
            rememberAttachedTrackId(track)
            rendererHasSink = true
            rememberSuccessfulSinkAttach(trackIdOrNull(track))
            rememberReconciledRendererDimensions()
            rememberEglInitSurfaceDimensions()
            pendingTrack = null
            surfaceReadyRetry = null
        } else {
            pendingTrack = null
            if (attachedTrack?.platformTrack == track.platformTrack) {
                attachedTrack = null
            }
            rendererHasSink = false
            hasRenderedFirstFrameSinceSinkAttach = false
            invokeSurfaceReadyRetry()
        }
    }

    fun setSurfaceReadyRetry(retry: () -> Unit) {
        surfaceReadyRetry = retry
        if (pendingTrack != null && isSurfaceReady()) {
            reconcileAttachedSinkAfterSurfaceEvent()
        }
    }

    fun rendererDidInitialize() {
        AndroidRTCViewSupport.runOnMainThreadSyncUnit { rendererDidInitializeOnMainThread() }
    }

    private fun rendererDidInitializeOnMainThread() {
        ensureFirstFrameHandlerRegistered()
        lastRendererWidth = surfaceViewRenderer.width
        lastRendererHeight = surfaceViewRenderer.height
        lastEglInitSurfaceWidth = 0
        lastEglInitSurfaceHeight = 0
        hasRenderedFirstFrameSinceSinkAttach = false
        logRendererLayoutState("renderer_did_initialize")
        if (!surfaceCallbackSetup) {
            setupSurfaceCallback()
        }
        val track = attachedTrack ?: pendingTrack ?: return
        pendingTrack = track
        attachedTrack = track
        if (isSurfaceReady()) {
            reconcileAttachedSinkAfterSurfaceEvent(forceReattach = true)
        } else {
            invokeSurfaceReadyRetry()
        }
    }

    private val composeLayoutHandler = Handler(Looper.getMainLooper())
    private var composeLayoutUpdatePosted = false

    fun rendererDidUpdateLayout() {
        AndroidRTCViewSupport.runOnMainThreadSyncUnit { rendererDidUpdateLayoutOnMainThread() }
    }

    /// Compose `AndroidView.update` runs on the main thread during layout; defer EGL reconcile so
    /// a multiparty grid cannot synchronously reinit every tile in one frame and trigger ANR.
    fun rendererDidUpdateLayoutFromCompose() {
        if (composeLayoutUpdatePosted) return
        composeLayoutUpdatePosted = true
        composeLayoutHandler.post {
            composeLayoutUpdatePosted = false
            rendererDidUpdateLayoutOnMainThread()
        }
    }

    private fun rendererDidUpdateLayoutOnMainThread() {
        val width = surfaceViewRenderer.width
        val height = surfaceViewRenderer.height
        val previousWidth = lastRendererWidth
        val previousHeight = lastRendererHeight
        if (requiresRendererEglReinitForLayout(previousWidth, previousHeight, width, height)) {
            lastRendererWidth = width
            lastRendererHeight = height
            reinitializeRendererSurfaceForLayoutChange()
            return
        }
        reconcileAfterRendererLayout(width, height)
    }

    fun rendererLayoutNeedsSinkReconcile(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync { rendererLayoutNeedsSinkReconcileOnMainThread() }
    }

    private fun rendererLayoutNeedsSinkReconcileOnMainThread(): Boolean {
        val hasTrack = attachedTrack != null || pendingTrack != null
        if (!hasTrack) return false
        if (pendingTrack != null) return true
        if (!isSurfaceReady()) return true
        if (rendererEglNeedsSurfaceResync()) return true
        val attached = attachedTrack
        val pending = pendingTrack
        if (attached != null &&
            pending != null &&
            AndroidRTCViewSupport.isLiveVideoTrack(pending) &&
            !AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, pending)
        ) {
            return true
        }
        if (rendererHasSink && sinkBoundGeneration != rendererGeneration) return true
        if (rendererHasSink && !hasRenderedFirstFrameSinceSinkAttach) {
            // Pre-first-frame bind is normal after attach; only reconcile when surface/EGL drift.
            return rendererEglNeedsSurfaceResync() || pendingTrack != null
        }
        if (!rendererHasSink) return false
        return shouldReinitializeRendererEglForLayout()
    }

    fun attachedTrackIsLive(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync { attachedTrackIsLiveOnMainThread() }
    }

    private fun attachedTrackIsLiveOnMainThread(): Boolean {
        val attached = attachedTrack ?: return false
        return AndroidRTCViewSupport.isLiveVideoTrack(attached)
    }

    fun participantRendererAttachProbeFlags(track: RTCVideoTrack): Int {
        return AndroidRTCViewSupport.runOnMainThreadSyncInt {
            reconcileStaleFirstFrameFlagForAttachedTrackOnMainThread()
            var flags = 0
            if (hasActiveSinkOnMainThread()) {
                flags = flags or 1
            }
            if (attachedTrackSharesRendererSinkOnMainThread(track)) {
                flags = flags or 2
            }
            if (rendererLayoutNeedsSinkReconcileOnMainThread()) {
                flags = flags or 4
            }
            if (attachedTrackIsLiveOnMainThread()) {
                flags = flags or 8
            }
            flags
        }
    }

    fun hasActiveSink(): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync { hasActiveSinkOnMainThread() }
    }

    private fun hasActiveSinkOnMainThread(): Boolean {
        if (!sinkMatchesCurrentRendererGeneration()) return false
        if (!isSurfaceReady()) return false
        if (!eglInitMatchesCurrentSurface()) return false
        val track = attachedTrack ?: return false
        if (AndroidRTCViewSupport.isLiveVideoTrack(track)) return true
        return rendererHasRecentFramesForCurrentSinkOnMainThread()
    }

    private fun reconcileStaleFirstFrameFlagForAttachedTrackOnMainThread() {
        val attached = attachedTrack ?: return
        if (AndroidRTCViewSupport.isLiveVideoTrack(attached)) return
        if (!hasRenderedFirstFrameSinceSinkAttach) return
        hasRenderedFirstFrameSinceSinkAttach = false
        renderedFramesSinceSinkAttach = 0L
    }

    fun attachedTrackId(): String? {
        return AndroidRTCViewSupport.runOnMainThreadSyncStringNullable {
            attachedTrackIdOnMainThread()
        }
    }

    private fun attachedTrackIdOnMainThread(): String? {
        val track = attachedTrack
        if (track == null) return lastAttachedTrackId
        return try {
            val trackId = track.platformTrack.id()?.trim().orEmpty()
            if (trackId.isNotEmpty()) {
                lastAttachedTrackId = trackId
                trackId
            } else {
                lastAttachedTrackId
            }
        } catch (_: IllegalStateException) {
            lastAttachedTrackId
        }
    }

    fun attachedTrackSharesRendererSink(track: RTCVideoTrack): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync {
            attachedTrackSharesRendererSinkOnMainThread(track)
        }
    }

    private fun attachedTrackSharesRendererSinkOnMainThread(track: RTCVideoTrack): Boolean {
        val attached = attachedTrack ?: return false
        if (!sinkMatchesCurrentRendererGeneration()) return false
        if (!hasActiveSinkOnMainThread()) return false
        if (rendererHasRecentFramesForCurrentSinkOnMainThread()) {
            val incomingTrackId = trackIdOrNull(track)
            if (incomingTrackId != null && incomingTrackId == lastAttachedTrackId) {
                // Same negotiated id is not enough after SFU receiver rotation; the tile must
                // still be bound to the live platform track instance from the connection map.
                return AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
            }
        }
        if (!hasRenderedFirstFrameSinceSinkAttach) {
            val incomingTrackId = trackIdOrNull(track)
            if (everConfirmedFirstFrameTrackId != null &&
                everConfirmedFirstFrameTrackId == incomingTrackId &&
                AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
            ) {
                return true
            }
            // Before the first frame, still compare platform track identity. Returning false
            // unconditionally made every pre-first-frame probe report sharesSink=false and
            // triggered spurious coordinator sink rebinds on tiles that were already bound
            // to the live receiver wrapper.
            return AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
        }
        return AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
    }

    private fun removeStaleRendererSinkIfNeeded(): RTCVideoTrack? {
        val staleTrack = attachedTrack ?: return null
        if (AndroidRTCViewSupport.isLiveVideoTrack(staleTrack)) return null
        Log.d(
            "AndroidSampleCaptureView",
            "Removing stale renderer sink during attach trackId=${lastAttachedTrackId ?: trackIdOrNull(staleTrack) ?: "<unknown>"}"
        )
        AndroidRTCViewSupport.removeTrackSink(staleTrack, surfaceViewRenderer)
        attachedTrack = null
        rendererHasSink = false
        hasRenderedFirstFrameSinceSinkAttach = false
        return staleTrack
    }

    private fun rememberAttachedTrackId(track: RTCVideoTrack) {
        trackIdOrNull(track)?.let { lastAttachedTrackId = it }
    }

    private fun trackIdOrNull(track: RTCVideoTrack): String? {
        return try {
            track.platformTrack.id()?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: IllegalStateException) {
            null
        }
    }

    private fun isSameTrackIdWrapperRotation(
        incomingTrackId: String?,
        reboundTrackId: String?,
    ): Boolean {
        if (incomingTrackId.isNullOrEmpty() || reboundTrackId.isNullOrEmpty()) return false
        return incomingTrackId == reboundTrackId
    }

    private fun shouldRebindSameTrackIdStaleWrapper(
        incomingTrackId: String?,
        reboundTrackId: String?,
    ): Boolean {
        if (incomingTrackId.isNullOrEmpty() && !reboundTrackId.isNullOrEmpty()) {
            return true
        }
        if (everConfirmedFirstFrameTrackId != null &&
            everConfirmedFirstFrameTrackId == reboundTrackId
        ) {
            return true
        }
        return isSameTrackIdWrapperRotation(
            incomingTrackId,
            reboundTrackId ?: lastAttachedTrackId
        )
    }

    private fun rememberReconciledRendererDimensions() {
        if (lastSurfaceWidth > 0 && lastSurfaceHeight > 0) {
            lastReconciledRendererWidth = lastSurfaceWidth
            lastReconciledRendererHeight = lastSurfaceHeight
        } else {
            lastReconciledRendererWidth = surfaceViewRenderer.width
            lastReconciledRendererHeight = surfaceViewRenderer.height
        }
    }

    private fun invokeSurfaceReadyRetry() {
        val retry = surfaceReadyRetry ?: return
        surfaceReadyRetry = null
        AndroidRTCViewSupport.postToMainThread(retry)
    }

    private fun attachTrackSinkImmediate(
        track: RTCVideoTrack,
        previousTrack: RTCVideoTrack?,
        attachReason: String,
    ): Boolean {
        val width = surfaceViewRenderer.width
        val height = surfaceViewRenderer.height
        if (requiresRendererEglReinitForLayout(lastRendererWidth, lastRendererHeight, width, height) ||
            rendererEglNeedsSurfaceResync()
        ) {
            logRendererLayoutState("attach_requires_egl_resync reason=$attachReason")
            pendingTrack = track
            attachedTrack = track
            lastRendererWidth = width
            lastRendererHeight = height
            return reinitializeRendererSurfaceForLayoutChange()
        }
        previousTrack?.let { stale ->
            val stalePlatformDiffers = stale.platformTrack != track.platformTrack
            val staleWrapperEnded = !AndroidRTCViewSupport.isLiveVideoTrack(stale)
            if (stalePlatformDiffers || staleWrapperEnded) {
                AndroidRTCViewSupport.removeTrackSink(stale, surfaceViewRenderer)
                hasRenderedFirstFrameSinceSinkAttach = false
                renderedFramesSinceSinkAttach = 0L
            }
        }
        if (AndroidRTCViewSupport.addTrackSink(
                track,
                surfaceViewRenderer,
                "AndroidSampleCaptureView",
                attachReason
            )
        ) {
            attachedTrack = track
            rendererHasSink = true
            rememberSuccessfulSinkAttach(trackIdOrNull(track))
            rememberAttachedTrackId(track)
            pendingTrack = null
            surfaceReadyRetry = null
            rememberReconciledRendererDimensions()
            rememberEglInitSurfaceDimensions()
            lastRendererWidth = width
            lastRendererHeight = height
            pendingLiveWrapperRebindRequested = false
            logRendererLayoutState("attach_sink_bound reason=$attachReason")
            return true
        }
        rendererHasSink = false
        logRendererLayoutState("attach_sink_bind_failed reason=$attachReason")
        invokeSurfaceReadyRetry()
        return false
    }

    fun attach(track: RTCVideoTrack): Boolean {
        return AndroidRTCViewSupport.runOnMainThreadSync { attachOnMainThread(track) }
    }

    private fun attachOnMainThread(track: RTCVideoTrack): Boolean {
        val incomingTrackId = trackIdOrNull(track)
        logRendererLayoutState("attach_begin trackId=${incomingTrackId ?: "<unknown>"}")
        val incomingTrackIsLive = AndroidRTCViewSupport.isLiveVideoTrack(track)
        if (incomingTrackIsLive && isSurfaceReady()) {
            val attachedBeforeStaleRemoval = attachedTrack
            val reboundTrackId = incomingTrackId ?: lastAttachedTrackId
            if (attachedBeforeStaleRemoval != null &&
                !AndroidRTCViewSupport.isLiveVideoTrack(attachedBeforeStaleRemoval) &&
                shouldRebindSameTrackIdStaleWrapper(incomingTrackId, reboundTrackId)
            ) {
                val staleHasRecentFrames = shouldDeferLiveWrapperRebindWhileStaleHasRecentFrames(
                    attachedBeforeStaleRemoval,
                    track
                )
                if (staleHasRecentFrames) {
                    if (!hasRenderedFirstFrameSinceSinkAttach) {
                        requestPendingLiveWrapperRebindOnMainThread()
                        return hasActiveSinkOnMainThread()
                    }
                    Log.d(
                        "AndroidSampleCaptureView",
                        "Skipping stale-frame defer; confirmed frames require live wrapper EGL swap " +
                            "participant=$rendererParticipantLabel trackId=${reboundTrackId ?: "<unknown>"}"
                    )
                }
                Log.d(
                    "AndroidSampleCaptureView",
                    "Rebinding live wrapper via EGL reinit after stale wrapper rotation " +
                        "participant=$rendererParticipantLabel trackId=${reboundTrackId ?: "<unknown>"} " +
                        "rendererGen=$rendererGeneration sinkGen=$sinkBoundGeneration"
                )
                AndroidRTCViewSupport.removeTrackSink(attachedBeforeStaleRemoval, surfaceViewRenderer)
                hasRenderedFirstFrameSinceSinkAttach = false
                renderedFramesSinceSinkAttach = 0L
                rendererHasSink = false
                pendingTrack = track
                attachedTrack = track
                notifySinkAttachWaitersOnMainThread()
                return reinitializeRendererSurfaceForLayoutChange()
            }
        }
        if (!incomingTrackIsLive) {
            if (rendererHasSink &&
                attachedTrack != null &&
                AndroidRTCViewSupport.isLiveVideoTrack(attachedTrack!!)
            ) {
                Log.w(
                    "AndroidSampleCaptureView",
                    "Ignored disposed track attach while live sink remains active trackId=${lastAttachedTrackId ?: "<unknown>"}"
                )
                return hasActiveSinkOnMainThread()
            }
            Log.w(
                "AndroidSampleCaptureView",
                "Ignored non-live track attach before stale sink removal participant=$rendererParticipantLabel " +
                    "incomingTrackId=${incomingTrackId ?: "<unknown>"} attachedTrackId=${lastAttachedTrackId ?: "<unknown>"}"
            )
            return false
        }
        val removedStaleTrack = removeStaleRendererSinkIfNeeded()
        val reboundTrackId = incomingTrackId ?: lastAttachedTrackId
        setupSurfaceCallback()
        var attached = attachedTrack
        if (attached != null &&
            !AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
        ) {
            if (!AndroidRTCViewSupport.isLiveVideoTrack(track) &&
                attached != null &&
                AndroidRTCViewSupport.isLiveVideoTrack(attached) &&
                rendererHasSink &&
                sinkMatchesCurrentRendererGeneration()
            ) {
                Log.w(
                    "AndroidSampleCaptureView",
                    "Ignored stale wrapper attach while live sink remains active participant=$rendererParticipantLabel " +
                        "trackId=${lastAttachedTrackId ?: incomingTrackId ?: "<unknown>"}"
                )
                return hasActiveSinkOnMainThread()
            }
            if (isSurfaceReady()) {
                Log.d(
                    "AndroidSampleCaptureView",
                    "Rebinding renderer sink after SFU track wrapper refresh trackId=${lastAttachedTrackId ?: incomingTrackId ?: "<unknown>"}"
                )
                return rebindRendererSinkForTrackRefresh(
                    attached,
                    track,
                    "SFU track wrapper refresh"
                )
            }
            AndroidRTCViewSupport.removeTrackSink(attached, surfaceViewRenderer)
            pendingTrack = track
            attachedTrack = track
            rememberAttachedTrackId(track)
            rendererHasSink = false
            hasRenderedFirstFrameSinceSinkAttach = false
            invokeSurfaceReadyRetry()
            return false
        }
        if (attached != null &&
            sinkMatchesCurrentRendererGeneration() &&
            hasRenderedFirstFrameSinceSinkAttach &&
            isSurfaceReady() &&
            AndroidRTCViewSupport.isLiveVideoTrack(track) &&
            AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
        ) {
            attachedTrack = track
            rememberAttachedTrackId(track)
            pendingTrack = null
            surfaceReadyRetry = null
            Log.d("AndroidSampleCaptureView", "Track already attached - surface ready")
            val width = surfaceViewRenderer.width
            val height = surfaceViewRenderer.height
            if (requiresRendererEglReinitForLayout(lastRendererWidth, lastRendererHeight, width, height)) {
                lastRendererWidth = width
                lastRendererHeight = height
                reinitializeRendererSurfaceForLayoutChange()
            } else {
                reconcileAfterRendererLayout(width, height)
            }
            return true
        }
        if (attached != null &&
            !rendererHasSink &&
            isSurfaceReady() &&
            AndroidRTCViewSupport.isLiveVideoTrack(track) &&
            AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
        ) {
            Log.d(
                "AndroidSampleCaptureView",
                "Rebinding renderer sink after inactive sink state trackId=${lastAttachedTrackId ?: incomingTrackId ?: "<unknown>"}"
            )
            return attachTrackSinkImmediate(
                track,
                attached,
                "Reattached track after inactive sink state"
            )
        }
        if (attached != null &&
            sinkMatchesCurrentRendererGeneration() &&
            !hasRenderedFirstFrameSinceSinkAttach &&
            isSurfaceReady() &&
            AndroidRTCViewSupport.isLiveVideoTrack(track) &&
            AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(attached, track)
        ) {
            attachedTrack = track
            rememberAttachedTrackId(track)
            pendingTrack = null
            surfaceReadyRetry = null
            Log.d(
                "AndroidSampleCaptureView",
                "Track sink already bound - waiting for first rendered frame trackId=${lastAttachedTrackId ?: incomingTrackId ?: "<unknown>"}"
            )
            return true
        }
        if (removedStaleTrack != null && AndroidRTCViewSupport.isLiveVideoTrack(track)) {
            if (shouldRebindSameTrackIdStaleWrapper(incomingTrackId, reboundTrackId) &&
                isSurfaceReady()
            ) {
                pendingTrack = track
                logRendererLayoutState(
                    "attach_requires_egl_reinit_after_same_track_stale_wrapper trackId=${incomingTrackId ?: "<unknown>"}"
                )
                return reinitializeRendererSurfaceForLayoutChange()
            }
            pendingTrack = track
            if (isSurfaceReady()) {
                logRendererLayoutState(
                    "attach_requires_egl_reinit_after_stale_wrapper trackId=${incomingTrackId ?: "<unknown>"}"
                )
                return reinitializeRendererSurfaceForLayoutChange()
            }
            rendererHasSink = false
            invokeSurfaceReadyRetry()
            return false
        }
        if (isSurfaceReady()) {
            val attachedNow = attachTrackSinkImmediate(
                track,
                attachedTrack,
                "Attached track immediately - surface ready"
            )
            logRendererLayoutState(
                "attach_end trackId=${incomingTrackId ?: "<unknown>"} attachReturned=$attachedNow"
            )
            return attachedNow
        }
        pendingTrack = track
        attachedTrack = track
        rendererHasSink = false
        hasRenderedFirstFrameSinceSinkAttach = false
        logRendererLayoutState("attach_queued_surface_not_ready trackId=${incomingTrackId ?: "<unknown>"}")
        Log.d("AndroidSampleCaptureView", "Surface not ready, queued track for later attachment")
        AndroidRTCViewSupport.postToMainThread { reconcileAttachedSinkAfterSurfaceEvent() }
        return false
    }

    fun detach(track: RTCVideoTrack) {
        AndroidRTCViewSupport.removeTrackSink(track, surfaceViewRenderer)
        val incomingTrackId = trackIdOrNull(track)
        if (pendingTrack?.platformTrack == track.platformTrack) {
            pendingTrack = null
        }
        val attached = attachedTrack
        if (attached?.platformTrack == track.platformTrack ||
            (incomingTrackId != null && incomingTrackId == lastAttachedTrackId)
        ) {
            if (attached != null && attached.platformTrack != track.platformTrack) {
                AndroidRTCViewSupport.removeTrackSink(attached, surfaceViewRenderer)
            }
            attachedTrack = null
            rendererHasSink = false
            hasRenderedFirstFrameSinceSinkAttach = false
        }
    }

    fun clearSurfaceReadyRetry() {
        surfaceReadyRetry = null
    }
}

/**
 * Single owner of `PeerConnection.getTransceivers()` on Android.
 *
 * The Android WebRTC SDK **disposes every transceiver wrapper returned by the previous
 * `getTransceivers()` call** each time it is invoked, which cascades into disposing the cached
 * receiver `VideoTrack` wrappers — and `VideoTrack.dispose()` silently removes every renderer
 * sink that was attached through that wrapper. Ad-hoc `getTransceivers()` probes therefore
 * detach live sibling renderers mid-call (group-call remote freeze seesaw).
 *
 * All track/transceiver resolution must go through the cached snapshot below. The snapshot is
 * refreshed only on explicit [invalidateTransceiverSnapshot] calls at receiver-rotation
 * boundaries (set-description success, track observer events, local media mutations), keeping
 * wrapper rotation event-driven and bounded to moments where the attach coordinator re-attaches
 * every tile anyway.
 */
object AndroidWebRTCTrackResolver {
    private val transceiverSnapshots = WeakHashMap<PeerConnection, List<RtpTransceiver>>()

    /** Marks the snapshot stale; the next resolution refreshes it exactly once. Never calls into WebRTC. */
    @Synchronized
    fun invalidateTransceiverSnapshot(peerConnection: PeerConnection?) {
        if (peerConnection == null) return
        transceiverSnapshots.remove(peerConnection)
    }

    /**
     * Native `getTransceivers()` SIGSEGVs once signaling/connection state is CLOSED. Call this
     * before any transceiver lookup (including cached snapshots) during teardown races.
     */
    fun peerConnectionIsUsableForTransceiverLookup(peerConnection: PeerConnection): Boolean {
        return try {
            when (peerConnection.signalingState()) {
                PeerConnection.SignalingState.CLOSED -> false
                else -> when (peerConnection.connectionState()) {
                    PeerConnection.PeerConnectionState.CLOSED -> false
                    else -> true
                }
            }
        } catch (_: IllegalStateException) {
            false
        }
    }

    /** True when ICE/DTLS transport is already up; used to suppress stale relay-fallback retries. */
    fun peerConnectionTransportIsEstablished(peerConnection: PeerConnection): Boolean {
        if (!peerConnectionIsUsableForTransceiverLookup(peerConnection)) return false
        return try {
            when (peerConnection.iceConnectionState()) {
                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> true
                else -> peerConnection.connectionState() == PeerConnection.PeerConnectionState.CONNECTED
            }
        } catch (_: IllegalStateException) {
            false
        }
    }

    /**
     * Cached transceiver list for this peer connection. Refreshing disposes wrappers from the
     * previous refresh, so this must remain the only `getTransceivers()` call site.
     */
    @Synchronized
    fun transceivers(peerConnection: PeerConnection): List<RtpTransceiver> {
        if (!peerConnectionIsUsableForTransceiverLookup(peerConnection)) {
            invalidateTransceiverSnapshot(peerConnection)
            return emptyList()
        }
        transceiverSnapshots[peerConnection]?.let { return it }
        val fresh = try {
            peerConnection.getTransceivers().toList()
        } catch (_: IllegalStateException) {
            invalidateTransceiverSnapshot(peerConnection)
            return emptyList()
        }
        transceiverSnapshots[peerConnection] = fresh
        return fresh
    }

    /**
     * Receiver wrappers from the cached transceiver snapshot. Unlike `PeerConnection.getReceivers()`
     * (which disposes every wrapper returned by its previous call), these wrappers keep a stable
     * Java identity between snapshot invalidations, so identity-keyed bindings (e.g. FrameCryptor
     * receiver keys) survive repeated lookups and only rotate at real renegotiation boundaries.
     */
    fun stableReceivers(peerConnection: PeerConnection): List<RtpReceiver> {
        val fromSnapshot = { snapshot: List<RtpTransceiver> ->
            snapshot.mapNotNull { transceiver ->
                try {
                    transceiver.getReceiver()
                } catch (_: IllegalStateException) {
                    null
                }
            }
        }
        val snapshot = transceivers(peerConnection)
        val receivers = fromSnapshot(snapshot)
        if (receivers.isNotEmpty() || snapshot.isEmpty()) return receivers
        // Whole snapshot disposed behind us: refresh once so bindings recover on the next event.
        invalidateTransceiverSnapshot(peerConnection)
        return fromSnapshot(transceivers(peerConnection))
    }

    /** Sender wrappers from the cached transceiver snapshot; same identity-stability rationale as [stableReceivers]. */
    fun stableSenders(peerConnection: PeerConnection): List<RtpSender> {
        val fromSnapshot = { snapshot: List<RtpTransceiver> ->
            snapshot.mapNotNull { transceiver ->
                try {
                    transceiver.sender
                } catch (_: IllegalStateException) {
                    null
                }
            }
        }
        val snapshot = transceivers(peerConnection)
        val senders = fromSnapshot(snapshot)
        if (senders.isNotEmpty() || snapshot.isEmpty()) return senders
        invalidateTransceiverSnapshot(peerConnection)
        return fromSnapshot(transceivers(peerConnection))
    }

    fun videoTransceiverCount(peerConnection: PeerConnection): Int {
        var count = 0
        for (transceiver in transceivers(peerConnection)) {
            if (transceiverMediaTypeOrNull(transceiver) == MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) count += 1
        }
        return count
    }

    fun hasAudioTransceiver(peerConnection: PeerConnection): Boolean {
        for (transceiver in transceivers(peerConnection)) {
            if (transceiverMediaTypeOrNull(transceiver) == MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO) return true
        }
        return false
    }

    /**
     * Trackless video transceiver beyond the camera slot (the reserved group-call screen slot),
     * if one exists.
     */
    fun reusableScreenSlotTransceiver(peerConnection: PeerConnection): RtpTransceiver? {
        var seenFirstVideo = false
        for (transceiver in transceivers(peerConnection)) {
            if (transceiverMediaTypeOrNull(transceiver) != MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) continue
            if (!seenFirstVideo) {
                seenFirstVideo = true
                continue
            }
            val senderHasTrack = try {
                transceiver.sender.track() != null
            } catch (_: IllegalStateException) {
                continue
            }
            if (!senderHasTrack) return transceiver
        }
        return null
    }

    fun firstRemoteCameraTrack(peerConnection: PeerConnection): RTCVideoTrack? {
        return chooseBestVideoTrack(peerConnection) { id -> !id.startsWith("screen_") }?.let { RTCVideoTrack(it) }
    }

    fun remoteCameraTrackById(peerConnection: PeerConnection, trackId: String): RTCVideoTrack? {
        return chooseBestVideoTrack(peerConnection) { id -> id == trackId }?.let { RTCVideoTrack(it) }
    }

    fun remoteCameraTrackByMid(peerConnection: PeerConnection, mid: String): RTCVideoTrack? {
        val wantedMid = mid.trim()
        if (wantedMid.isEmpty()) return null
        return chooseBestVideoTrack(peerConnection, mid = wantedMid) { id -> !id.startsWith("screen_") }?.let { RTCVideoTrack(it) }
    }

    fun remoteScreenTrackById(peerConnection: PeerConnection, trackId: String): RTCVideoTrack? {
        return chooseBestVideoTrack(peerConnection) { id -> id == trackId }?.let { RTCVideoTrack(it) }
    }

    /// Resolves the screen receiver by transceiver mid. Remote track ids are immutable: the
    /// contract screen mid's receiver track keeps whatever id it was created with (usually a
    /// UUID minted before the screen msid appeared), so id/prefix predicates can never match
    /// it. The SDP tells us which mid carries `screen_<participant>` media; trust the mid.
    fun remoteScreenTrackByMid(peerConnection: PeerConnection, mid: String): RTCVideoTrack? {
        val wantedMid = mid.trim()
        if (wantedMid.isEmpty()) return null
        return chooseBestVideoTrack(peerConnection, mid = wantedMid) { _ -> true }?.let { RTCVideoTrack(it) }
    }

    fun firstRemoteScreenTrack(peerConnection: PeerConnection): RTCVideoTrack? {
        return chooseBestVideoTrack(peerConnection) { id -> id.startsWith("screen_") }?.let { RTCVideoTrack(it) }
    }

    fun remoteAudioTrackById(peerConnection: PeerConnection, trackId: String): RTCAudioTrack? {
        return chooseAudioTrack(peerConnection, mid = null) { id -> id == trackId }?.let { RTCAudioTrack(it) }
    }

    fun remoteAudioTrackByMid(peerConnection: PeerConnection, mid: String): RTCAudioTrack? {
        val wantedMid = mid.trim()
        if (wantedMid.isEmpty()) return null
        return chooseAudioTrack(peerConnection, mid = wantedMid) { _ -> true }?.let { RTCAudioTrack(it) }
    }

    private fun transceiverMediaTypeOrNull(transceiver: RtpTransceiver): MediaStreamTrack.MediaType? {
        return try {
            transceiver.mediaType
        } catch (_: IllegalStateException) {
            null
        }
    }

    private fun transceiverMidOrNull(transceiver: RtpTransceiver): String? {
        return try {
            transceiver.mid
        } catch (_: IllegalStateException) {
            null
        }
    }

    private fun chooseBestVideoTrack(
        peerConnection: PeerConnection,
        mid: String? = null,
        idPredicate: (String) -> Boolean
    ): VideoTrack? {
        val snapshot = transceivers(peerConnection)
        chooseBestVideoTrack(snapshot, mid, idPredicate)?.let { return it }
        // Every wrapper disposed behind the snapshot means an untracked rotation happened;
        // refresh once (disposing already-dead wrappers is harmless) so resolution recovers
        // without waiting for the next rotation event.
        if (snapshotFullyDisposed(snapshot)) {
            invalidateTransceiverSnapshot(peerConnection)
            return chooseBestVideoTrack(transceivers(peerConnection), mid, idPredicate)
        }
        return null
    }

    private fun chooseBestVideoTrack(
        snapshot: List<RtpTransceiver>,
        mid: String?,
        idPredicate: (String) -> Boolean
    ): VideoTrack? {
        var fallback: VideoTrack? = null
        for (transceiver in snapshot) {
            if (transceiverMediaTypeOrNull(transceiver) != MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) continue
            if (mid != null && transceiverMidOrNull(transceiver) != mid) continue
            val track = try {
                transceiver.getReceiver()?.track() as? VideoTrack
            } catch (_: IllegalStateException) {
                continue
            } ?: continue
            val id = try {
                track.id()
            } catch (_: IllegalStateException) {
                continue
            }
            if (!idPredicate(id)) continue
            val state = try {
                track.state()
            } catch (_: IllegalStateException) {
                fallback = track
                continue
            }
            if (state == MediaStreamTrack.State.LIVE) return track
            if (fallback == null) {
                fallback = track
            }
        }
        return try {
            fallback?.takeIf { it.state() == MediaStreamTrack.State.LIVE }
        } catch (_: IllegalStateException) {
            null
        }
    }

    private fun chooseAudioTrack(
        peerConnection: PeerConnection,
        mid: String?,
        idPredicate: (String) -> Boolean
    ): AudioTrack? {
        for (transceiver in transceivers(peerConnection)) {
            if (transceiverMediaTypeOrNull(transceiver) != MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO) continue
            if (mid != null && transceiverMidOrNull(transceiver) != mid) continue
            val track = try {
                transceiver.getReceiver()?.track() as? AudioTrack
            } catch (_: IllegalStateException) {
                continue
            } ?: continue
            val id = try {
                track.id()
            } catch (_: IllegalStateException) {
                continue
            }
            if (!idPredicate(id)) continue
            return track
        }
        return null
    }

    private fun snapshotFullyDisposed(snapshot: List<RtpTransceiver>): Boolean {
        if (snapshot.isEmpty()) return false
        for (transceiver in snapshot) {
            if (transceiverMediaTypeOrNull(transceiver) != null) return false
        }
        return true
    }
}
