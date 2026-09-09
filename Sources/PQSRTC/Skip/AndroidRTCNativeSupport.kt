package pqsrtc.module

import android.content.res.Configuration
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.PixelFormat
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Range
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import kotlin.math.max
import kotlin.math.min
import org.webrtc.AudioTrack
import org.webrtc.CameraVideoCapturer
import org.webrtc.CapturerObserver
import org.webrtc.EglBase
import org.webrtc.EglRenderer
import org.webrtc.FrameCryptor
import org.webrtc.FrameCryptorAlgorithm
import org.webrtc.FrameCryptorFactory
import org.webrtc.FrameCryptorKeyProvider
import org.webrtc.GlShader
import org.webrtc.GlUtil
import org.webrtc.JavaI420Buffer
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RendererCommon
import org.webrtc.RtpReceiver
import org.webrtc.RtpSender
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import org.webrtc.YuvHelper
import skip.foundation.ProcessInfo
import java.nio.FloatBuffer
import java.util.ConcurrentModificationException
import java.util.WeakHashMap
import java.util.concurrent.CountDownLatch

/**
 * Applies local SDP on the raw Java [PeerConnection].
 *
 * Skip's `RTCPeerConnection` wrapper has no `setLocalDescription`. A Skip-bridged Swift
 * `SdpObserver` also parks answer `createAnswer` when signaling goes STABLE during JNI.
 * This wait is Java-to-Java: native `onSetSuccess` / `onSetFailure` counts down the latch.
 */
object AndroidNativeSetLocalDescription {
    fun applyAndWait(peerConnection: PeerConnection, sdp: SessionDescription): String? {
        val errorHolder = arrayOfNulls<String>(1)
        val latch = CountDownLatch(1)
        val observer = object : SdpObserver {
            override fun onSetSuccess() {
                Log.i("AndroidRTCClient", "setLocalDescription completed via kotlin-observer")
                latch.countDown()
            }

            override fun onSetFailure(error: String?) {
                Log.e("AndroidRTCClient", "setLocalDescription failed: $error")
                errorHolder[0] = error ?: "set description failed"
                latch.countDown()
            }

            override fun onCreateSuccess(desc: SessionDescription?) {}

            override fun onCreateFailure(error: String?) {}
        }
        peerConnection.setLocalDescription(observer, sdp)
        latch.await()
        return errorHolder[0]
    }
}

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

    fun shouldReuseAudioReceiverCryptorBinding(
        existingTrackId: String?,
        newTrackId: String,
    ): Boolean {
        return newTrackId.isNotEmpty() && existingTrackId == newTrackId
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

/// Skin-weighted luma blur on a worker. A 5-tap at 1280×720 is ~1 px after
/// the local overlay downscales to ~367 px (Device3 17:57: I420Softened
/// logged, user still saw no filter). Blur a 1/4 plane then upsample so the
/// look matches iOS Gaussian σ≈min(w,h)/240 on the small tile.
private class VideoAppearanceFrameSoftening {
    private val blurWeight = 45
    private val downScale = 4
    private var luma = ByteArray(0)
    private var blurTmp = ByteArray(0)
    private var downLuma = ByteArray(0)
    private var downBlur = ByteArray(0)
    private var rowBuf = ByteArray(0)
    private var chromaU = ByteArray(0)
    private var chromaV = ByteArray(0)
    private var skinWeight = ByteArray(0)
    private var loggedFirstSoften = false

    fun resetDiagnostics() {
        loggedFirstSoften = false
    }

    fun soften(frame: VideoFrame): VideoFrame? {
        val src = frame.buffer.toI420() ?: return null
        val w = src.width
        val h = src.height
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        val dw = max(1, w / downScale)
        val dh = max(1, h / downScale)
        val dst = JavaI420Buffer.allocate(w, h)
        computeSkinWeights(src.dataU, src.strideU, src.dataV, src.strideV, cw, ch)
        if (!loggedFirstSoften) {
            loggedFirstSoften = true
            val n = cw * ch
            var skin = 0
            var i = 0
            while (i < n) {
                if ((skinWeight[i].toInt() and 0xFF) > 0) {
                    skin++
                }
                i++
            }
            val skinPct = if (n > 0) (skin * 100) / n else 0
            Log.i(
                "AndroidRTCClient",
                "Appearance softening first frame ${w}x${h} down=${dw}x${dh} skinPct=$skinPct",
            )
        }
        softenYPlane(src.dataY, src.strideY, dst.dataY, dst.strideY, w, h, cw, dw, dh)
        copyPlane(src.dataU, src.strideU, dst.dataU, dst.strideU, cw, ch)
        copyPlane(src.dataV, src.strideV, dst.dataV, dst.strideV, cw, ch)
        src.release()
        return VideoFrame(dst, frame.rotation, frame.timestampNs)
    }

    private fun computeSkinWeights(
        u: java.nio.ByteBuffer,
        uStride: Int,
        v: java.nio.ByteBuffer,
        vStride: Int,
        cw: Int,
        ch: Int,
    ) {
        val n = cw * ch
        if (chromaU.size < n) {
            chromaU = ByteArray(n)
            chromaV = ByteArray(n)
            skinWeight = ByteArray(n)
        }
        val us = u.duplicate()
        val vs = v.duplicate()
        var row = 0
        while (row < ch) {
            us.position(row * uStride)
            us.get(chromaU, row * cw, cw)
            vs.position(row * vStride)
            vs.get(chromaV, row * cw, cw)
            row++
        }
        var i = 0
        while (i < n) {
            val cb = chromaU[i].toInt() and 0xFF
            val cr = chromaV[i].toInt() and 0xFF
            val dcb = cb - 102
            val dcr = cr - 153
            val dist = (dcb * dcb * 100) / 625 + (dcr * dcr * 100) / 400
            val wgt = when {
                dist >= 160 -> 0
                dist <= 70 -> blurWeight
                else -> (blurWeight * (160 - dist)) / 90
            }
            skinWeight[i] = wgt.toByte()
            i++
        }
    }

    private fun copyPlane(
        src: java.nio.ByteBuffer,
        srcStride: Int,
        dst: java.nio.ByteBuffer,
        dstStride: Int,
        width: Int,
        height: Int,
    ) {
        val s = src.duplicate()
        val d = dst.duplicate()
        if (rowBuf.size < width) {
            rowBuf = ByteArray(width)
        }
        var row = 0
        while (row < height) {
            s.position(row * srcStride)
            s.get(rowBuf, 0, width)
            d.position(row * dstStride)
            d.put(rowBuf, 0, width)
            row++
        }
    }

    private fun softenYPlane(
        src: java.nio.ByteBuffer,
        srcStride: Int,
        dst: java.nio.ByteBuffer,
        dstStride: Int,
        width: Int,
        height: Int,
        chromaWidth: Int,
        downWidth: Int,
        downHeight: Int,
    ) {
        val n = width * height
        if (luma.size < n) {
            luma = ByteArray(n)
            blurTmp = ByteArray(n)
        }
        val downN = downWidth * downHeight
        if (downLuma.size < downN) {
            downLuma = ByteArray(downN)
            downBlur = ByteArray(downN)
        }
        val s = src.duplicate()
        var copyRow = 0
        while (copyRow < height) {
            s.position(copyRow * srcStride)
            s.get(luma, copyRow * width, width)
            copyRow++
        }
        downsampleBox(luma, width, height, downLuma, downWidth, downHeight)
        // Two 5-tap passes on the 1/4 plane ≈ iOS Gaussian, without a full-res
        // kernel. Do not `for (dx in -2..2)` — IntRange per pixel GC (lesson 42).
        boxBlur5(downLuma, downBlur, downWidth, downHeight)
        boxBlur5(downLuma, downBlur, downWidth, downHeight)
        upsampleBilinear(downLuma, downWidth, downHeight, blurTmp, width, height)
        var blendRow = 0
        while (blendRow < height) {
            val base = blendRow * width
            val chromaRowBase = (blendRow / 2) * chromaWidth
            var x = 0
            while (x < width) {
                val original = luma[base + x].toInt() and 0xFF
                if (original >= 40 && original <= 250) {
                    val mask = skinWeight[chromaRowBase + (x / 2)].toInt() and 0xFF
                    if (mask > 0) {
                        val blurred = blurTmp[base + x].toInt() and 0xFF
                        luma[base + x] =
                            ((original * (100 - mask) + blurred * mask) / 100).toByte()
                    }
                }
                x++
            }
            blendRow++
        }
        val d = dst.duplicate()
        var writeRow = 0
        while (writeRow < height) {
            d.position(writeRow * dstStride)
            d.put(luma, writeRow * width, width)
            writeRow++
        }
    }

    private fun downsampleBox(
        src: ByteArray,
        srcWidth: Int,
        srcHeight: Int,
        dst: ByteArray,
        dstWidth: Int,
        dstHeight: Int,
    ) {
        var y = 0
        while (y < dstHeight) {
            val y0 = y * srcHeight / dstHeight
            var y1 = (y + 1) * srcHeight / dstHeight
            if (y1 <= y0) {
                y1 = y0 + 1
            }
            if (y1 > srcHeight) {
                y1 = srcHeight
            }
            var x = 0
            while (x < dstWidth) {
                val x0 = x * srcWidth / dstWidth
                var x1 = (x + 1) * srcWidth / dstWidth
                if (x1 <= x0) {
                    x1 = x0 + 1
                }
                if (x1 > srcWidth) {
                    x1 = srcWidth
                }
                var sum = 0
                var count = 0
                var yy = y0
                while (yy < y1) {
                    val row = yy * srcWidth
                    var xx = x0
                    while (xx < x1) {
                        sum += src[row + xx].toInt() and 0xFF
                        count++
                        xx++
                    }
                    yy++
                }
                dst[y * dstWidth + x] = (sum / max(1, count)).toByte()
                x++
            }
            y++
        }
    }

    private fun boxBlur5(src: ByteArray, tmp: ByteArray, width: Int, height: Int) {
        var row = 0
        while (row < height) {
            val base = row * width
            var x = 0
            while (x < width) {
                var sum = 0
                var dx = -2
                while (dx <= 2) {
                    var nx = x + dx
                    if (nx < 0) nx = 0
                    if (nx > width - 1) nx = width - 1
                    sum += src[base + nx].toInt() and 0xFF
                    dx++
                }
                tmp[base + x] = (sum / 5).toByte()
                x++
            }
            row++
        }
        var col = 0
        while (col < width) {
            var y = 0
            while (y < height) {
                var sum = 0
                var dy = -2
                while (dy <= 2) {
                    var ny = y + dy
                    if (ny < 0) ny = 0
                    if (ny > height - 1) ny = height - 1
                    sum += tmp[ny * width + col].toInt() and 0xFF
                    dy++
                }
                src[y * width + col] = (sum / 5).toByte()
                y++
            }
            col++
        }
    }

    private fun upsampleBilinear(
        src: ByteArray,
        srcWidth: Int,
        srcHeight: Int,
        dst: ByteArray,
        dstWidth: Int,
        dstHeight: Int,
    ) {
        if (srcWidth <= 1 || srcHeight <= 1 || dstWidth <= 1 || dstHeight <= 1) {
            var y = 0
            while (y < dstHeight) {
                val sy = min(srcHeight - 1, y * srcHeight / max(1, dstHeight))
                val srcRow = sy * srcWidth
                val dstRow = y * dstWidth
                var x = 0
                while (x < dstWidth) {
                    val sx = min(srcWidth - 1, x * srcWidth / max(1, dstWidth))
                    dst[dstRow + x] = src[srcRow + sx]
                    x++
                }
                y++
            }
            return
        }
        val xScale = (srcWidth - 1).toFloat() / (dstWidth - 1).toFloat()
        val yScale = (srcHeight - 1).toFloat() / (dstHeight - 1).toFloat()
        var y = 0
        while (y < dstHeight) {
            val fy = y * yScale
            val y0 = fy.toInt()
            var y1 = y0 + 1
            if (y1 > srcHeight - 1) {
                y1 = srcHeight - 1
            }
            val ty = fy - y0
            val dstRow = y * dstWidth
            var x = 0
            while (x < dstWidth) {
                val fx = x * xScale
                val x0 = fx.toInt()
                var x1 = x0 + 1
                if (x1 > srcWidth - 1) {
                    x1 = srcWidth - 1
                }
                val tx = fx - x0
                val p00 = src[y0 * srcWidth + x0].toInt() and 0xFF
                val p10 = src[y0 * srcWidth + x1].toInt() and 0xFF
                val p01 = src[y1 * srcWidth + x0].toInt() and 0xFF
                val p11 = src[y1 * srcWidth + x1].toInt() and 0xFF
                val top = p00 + (p10 - p00) * tx
                val bot = p01 + (p11 - p01) * tx
                dst[dstRow + x] = (top + (bot - top) * ty).toInt().toByte()
                x++
            }
            y++
        }
    }
}

/// Preview and VideoSource keep the camera TextureBuffer when softening is off.
/// When Settings softening is on, the worker `toI420`s (not on the shared
/// capturer EglBase — lesson 26) and both preview and send get I420.
/// Device3 13:16 I420+TextureView skipped; revision-g SurfaceView is the compositor.
object CameraCaptureFrameRouter {
    private val lock = Any()
    private val softening = VideoAppearanceFrameSoftening()
    private var pending: VideoFrame? = null
    private var pendingDownstream: CapturerObserver? = null
    private var inFlight = false
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var loggedPipeline = false

    fun deliver(
        frame: VideoFrame,
        normalizeToUpright: Boolean,
        allowAppearanceSoftening: Boolean,
        fanOutLocalPreview: Boolean,
        downstream: CapturerObserver,
    ) {
        val hardwarePreview = AndroidRTCViewSupport.isCamera2PreviewSurfaceAttached()
        val soften =
            AndroidRTCViewSupport.ANDROID_CPU_APPEARANCE_SOFTENING &&
                allowAppearanceSoftening &&
                AndroidCaptureUIPreferenceCache.isVideoAppearanceSofteningEnabled()
        if (!loggedPipeline) {
            loggedPipeline = true
            val previewKind = when {
                hardwarePreview -> "Camera2Surface"
                fanOutLocalPreview && soften -> "I420Softened"
                fanOutLocalPreview -> "TextureBuffer"
                else -> "none"
            }
            val sendKind = if (soften) "I420Softened" else "TextureBuffer"
            Log.i(
                "AndroidRTCClient",
                "Camera capture pipeline revision=" +
                    AndroidRTCViewSupport.LOCAL_PREVIEW_PIPELINE_REVISION +
                    " cpuSoften=$soften hardwarePreview=$hardwarePreview " +
                    "fanOut=$fanOutLocalPreview preview=$previewKind send=$sendKind",
            )
        }
        // Soften on the worker. Do not fan the TextureBuffer and toI420 it
        // on the shared EglBase (lesson 26). Preview gets the softened I420.
        if (fanOutLocalPreview && !hardwarePreview && !soften) {
            AndroidRTCViewSupport.deliverLocalPreviewCaptureFrame(frame)
        }
        if (soften) {
            enqueueSoftenAndSend(
                frame,
                downstream,
                fanPreview = fanOutLocalPreview && !hardwarePreview,
            )
        } else {
            downstream.onFrameCaptured(frame)
        }
    }

    fun stop() {
        val dropped: VideoFrame?
        val worker: HandlerThread?
        synchronized(lock) {
            dropped = pending
            pending = null
            pendingDownstream = null
            pendingFanPreview = false
            inFlight = false
            loggedPipeline = false
            softening.resetDiagnostics()
            worker = thread
            thread = null
            handler = null
        }
        dropped?.release()
        worker?.quitSafely()
    }

    private var pendingFanPreview = false

    private fun enqueueSoftenAndSend(
        frame: VideoFrame,
        downstream: CapturerObserver,
        fanPreview: Boolean,
    ) {
        frame.retain()
        val posted: Boolean
        synchronized(lock) {
            pending?.release()
            pending = frame
            pendingDownstream = downstream
            pendingFanPreview = fanPreview
            if (inFlight) {
                posted = false
            } else {
                inFlight = true
                posted = true
            }
        }
        if (posted) {
            softenHandler().post { drainSoften() }
        }
    }

    private fun softenHandler(): Handler {
        synchronized(lock) {
            handler?.let { return it }
            val next = HandlerThread("pqsr-camera-soften")
            next.start()
            val created = Handler(next.looper)
            thread = next
            handler = created
            return created
        }
    }

    private fun drainSoften() {
        while (true) {
            val next: VideoFrame
            val dest: CapturerObserver
            val fanPreview: Boolean
            synchronized(lock) {
                val pendingFrame = pending
                val pendingDest = pendingDownstream
                if (pendingFrame == null || pendingDest == null) {
                    inFlight = false
                    return
                }
                pending = null
                pendingDownstream = null
                fanPreview = pendingFanPreview
                next = pendingFrame
                dest = pendingDest
            }
            try {
                val softened = softening.soften(next)
                val outgoing = softened ?: next
                if (fanPreview) {
                    AndroidRTCViewSupport.deliverLocalPreviewCaptureFrame(outgoing)
                }
                dest.onFrameCaptured(outgoing)
                if (softened != null) {
                    softened.release()
                }
            } catch (error: Throwable) {
                Log.w("AndroidRTCClient", "Appearance softening failed; sending raw frame", error)
                try {
                    if (fanPreview) {
                        AndroidRTCViewSupport.deliverLocalPreviewCaptureFrame(next)
                    }
                    dest.onFrameCaptured(next)
                } catch (_: Throwable) {
                }
            } finally {
                next.release()
            }
        }
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

    fun isLikelyTransientRotationSurfaceMeasure(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
    ): Boolean {
        return previousWidth > 0
            && previousHeight > 0
            && newWidth > 0
            && newHeight > 0
            && previousWidth != newWidth
            && previousHeight != newHeight
    }

    fun isLikelyFullscreenHost(
        hostWidth: Int,
        hostHeight: Int,
        windowWidth: Int,
        windowHeight: Int,
    ): Boolean {
        if (hostWidth <= 0 || hostHeight <= 0 || windowWidth <= 0 || windowHeight <= 0) {
            return false
        }
        return hostWidth * 10 >= windowWidth * 9 && hostHeight * 10 >= windowHeight * 9
    }

    fun isLikelyUnsettledFragmentHost(
        hostWidth: Int,
        hostHeight: Int,
        windowWidth: Int,
        windowHeight: Int,
    ): Boolean {
        if (hostWidth <= 0 || hostHeight <= 0 || windowWidth <= 0 || windowHeight <= 0) {
            return true
        }
        return hostWidth * hostHeight * 8 < windowWidth * windowHeight
    }

    @Suppress("UNUSED_PARAMETER")
    fun shouldDeferAspectFitWrapContent(
        preferFit: Boolean,
        windowOrientationMatchesConfiguration: Boolean,
        hostWidth: Int,
        hostHeight: Int,
        windowWidth: Int,
        windowHeight: Int,
        previousHostWidth: Int,
        previousHostHeight: Int,
    ): Boolean {
        // Dual-axis 1-up → 16:9 (1080×2520 → 1002×564) is a settled conference
        // tile, not a rotation fragment. Letterbox in this apply; previous size
        // is unused once fullscreen leftover and fragment hosts are filtered.
        if (!preferFit) return false
        if (!windowOrientationMatchesConfiguration) return true
        if (hostWidth <= 0 || hostHeight <= 0) return true
        if (isLikelyFullscreenHost(hostWidth, hostHeight, windowWidth, windowHeight)) {
            return true
        }
        if (isLikelyUnsettledFragmentHost(hostWidth, hostHeight, windowWidth, windowHeight)) {
            return true
        }
        return false
    }

    fun letterboxExactSize(
        frameWidth: Int,
        frameHeight: Int,
        frameRotation: Int,
        hostWidth: Int,
        hostHeight: Int,
    ): Pair<Int, Int> {
        if (frameWidth <= 0 || frameHeight <= 0 || hostWidth <= 0 || hostHeight <= 0) {
            return Pair(0, 0)
        }
        var rotation = frameRotation % 360
        if (rotation < 0) rotation += 360
        val uprightWidth = if (rotation == 90 || rotation == 270) frameHeight else frameWidth
        val uprightHeight = if (rotation == 90 || rotation == 270) frameWidth else frameHeight
        return if (uprightWidth * hostHeight > uprightHeight * hostWidth) {
            val fittedHeight = maxOf(1, hostWidth * uprightHeight / uprightWidth)
            Pair(hostWidth, minOf(hostHeight, fittedHeight))
        } else {
            val fittedWidth = maxOf(1, hostHeight * uprightWidth / uprightHeight)
            Pair(minOf(hostWidth, fittedWidth), hostHeight)
        }
    }

    fun isLikelyAspectFitWrapSurfaceMeasure(
        surfaceWidth: Int,
        surfaceHeight: Int,
        tileWidth: Int,
        tileHeight: Int,
    ): Boolean {
        if (surfaceWidth <= 0 || surfaceHeight <= 0 || tileWidth <= 0 || tileHeight <= 0) {
            return false
        }
        if (surfaceWidth == tileWidth && surfaceHeight == tileHeight) return false
        if (surfaceWidth > tileWidth || surfaceHeight > tileHeight) return false
        return (surfaceWidth == tileWidth && surfaceHeight < tileHeight)
            || (surfaceHeight == tileHeight && surfaceWidth < tileWidth)
    }

    @Suppress("UNUSED_PARAMETER")
    fun shouldReinitRendererEglForImmediateHolderResize(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
        windowOrientationMatchesConfiguration: Boolean = false,
        tileWidth: Int = 0,
        tileHeight: Int = 0,
    ): Boolean {
        if (newWidth <= 0 || newHeight <= 0) return false
        if (previousWidth <= 0 || previousHeight <= 0) return false
        if (previousWidth == newWidth && previousHeight == newHeight) return false
        if (isLikelyTransientRotationSurfaceMeasure(
                previousWidth,
                previousHeight,
                newWidth,
                newHeight,
            )
        ) {
            return false
        }
        if (isLikelyAspectFitWrapSurfaceMeasure(
                newWidth,
                newHeight,
                tileWidth,
                tileHeight,
            )
        ) {
            return false
        }
        if (tileWidth > 0 && tileHeight > 0 &&
            (newWidth != tileWidth || newHeight != tileHeight)
        ) {
            return false
        }
        return true
    }

    fun shouldReinitRendererEglAfterComposeLayoutSettled(
        viewWidth: Int,
        viewHeight: Int,
        lastRendererWidth: Int,
        lastRendererHeight: Int,
        eglNeedsResync: Boolean,
        windowOrientationMatchesConfiguration: Boolean,
    ): Boolean {
        if (!eglNeedsResync) return false
        if (viewWidth <= 0 || viewHeight <= 0) return false
        if (!windowOrientationMatchesConfiguration) return false
        return viewWidth == lastRendererWidth && viewHeight == lastRendererHeight
    }

    /// Attach / sink-reconcile must not undo `surface_holder_rotation_skip`.
    fun shouldAllowAttachDrivenEglReinit(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
        eglNeedsResync: Boolean,
        windowOrientationMatchesConfiguration: Boolean,
        tileWidth: Int,
        tileHeight: Int,
        lastRendererWidth: Int,
        lastRendererHeight: Int,
    ): Boolean {
        if (!eglNeedsResync) return false
        if (isLikelyTransientRotationSurfaceMeasure(
                previousWidth,
                previousHeight,
                newWidth,
                newHeight,
            )
        ) {
            return false
        }
        if (isLikelyAspectFitWrapSurfaceMeasure(
                newWidth,
                newHeight,
                tileWidth,
                tileHeight,
            )
        ) {
            return false
        }
        if (tileWidth > 0 && tileHeight > 0 &&
            (newWidth != tileWidth || newHeight != tileHeight)
        ) {
            return false
        }
        return shouldReinitRendererEglAfterComposeLayoutSettled(
            viewWidth = newWidth,
            viewHeight = newHeight,
            lastRendererWidth = lastRendererWidth,
            lastRendererHeight = lastRendererHeight,
            eglNeedsResync = true,
            windowOrientationMatchesConfiguration = windowOrientationMatchesConfiguration,
        )
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
    /// Camera2 `startCapture(..., fps)` picks the closest AE range. Requesting 15
    /// locks Device3 to `[15.0:15.0]` (06:11:09: LocalPreview 60/0/60 at 15.0,
    /// `Camera fps: 15`). 30 selects `[15.0:30.0]`. WebRTC then prefers a low
    /// min so AE can float (06:51: Camera 17–26). Own the request here, then
    /// `lockOpenedCamera2ToFixedFpsIfNeeded` forces `[30:30]` on first frame.
    const val LOCAL_CAMERA_CAPTURE_FPS = 30

    /// Device3 16:20 (pid 1303): TextureBuffer + shared EglBase rendered
    /// 120/0/120 at 30.0 in ~500 µs and still looked skippy. The PiP was a
    /// TextureView over a full-screen remote SurfaceView hole-punch. Bump
    /// when the local capture / preview pipeline changes.
    const val LOCAL_PREVIEW_PIPELINE_REVISION = "2026-09-09-j"

    /// Device3 09:49: `Attached Camera2 preview surface 1280x720` then 90° /
    /// smaller PiP; camera floated 13–26 fps; LocalPreview EGL 0 frames; GC
    /// still ~2.8M objects / 3s. Do not bind the TextureView as a Camera2
    /// output again without a proven transform + fill.
    const val USE_CAMERA2_PREVIEW_SURFACE = false

    /// Settings "Soften video appearance" (default on). Runs on the worker
    /// after TextureBuffer fanout is skipped, so preview and send both get
    /// I420 without toI420 on the shared capturer EglBase (lesson 26).
    const val ANDROID_CPU_APPEARANCE_SOFTENING = true

    @Volatile
    private var openedCameraCapturer: CameraVideoCapturer? = null

    @Volatile
    private var lockedOpenedCamera2Fps = false

    @Volatile
    private var camera2PreviewAttached = false

    @Volatile
    private var camera2OutputGeneration = 0

    @Volatile
    private var camera2SessionNeedsWebrtcOnlyRestore = false

    @Volatile
    private var openedPreviewRenderer: LocalPreviewTextureRenderer? = null

    @Volatile
    private var openedPreviewTexture: SurfaceTexture? = null

    @Volatile
    private var openedPreviewSurface: Surface? = null

    @Volatile
    private var openedCaptureWidth = 1280

    @Volatile
    private var openedCaptureHeight = 720

    private var previewBufferWidth = 0
    private var previewBufferHeight = 0
    private var previewSensorOrientation = 0
    private var previewFrontFacing = true

    private val rendererFirstFrameCallbacks = WeakHashMap<SurfaceViewRenderer, () -> Unit>()
    private val rendererFirstFrameHandlerGenerations = WeakHashMap<SurfaceViewRenderer, Int>()
    private val rendererFirstFrameHandlers = WeakHashMap<SurfaceViewRenderer, (Int) -> Unit>()

    fun startLocalCameraCapture(
        capturer: CameraVideoCapturer,
        width: Int,
        height: Int,
    ) {
        val fps = LOCAL_CAMERA_CAPTURE_FPS
        openedCameraCapturer = capturer
        openedCaptureWidth = width
        openedCaptureHeight = height
        lockedOpenedCamera2Fps = false
        camera2PreviewAttached = false
        camera2OutputGeneration += 1
        openedPreviewSurface?.release()
        openedPreviewSurface = null
        Log.i("AndroidRTCClient", "Starting camera capture: ${width}x${height}@${fps}fps")
        capturer.startCapture(width, height, fps)
    }

    fun clearOpenedCameraCapturer() {
        camera2OutputGeneration += 1
        openedCameraCapturer = null
        lockedOpenedCamera2Fps = false
        camera2PreviewAttached = false
        camera2SessionNeedsWebrtcOnlyRestore = false
        openedPreviewSurface?.release()
        openedPreviewSurface = null
        CameraCaptureFrameRouter.stop()
    }

    fun isCamera2PreviewSurfaceAttached(): Boolean = camera2PreviewAttached

    fun registerLocalPreviewRenderer(renderer: LocalPreviewTextureRenderer) {
        openedPreviewRenderer = renderer
    }

    fun registerLocalPreviewCameraSurface(
        renderer: LocalPreviewTextureRenderer,
        texture: SurfaceTexture,
    ) {
        if (!USE_CAMERA2_PREVIEW_SURFACE) return
        openedPreviewRenderer = renderer
        openedPreviewTexture = texture
        applyOpenedCamera2OutputsIfNeeded()
    }

    fun unregisterLocalPreviewCameraSurface(renderer: LocalPreviewTextureRenderer) {
        if (openedPreviewRenderer !== renderer) return
        val wasAttached = camera2PreviewAttached
        camera2PreviewAttached = false
        openedPreviewTexture = null
        openedPreviewSurface?.release()
        openedPreviewSurface = null
        openedPreviewRenderer = null
        if (wasAttached && openedCameraCapturer != null) {
            camera2SessionNeedsWebrtcOnlyRestore = true
            lockedOpenedCamera2Fps = false
            applyOpenedCamera2OutputsIfNeeded()
        }
    }

    fun attachOpenedCamera2PreviewSurfaceIfNeeded() {
        applyOpenedCamera2OutputsIfNeeded()
    }

    /// WebRTC `getClosestSupportedFramerateRange` prefers a low min (lighting
    /// headroom), so Device3's `[15.0:30.0]` never holds 30. After the session
    /// exists, rewrite the repeating request to `[30:30]`. When the TextureView
    /// SurfaceTexture is ready, recreate the session with that surface as a
    /// second Camera2 output (Apple `AVCaptureVideoPreviewLayer` equivalent).
    fun lockOpenedCamera2ToFixedFpsIfNeeded() {
        applyOpenedCamera2OutputsIfNeeded()
    }

    private fun applyOpenedCamera2OutputsIfNeeded() {
        val capturer = openedCameraCapturer ?: return
        try {
            val sessionField = declaredFieldOnHierarchy(capturer.javaClass, "currentSession")
                ?: return
            sessionField.isAccessible = true
            val session = sessionField.get(capturer) ?: return
            if (session.javaClass.name != "org.webrtc.Camera2Session") return
            val handlerField = session.javaClass.getDeclaredField("cameraThreadHandler")
            handlerField.isAccessible = true
            val cameraHandler = handlerField.get(session) as? Handler
            val apply = Runnable { applyOpenedCamera2OutputsOnCameraThread(session) }
            if (cameraHandler != null) {
                cameraHandler.post(apply)
            } else {
                apply.run()
            }
        } catch (error: Throwable) {
            Log.w("AndroidRTCClient", "Unable to apply Camera2 session outputs", error)
        }
    }

    private fun declaredFieldOnHierarchy(type: Class<*>, name: String): java.lang.reflect.Field? {
        var current: Class<*>? = type
        while (current != null) {
            try {
                return current.getDeclaredField(name)
            } catch (_: NoSuchFieldException) {
                current = current.superclass
            }
        }
        return null
    }

    private fun applyOpenedCamera2OutputsOnCameraThread(session: Any) {
        val wantPreview =
            USE_CAMERA2_PREVIEW_SURFACE &&
                openedPreviewTexture != null &&
                !camera2PreviewAttached
        val restoreWebrtcOnly = camera2SessionNeedsWebrtcOnlyRestore
        camera2SessionNeedsWebrtcOnlyRestore = false
        val wantFps = !lockedOpenedCamera2Fps
        Log.i(
            "AndroidRTCClient",
            "applyOpenedCamera2Outputs revision=$LOCAL_PREVIEW_PIPELINE_REVISION " +
                "wantPreview=$wantPreview hasTexture=${openedPreviewTexture != null} " +
                "previewAttached=$camera2PreviewAttached wantFps=$wantFps restoreWebrtcOnly=$restoreWebrtcOnly",
        )
        if (!wantPreview && !restoreWebrtcOnly && !wantFps) {
            postToMainThread { applyLocalPreviewCamera2Transform() }
            return
        }
        if (wantPreview || restoreWebrtcOnly) {
            recreateOpenedCamera2Session(session, includePreview = wantPreview)
            return
        }
        applyFixedFpsRangeOnCameraThread(session)
    }

    private fun recreateOpenedCamera2Session(session: Any, includePreview: Boolean) {
        val generation = camera2OutputGeneration
        try {
            val deviceField = session.javaClass.getDeclaredField("cameraDevice")
            val surfaceField = session.javaClass.getDeclaredField("surface")
            val captureField = session.javaClass.getDeclaredField("captureSession")
            val characteristicsField = session.javaClass.getDeclaredField("cameraCharacteristics")
            deviceField.isAccessible = true
            surfaceField.isAccessible = true
            captureField.isAccessible = true
            characteristicsField.isAccessible = true
            val device = deviceField.get(session) as? CameraDevice ?: return
            val webrtcSurface = surfaceField.get(session) as? Surface ?: return
            val characteristics = characteristicsField.get(session) as? CameraCharacteristics
            val handlerField = session.javaClass.getDeclaredField("cameraThreadHandler")
            handlerField.isAccessible = true
            val cameraHandler = handlerField.get(session) as? Handler

            val (bufferWidth, bufferHeight) = camera2CaptureSize(session)
            previewBufferWidth = bufferWidth
            previewBufferHeight = bufferHeight
            previewSensorOrientation = camera2IntField(session, "cameraOrientation")
                ?: characteristics?.get(CameraCharacteristics.SENSOR_ORIENTATION)
                ?: 0
            previewFrontFacing = camera2BooleanField(session, "isCameraFrontFacing")
                ?: (characteristics?.get(CameraCharacteristics.LENS_FACING)
                    == CameraCharacteristics.LENS_FACING_FRONT)

            val outputs = mutableListOf(webrtcSurface)
            var previewSurface: Surface? = null
            val previewTexture = if (includePreview) openedPreviewTexture else null
            if (previewTexture != null) {
                previewTexture.setDefaultBufferSize(bufferWidth, bufferHeight)
                val created = Surface(previewTexture)
                if (created.isValid) {
                    previewSurface = created
                    outputs.add(created)
                } else {
                    created.release()
                }
            }

            val callback = object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(newSession: CameraCaptureSession) {
                    if (generation != camera2OutputGeneration) {
                        previewSurface?.release()
                        return
                    }
                    try {
                        captureField.set(session, newSession)
                        openedPreviewSurface?.let { previous ->
                            if (previous !== previewSurface) {
                                previous.release()
                            }
                        }
                        openedPreviewSurface = previewSurface
                        startRepeatingOnCameraSession(
                            session = session,
                            captureSession = newSession,
                            extraPreview = previewSurface,
                        )
                        lockedOpenedCamera2Fps = true
                        camera2PreviewAttached = previewSurface != null
                        if (previewSurface != null) {
                            Log.i(
                                "AndroidRTCClient",
                                "Attached Camera2 preview surface ${bufferWidth}x${bufferHeight}",
                            )
                            Log.i(
                                "AndroidRTCClient",
                                "Locked Camera2 AE fps range to [$LOCAL_CAMERA_CAPTURE_FPS:$LOCAL_CAMERA_CAPTURE_FPS]",
                            )
                            val renderer = openedPreviewRenderer
                            postToMainThread {
                                renderer?.markCamera2PreviewAttached()
                            }
                        } else {
                            Log.i(
                                "AndroidRTCClient",
                                "Locked Camera2 AE fps range to [$LOCAL_CAMERA_CAPTURE_FPS:$LOCAL_CAMERA_CAPTURE_FPS]",
                            )
                        }
                    } catch (error: Throwable) {
                        previewSurface?.release()
                        openedPreviewSurface = null
                        camera2PreviewAttached = false
                        Log.w("AndroidRTCClient", "Failed to start Camera2 outputs", error)
                        fallbackLocalPreviewToEglI420()
                    }
                }

                override fun onConfigureFailed(newSession: CameraCaptureSession) {
                    previewSurface?.release()
                    if (generation != camera2OutputGeneration) return
                    openedPreviewSurface = null
                    camera2PreviewAttached = false
                    Log.w(
                        "AndroidRTCClient",
                        "Failed to attach Camera2 preview surface; using I420 TextureView",
                    )
                    if (includePreview) {
                        recreateOpenedCamera2Session(session, includePreview = false)
                    }
                    fallbackLocalPreviewToEglI420()
                }
            }
            if (cameraHandler != null) {
                device.createCaptureSession(outputs, callback, cameraHandler)
            } else {
                device.createCaptureSession(outputs, callback, null)
            }
        } catch (error: Throwable) {
            Log.w("AndroidRTCClient", "Failed to recreate Camera2 session", error)
            if (includePreview) {
                try {
                    applyFixedFpsRangeOnCameraThread(session)
                } catch (_: Throwable) {
                }
            }
            fallbackLocalPreviewToEglI420()
        }
    }

    private fun fallbackLocalPreviewToEglI420() {
        camera2PreviewAttached = false
        val renderer = openedPreviewRenderer
        postToMainThread {
            renderer?.initializeEglFallback()
        }
    }

    private fun camera2CaptureSize(session: Any): Pair<Int, Int> {
        return try {
            val formatField = session.javaClass.getDeclaredField("captureFormat")
            formatField.isAccessible = true
            val format = formatField.get(session)
            if (format != null) {
                val widthField = format.javaClass.getField("width")
                val heightField = format.javaClass.getField("height")
                Pair(widthField.getInt(format), heightField.getInt(format))
            } else {
                Pair(openedCaptureWidth, openedCaptureHeight)
            }
        } catch (_: Throwable) {
            Pair(openedCaptureWidth, openedCaptureHeight)
        }
    }

    private fun camera2IntField(session: Any, name: String): Int? {
        return try {
            val field = session.javaClass.getDeclaredField(name)
            field.isAccessible = true
            field.getInt(session)
        } catch (_: Throwable) {
            null
        }
    }

    private fun camera2BooleanField(session: Any, name: String): Boolean? {
        return try {
            val field = session.javaClass.getDeclaredField(name)
            field.isAccessible = true
            field.getBoolean(session)
        } catch (_: Throwable) {
            null
        }
    }

    fun applyLocalPreviewCamera2Transform() {
        val view = openedPreviewRenderer ?: return
        if (!camera2PreviewAttached) return
        if (previewBufferWidth <= 0 || previewBufferHeight <= 0) return
        val viewWidth = view.width
        val viewHeight = view.height
        if (viewWidth <= 0 || viewHeight <= 0) return
        val displayRotation = view.display?.rotation ?: Surface.ROTATION_0
        val displayDegrees = when (displayRotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        val rotation = if (previewFrontFacing) {
            (previewSensorOrientation + displayDegrees) % 360
        } else {
            (previewSensorOrientation - displayDegrees + 360) % 360
        }
        val bufferW = previewBufferWidth.toFloat()
        val bufferH = previewBufferHeight.toFloat()
        val swapped = rotation == 90 || rotation == 270
        val srcW = if (swapped) bufferH else bufferW
        val srcH = if (swapped) bufferW else bufferH
        val scale = max(viewWidth / srcW, viewHeight / srcH)
        val centerX = viewWidth / 2f
        val centerY = viewHeight / 2f
        val matrix = Matrix()
        matrix.setTranslate(-bufferW / 2f, -bufferH / 2f)
        matrix.postRotate(rotation.toFloat())
        if (view.currentMirror() && previewFrontFacing) {
            matrix.postScale(-1f, 1f)
        }
        matrix.postScale(scale, scale)
        matrix.postTranslate(centerX, centerY)
        view.setTransform(matrix)
    }

    private fun applyFixedFpsRangeOnCameraThread(session: Any) {
        if (lockedOpenedCamera2Fps && !camera2SessionNeedsWebrtcOnlyRestore) return
        try {
            val deviceField = session.javaClass.getDeclaredField("cameraDevice")
            val surfaceField = session.javaClass.getDeclaredField("surface")
            val captureField = session.javaClass.getDeclaredField("captureSession")
            deviceField.isAccessible = true
            surfaceField.isAccessible = true
            captureField.isAccessible = true
            val captureSession = captureField.get(session) as? CameraCaptureSession ?: return
            startRepeatingOnCameraSession(
                session = session,
                captureSession = captureSession,
                extraPreview = null,
            )
            lockedOpenedCamera2Fps = true
            Log.i(
                "AndroidRTCClient",
                "Locked Camera2 AE fps range to [$LOCAL_CAMERA_CAPTURE_FPS:$LOCAL_CAMERA_CAPTURE_FPS]",
            )
        } catch (error: Throwable) {
            Log.w("AndroidRTCClient", "Failed to lock Camera2 AE fps range", error)
        }
    }

    private fun startRepeatingOnCameraSession(
        session: Any,
        captureSession: CameraCaptureSession,
        extraPreview: Surface?,
    ) {
        val deviceField = session.javaClass.getDeclaredField("cameraDevice")
        val surfaceField = session.javaClass.getDeclaredField("surface")
        val characteristicsField = session.javaClass.getDeclaredField("cameraCharacteristics")
        deviceField.isAccessible = true
        surfaceField.isAccessible = true
        characteristicsField.isAccessible = true
        val device = deviceField.get(session) as? CameraDevice
            ?: throw IllegalStateException("cameraDevice missing")
        val webrtcSurface = surfaceField.get(session) as? Surface
            ?: throw IllegalStateException("webrtc surface missing")
        val characteristics = characteristicsField.get(session) as? CameraCharacteristics
        val fps = LOCAL_CAMERA_CAPTURE_FPS
        val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(fps, fps))
        builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        builder.set(CaptureRequest.CONTROL_AE_LOCK, false)
        applyCamera2Stabilization(builder, characteristics)
        applyCamera2Focus(builder, characteristics)
        builder.addTarget(webrtcSurface)
        if (extraPreview != null) {
            builder.addTarget(extraPreview)
        }
        captureSession.setRepeatingRequest(builder.build(), null, null)
    }

    private fun applyCamera2Stabilization(
        builder: CaptureRequest.Builder,
        characteristics: CameraCharacteristics?,
    ) {
        val optical = characteristics?.get(
            CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION
        )
        if (optical != null && optical.contains(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)) {
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON,
            )
            builder.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
            )
            return
        }
        val video = characteristics?.get(
            CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES
        )
        if (video != null && video.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)) {
            builder.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON,
            )
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
            )
        }
    }

    private fun applyCamera2Focus(
        builder: CaptureRequest.Builder,
        characteristics: CameraCharacteristics?,
    ) {
        val modes = characteristics?.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
        if (modes != null && modes.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)) {
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        }
    }

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
        // Do not reset translationX/Y. Native call-chrome drag stores position on the
        // tile ancestor; visibility apply runs on every chrome sync and would snap drag back.
        if (hidden) {
            view.alpha = 0f
            view.visibility = android.view.View.INVISIBLE
        } else {
            view.alpha = 1f
            view.visibility = android.view.View.VISIBLE
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

    private val installedSurfaceCallbacks = mutableMapOf<Int, SurfaceHolder.Callback>()

    fun installSurfaceReadyCallback(
        renderer: SurfaceViewRenderer,
        logTag: String,
        onReady: () -> Unit,
        onDimensionsChanged: ((Int, Int) -> Unit)? = null,
        onDestroyed: (() -> Unit)? = null,
    ): Boolean {
        return try {
            val callback = object : SurfaceHolder.Callback {
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
            }
            renderer.holder?.let { holder ->
                installedSurfaceCallbacks.remove(System.identityHashCode(renderer))?.let { previous ->
                    holder.removeCallback(previous)
                }
                holder.addCallback(callback)
                installedSurfaceCallbacks[System.identityHashCode(renderer)] = callback
            }
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

    fun addTrackSink(track: RTCVideoTrack, sink: VideoSink, logTag: String, message: String): Boolean {
        return try {
            track.platformTrack.addSink(sink)
            Log.d(logTag, message)
            true
        } catch (e: IllegalStateException) {
            Log.w(logTag, "Attempted to attach disposed track: ${e.message}")
            false
        }
    }

    fun removeTrackSink(track: RTCVideoTrack, sink: VideoSink) {
        try {
            track.platformTrack.removeSink(sink)
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
                    noteRendererFrameResolution(renderer, width, height, rotation)
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
        applyHostRoundedOutline(view, radiusDp)
        if (view is LocalPreviewTextureRenderer) {
            view.setLocalPreviewCornerRadiusDp(radiusDp)
        }
    }

    /// Removes a previously applied rounded outline. Renderers are pooled across Compose
    /// remounts, so a renderer that used to carry the tile outline must be reset when the
    /// outline moves to its aspect-fit host container.
    fun clearRoundedOutline(view: View) {
        applyHostRoundedOutline(view, 0f)
        if (view is LocalPreviewTextureRenderer) {
            view.setLocalPreviewCornerRadiusDp(0f)
        }
    }

    fun detachFromParent(view: View) {
        val parent = view.parent
        if (parent is ViewGroup) {
            parent.removeView(view)
        }
    }

    private val rendererAspectFitContainers =
        WeakHashMap<SurfaceViewRenderer, android.widget.FrameLayout>()
    private val localPreviewHosts =
        WeakHashMap<View, android.widget.FrameLayout>()

    private data class RemoteCameraScaleState(
        var forceAspectFit: Boolean = true,
        var fillWhenOrientationMatches: Boolean = false,
        var cornerRadiusDp: Float = 0f,
        var frameWidth: Int = 0,
        var frameHeight: Int = 0,
        var frameRotation: Int = 0,
        var lastAppliedPreferFit: Boolean? = null,
        var lastAppliedLocalWidth: Int = 0,
        var lastAppliedLocalHeight: Int = 0,
        var lastAppliedExactWidth: Int = 0,
        var lastAppliedExactHeight: Int = 0,
        var lastAppliedDeferredFill: Boolean = false,
    )

    private val rendererCameraScaleState =
        WeakHashMap<SurfaceViewRenderer, RemoteCameraScaleState>()
    private val rendererHostLayoutListenerInstalled =
        WeakHashMap<android.widget.FrameLayout, Boolean>()
    private val rendererHostLastLayoutSize =
        WeakHashMap<android.widget.FrameLayout, Pair<Int, Int>>()

    private fun uprightFrameDimensions(width: Int, height: Int, rotation: Int): Pair<Int, Int> {
        val rot = ((rotation % 360) + 360) % 360
        return if (rot == 90 || rot == 270) {
            Pair(height, width)
        } else {
            Pair(width, height)
        }
    }

    /// Mirrors ``RemoteCameraAspectPolicy.prefersAspectFit`` for the native renderer path.
    private fun prefersAspectFitForState(
        state: RemoteCameraScaleState,
        localWidth: Int,
        localHeight: Int,
    ): Boolean {
        if (state.forceAspectFit) return true
        if (!state.fillWhenOrientationMatches) return false
        val (upW, upH) = uprightFrameDimensions(
            state.frameWidth,
            state.frameHeight,
            state.frameRotation
        )
        if (upW <= 0 || upH <= 0 || localWidth <= 0 || localHeight <= 0) {
            return true
        }
        val remoteLandscape = upW > upH
        val localLandscape = localWidth > localHeight
        return remoteLandscape != localLandscape
    }

    /// Device rotation with `configChanges` updates `Configuration` before the
    /// window finishes laying out. Intermediate sizes must not flip wrap/fill or
    /// reinit EGL — that starves the shared local-preview context.
    fun windowOrientationMatchesConfiguration(view: View): Boolean {
        val orientation = view.resources.configuration.orientation
        if (orientation == Configuration.ORIENTATION_UNDEFINED ||
            orientation == Configuration.ORIENTATION_SQUARE
        ) {
            return true
        }
        val root = view.rootView ?: return true
        val rootWidth = root.width
        val rootHeight = root.height
        if (rootWidth <= 0 || rootHeight <= 0) return false
        val rootPortrait = rootHeight >= rootWidth
        return if (orientation == Configuration.ORIENTATION_PORTRAIT) {
            rootPortrait
        } else {
            !rootPortrait
        }
    }

    private fun localViewportSizeForRenderer(
        renderer: SurfaceViewRenderer,
        container: android.widget.FrameLayout,
    ): Pair<Int, Int> {
        if (container.width > 0 && container.height > 0) {
            return Pair(container.width, container.height)
        }
        if (renderer.width > 0 && renderer.height > 0) {
            return Pair(renderer.width, renderer.height)
        }
        val metrics = renderer.resources.displayMetrics
        return Pair(metrics.widthPixels, metrics.heightPixels)
    }

    private fun ensureRemoteCameraHostContainer(
        renderer: SurfaceViewRenderer,
    ): android.widget.FrameLayout {
        val container = synchronized(rendererAspectFitContainers) {
            rendererAspectFitContainers[renderer] ?: android.widget.FrameLayout(
                renderer.context
            ).also { created ->
                created.setBackgroundColor(android.graphics.Color.BLACK)
                rendererAspectFitContainers[renderer] = created
            }
        }
        assignMatchParentLayoutParamsIfNeeded(container)
        if (rendererHostLayoutListenerInstalled[container] != true) {
            rendererHostLayoutListenerInstalled[container] = true
            container.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                val host = v as? android.widget.FrameLayout ?: return@addOnLayoutChangeListener
                val newW = host.width
                val newH = host.height
                if (newW <= 0 || newH <= 0) return@addOnLayoutChangeListener
                val previous = rendererHostLastLayoutSize[host]
                // Same-size OnLayout must not re-apply. Assigning layoutParams from
                // apply() would requestLayout → OnLayout → apply forever (Device3 ANR:
                // main thread 98%, GC 4–5M objects / 100MB).
                if (previous != null && previous.first == newW && previous.second == newH) {
                    return@addOnLayoutChangeListener
                }
                rendererHostLastLayoutSize[host] = Pair(newW, newH)
                val latest = synchronized(rendererCameraScaleState) {
                    rendererCameraScaleState[renderer]
                } ?: return@addOnLayoutChangeListener
                applyRemoteCameraScaleState(
                    renderer,
                    latest,
                    previousHostWidth = previous?.first,
                    previousHostHeight = previous?.second,
                )
            }
        }
        return container
    }

    private fun applyRemoteCameraScaleState(
        renderer: SurfaceViewRenderer,
        state: RemoteCameraScaleState,
        previousHostWidth: Int? = null,
        previousHostHeight: Int? = null,
    ): android.widget.FrameLayout {
        // Host container is always match-parent so landscape/portrait parents fill the screen;
        // the SurfaceView inside stays match-parent until the tile settles, then one exact
        // letterbox size (not WRAP_CONTENT remasure on every frame-resolution callback).
        val container = ensureRemoteCameraHostContainer(renderer)
        val windowMatches = windowOrientationMatchesConfiguration(container)
        val (localW, localH) = localViewportSizeForRenderer(renderer, container)
        val (windowW, windowH) = windowSizeForView(container)
        val previousW = previousHostWidth
            ?: rendererHostLastLayoutSize[container]?.first
            ?: 0
        val previousH = previousHostHeight
            ?: rendererHostLastLayoutSize[container]?.second
            ?: 0
        val preferFit = prefersAspectFitForState(state, localW, localH)
        val deferWrap = AndroidRendererLayoutPolicy.shouldDeferAspectFitWrapContent(
            preferFit = preferFit,
            windowOrientationMatchesConfiguration = windowMatches,
            hostWidth = localW,
            hostHeight = localH,
            windowWidth = windowW,
            windowHeight = windowH,
            previousHostWidth = previousW,
            previousHostHeight = previousH,
        )
        val (exactW, exactH) = if (preferFit && !deferWrap) {
            AndroidRendererLayoutPolicy.letterboxExactSize(
                state.frameWidth,
                state.frameHeight,
                state.frameRotation,
                localW,
                localH,
            )
        } else {
            Pair(0, 0)
        }
        if (deferWrap) {
            if (state.lastAppliedDeferredFill
                && renderer.parent === container
                && rendererUsesMatchParent(renderer)
            ) {
                return container
            }
            renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FILL)
            aspectFillContainer(renderer)
            state.lastAppliedDeferredFill = true
            state.lastAppliedPreferFit = null
            state.lastAppliedLocalWidth = localW
            state.lastAppliedLocalHeight = localH
            state.lastAppliedExactWidth = 0
            state.lastAppliedExactHeight = 0
            applyRemoteCameraCornerStyle(container, renderer, state)
            renderer.setZOrderOnTop(false)
            return container
        }
        if (state.lastAppliedPreferFit == preferFit
            && !state.lastAppliedDeferredFill
            && state.lastAppliedLocalWidth == localW
            && state.lastAppliedLocalHeight == localH
            && state.lastAppliedExactWidth == exactW
            && state.lastAppliedExactHeight == exactH
            && renderer.parent === container
        ) {
            return container
        }
        state.lastAppliedPreferFit = preferFit
        state.lastAppliedDeferredFill = false
        state.lastAppliedLocalWidth = localW
        state.lastAppliedLocalHeight = localH
        state.lastAppliedExactWidth = exactW
        state.lastAppliedExactHeight = exactH
        val scalingType = if (preferFit) {
            RendererCommon.ScalingType.SCALE_ASPECT_FIT
        } else {
            RendererCommon.ScalingType.SCALE_ASPECT_FILL
        }
        renderer.setScalingType(scalingType)
        if (preferFit) {
            aspectFitContainer(renderer, exactWidth = exactW, exactHeight = exactH)
        } else {
            aspectFillContainer(renderer)
        }
        applyRemoteCameraCornerStyle(container, renderer, state)
        // SurfaceView must remain below the activity-content hit layer. PiP drag registration
        // belongs to the outer call tile, not this renderer: rounded conference cells are style,
        // not draggable in-app PiP windows.
        renderer.setZOrderOnTop(false)
        return container
    }

    private fun applyRemoteCameraCornerStyle(
        container: android.widget.FrameLayout,
        renderer: SurfaceViewRenderer,
        state: RemoteCameraScaleState,
    ) {
        if (state.cornerRadiusDp > 0f) {
            applyRoundedOutline(view = container, radiusDp = state.cornerRadiusDp)
            applyRoundedOutline(view = renderer, radiusDp = state.cornerRadiusDp)
        } else {
            clearRoundedOutline(view = renderer)
            clearRoundedOutline(view = container)
        }
    }

    private fun rendererUsesMatchParent(renderer: SurfaceViewRenderer): Boolean {
        val params = renderer.layoutParams ?: return false
        return params.width == ViewGroup.LayoutParams.MATCH_PARENT
            && params.height == ViewGroup.LayoutParams.MATCH_PARENT
    }

    private fun windowSizeForView(view: View): Pair<Int, Int> {
        val root = view.rootView
        if (root != null && root.width > 0 && root.height > 0) {
            return Pair(root.width, root.height)
        }
        val metrics = view.resources.displayMetrics
        return Pair(metrics.widthPixels, metrics.heightPixels)
    }

    /// Assigning `layoutParams` always requestLayouts. Skip when already match-parent.
    private fun assignMatchParentLayoutParamsIfNeeded(view: View) {
        val existing = view.layoutParams
        if (existing != null
            && existing.width == ViewGroup.LayoutParams.MATCH_PARENT
            && existing.height == ViewGroup.LayoutParams.MATCH_PARENT
        ) {
            return
        }
        val params = existing ?: ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        params.width = ViewGroup.LayoutParams.MATCH_PARENT
        params.height = ViewGroup.LayoutParams.MATCH_PARENT
        view.layoutParams = params
    }

    /// EglRenderer always crops the frame to the renderer view's layout aspect ratio, so a
    /// SurfaceViewRenderer measured EXACTLY (Compose fillMaxSize) aspect-fills regardless of
    /// setScalingType(SCALE_ASPECT_FIT). Hosting the renderer at one exact fitted size
    /// (or WRAP_CONTENT before the first frame) inside a black match-parent container
    /// letterboxes like Apple. Exact pixels avoid VideoLayoutMeasure oscillating
    /// 317↔1002 on every `onFrameResolutionChanged`.
    fun aspectFitContainer(
        renderer: SurfaceViewRenderer,
        exactWidth: Int = 0,
        exactHeight: Int = 0,
    ): android.widget.FrameLayout {
        val container = synchronized(rendererAspectFitContainers) {
            rendererAspectFitContainers[renderer] ?: android.widget.FrameLayout(
                renderer.context
            ).also { created ->
                created.setBackgroundColor(android.graphics.Color.BLACK)
                rendererAspectFitContainers[renderer] = created
            }
        }
        val childWidth = if (exactWidth > 0) exactWidth else ViewGroup.LayoutParams.WRAP_CONTENT
        val childHeight = if (exactHeight > 0) exactHeight else ViewGroup.LayoutParams.WRAP_CONTENT
        if (renderer.parent !== container) {
            detachFromParent(renderer)
            container.addView(
                renderer,
                android.widget.FrameLayout.LayoutParams(
                    childWidth,
                    childHeight,
                    android.view.Gravity.CENTER
                )
            )
        } else {
            (renderer.layoutParams as? android.widget.FrameLayout.LayoutParams)?.let { params ->
                if (params.width != childWidth
                    || params.height != childHeight
                    || params.gravity != android.view.Gravity.CENTER
                ) {
                    params.width = childWidth
                    params.height = childHeight
                    params.gravity = android.view.Gravity.CENTER
                    renderer.layoutParams = params
                }
            }
        }
        return container
    }

    fun aspectFitContainerOrNull(renderer: SurfaceViewRenderer): android.widget.FrameLayout? {
        return synchronized(rendererAspectFitContainers) { rendererAspectFitContainers[renderer] }
    }

    /// Solo fullscreen remote: match-parent host so EglRenderer aspect-fills the device
    /// orientation. Multi-remote tiles keep [aspectFitContainer] letterboxing.
    fun aspectFillContainer(renderer: SurfaceViewRenderer): android.widget.FrameLayout {
        val container = synchronized(rendererAspectFitContainers) {
            rendererAspectFitContainers[renderer] ?: android.widget.FrameLayout(
                renderer.context
            ).also { created ->
                created.setBackgroundColor(android.graphics.Color.BLACK)
                rendererAspectFitContainers[renderer] = created
            }
        }
        assignMatchParentLayoutParamsIfNeeded(container)
        if (renderer.parent !== container) {
            detachFromParent(renderer)
            container.addView(
                renderer,
                android.widget.FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    android.view.Gravity.CENTER
                )
            )
        } else {
            (renderer.layoutParams as? android.widget.FrameLayout.LayoutParams)?.let { params ->
                if (params.width != ViewGroup.LayoutParams.MATCH_PARENT
                    || params.height != ViewGroup.LayoutParams.MATCH_PARENT
                ) {
                    params.width = ViewGroup.LayoutParams.MATCH_PARENT
                    params.height = ViewGroup.LayoutParams.MATCH_PARENT
                    params.gravity = android.view.Gravity.CENTER
                    renderer.layoutParams = params
                }
            }
        }
        return container
    }

    /// Shared host for remote camera Compose tiles.
    ///
    /// - `prefersAspectFit`: multi-remote grids always letterbox.
    /// - `fillWhenOrientationMatches`: solo fullscreen fills only when remote upright
    ///   orientation matches the local viewport (otherwise letterbox).
    fun remoteCameraHostContainer(
        renderer: SurfaceViewRenderer,
        prefersAspectFit: Boolean,
        cornerRadiusDp: Float,
        fillWhenOrientationMatches: Boolean = !prefersAspectFit,
    ): android.widget.FrameLayout {
        val state = synchronized(rendererCameraScaleState) {
            rendererCameraScaleState.getOrPut(renderer) { RemoteCameraScaleState() }.also {
                val nextForceFit = prefersAspectFit
                val nextMatchFill = fillWhenOrientationMatches && !prefersAspectFit
                if (it.forceAspectFit != nextForceFit
                    || it.fillWhenOrientationMatches != nextMatchFill
                    || it.cornerRadiusDp != cornerRadiusDp
                ) {
                    it.lastAppliedPreferFit = null
                    it.lastAppliedLocalWidth = 0
                    it.lastAppliedLocalHeight = 0
                    it.lastAppliedExactWidth = 0
                    it.lastAppliedExactHeight = 0
                    it.lastAppliedDeferredFill = false
                }
                it.forceAspectFit = nextForceFit
                it.fillWhenOrientationMatches = nextMatchFill
                it.cornerRadiusDp = cornerRadiusDp
            }
        }
        return applyRemoteCameraScaleState(renderer, state)
    }

    private fun noteRendererFrameResolution(
        renderer: SurfaceViewRenderer,
        width: Int,
        height: Int,
        rotation: Int,
    ) {
        val state = synchronized(rendererCameraScaleState) {
            rendererCameraScaleState[renderer]
        } ?: return
        val previousWidth = state.frameWidth
        val previousHeight = state.frameHeight
        val previousRotation = state.frameRotation
        val orientationChanged =
            previousWidth != width
                || previousHeight != height
                || previousRotation != rotation
        state.frameWidth = width
        state.frameHeight = height
        state.frameRotation = rotation
        if (orientationChanged) {
            val (previousUpW, previousUpH) = uprightFrameDimensions(
                previousWidth,
                previousHeight,
                previousRotation,
            )
            val (nextUpW, nextUpH) = uprightFrameDimensions(width, height, rotation)
            val previousClassKnown = previousUpW > 0 && previousUpH > 0
            val orientationClassChanged = !previousClassKnown
                || (previousUpW > previousUpH) != (nextUpW > nextUpH)
            if (orientationClassChanged) {
                state.lastAppliedPreferFit = null
                state.lastAppliedExactWidth = 0
                state.lastAppliedExactHeight = 0
            }
        }
        postToMainThread {
            applyRemoteCameraScaleState(renderer, state)
        }
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

    /// Local preview host. The preview is a SurfaceView media overlay so it
    /// does not composite through TextureView on top of the remote hole-punch
    /// (Device3 16:20: 30/0/30 TextureBuffer still looked skippy).
    /// Corners are drawn by `RoundedRectGlDrawer` (public EGL). Do not call
    /// hidden SurfaceView / SurfaceControl corner APIs (lesson 17, 2026-08-26).
    fun localPreviewHostContainer(
        previewView: View,
        cornerRadiusDp: Float,
    ): android.widget.FrameLayout {
        val host = synchronized(localPreviewHosts) {
            localPreviewHosts[previewView] ?: android.widget.FrameLayout(previewView.context).also { created ->
                created.setBackgroundColor(android.graphics.Color.TRANSPARENT)
                localPreviewHosts[previewView] = created
            }
        }
        assignMatchParentLayoutParamsIfNeeded(host)
        if (previewView.parent !== host) {
            detachFromParent(previewView)
            host.addView(
                previewView,
                android.widget.FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
        }
        if (cornerRadiusDp > 0f) {
            applyRoundedOutline(view = previewView, radiusDp = cornerRadiusDp)
            applyRoundedOutline(view = host, radiusDp = cornerRadiusDp)
            AndroidCallChromeNativeSupport.attachNativeCallChromeDrag(
                seed = host,
                key = "local",
                enableTap = false,
                edgeDp = 20f,
            )
        } else {
            clearRoundedOutline(view = previewView)
            clearRoundedOutline(view = host)
        }
        return host
    }

    fun localPreviewHostOrNull(previewView: View): android.widget.FrameLayout? {
        return synchronized(localPreviewHosts) { localPreviewHosts[previewView] }
    }

    /// Local PiP sinks that receive camera frames before VideoSource adaptation.
    /// Binding preview to the send `VideoTrack` inherits encoder fps (Device3: 7 fps
    /// received / 0 dropped while CameraStatistics stayed at 15).
    private val localPreviewCaptureSinks =
        java.util.Collections.synchronizedMap(WeakHashMap<VideoSink, Boolean>())

    fun addLocalPreviewCaptureSink(sink: VideoSink) {
        synchronized(localPreviewCaptureSinks) {
            localPreviewCaptureSinks[sink] = true
        }
    }

    fun removeLocalPreviewCaptureSink(sink: VideoSink) {
        synchronized(localPreviewCaptureSinks) {
            localPreviewCaptureSinks.remove(sink)
        }
    }

    fun hasLocalPreviewCaptureSink(sink: VideoSink): Boolean {
        synchronized(localPreviewCaptureSinks) {
            return localPreviewCaptureSinks.containsKey(sink)
        }
    }

    fun deliverLocalPreviewCaptureFrame(frame: VideoFrame) {
        val sinks: Array<VideoSink>
        synchronized(localPreviewCaptureSinks) {
            if (localPreviewCaptureSinks.isEmpty()) return
            sinks = localPreviewCaptureSinks.keys.toTypedArray()
        }
        for (sink in sinks) {
            try {
                sink.onFrame(frame)
            } catch (_: Throwable) {
            }
        }
    }

    fun removeLocalPreviewHost(previewView: View) {
        synchronized(localPreviewHosts) {
            localPreviewHosts.remove(previewView)
        }
    }

    fun initializeLocalPreviewTexture(
        previewView: LocalPreviewTextureRenderer,
        eglBase: EglBase,
        mirror: Boolean,
    ) {
        previewView.initialize(eglBase, mirror)
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

    fun safeReleaseRenderer(
        renderer: SurfaceViewRenderer,
        @Suppress("UNUSED_PARAMETER") eglBase: EglBase?,
    ) {
        // Always release. EglRenderer's 4s stats thread keeps logging until release(),
        // even after the shared EglBase is already gone. releaseRenderer swallows GL errors.
        releaseRenderer(renderer, "AndroidRTCClient")
    }

    fun logSurfaceRendererInitFailure() {
        Log.e("AndroidRTCClient", "Surface renderer init failed; keeping Compose alive")
    }
}

class AndroidFrameCryptorSupport {
    private var keyProvider: FrameCryptorKeyProvider? = null
    private var generation: Long = 0
    var videoReceiverFrameCryptorReadyHandler: ((String) -> Unit)? = null
    // H1: forwards (tag, participantId, stateDescription) so decrypt failures surface as events.
    var frameCryptorStateHandler: ((String, String, String) -> Unit)? = null

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
        frameCryptorStateHandler = null
    }

    @Synchronized
    fun disposeReceiverCryptors(forParticipant: String) {
        val participantId = forParticipant
        val keys = (
            videoReceiverCryptorsByParticipantId.keys +
                audioReceiverCryptorsByParticipantId.keys +
                screenReceiverCryptorsByParticipantId.keys
            ).filter { it.equals(participantId, ignoreCase = true) }
        for (key in keys) {
            videoReceiverCryptorsByParticipantId.remove(key)?.dispose()
            audioReceiverCryptorsByParticipantId.remove(key)?.dispose()
            screenReceiverCryptorsByParticipantId.remove(key)?.dispose()
            videoReceiverKeysByParticipantId.remove(key)
            audioReceiverKeysByParticipantId.remove(key)
            screenReceiverKeysByParticipantId.remove(key)
            videoReceiverTrackIdsByParticipantId.remove(key)
            audioReceiverTrackIdsByParticipantId.remove(key)
            screenReceiverTrackIdsByParticipantId.remove(key)
        }
        if (keys.isNotEmpty()) {
            generation += 1
        }
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
            AndroidReceiverCryptorPolicy.shouldReuseAudioReceiverCryptorBinding(
                existingTrackId,
                trackId,
            )
        ) {
            audioReceiverCryptor = existingCryptor
            audioReceiverKeysByParticipantId[participant] = receiverKey
            enableAndroidRemoteAudioReceiverTrack(receiver)
            Log.i("AndroidRTCClient", "Audio receiver cryptor already attached for '$participant' receiverKey=$receiverKey trackId=$trackId; keeping live cryptor")
            return
        }

        holdAndroidRemoteAudioReceiverTrack(receiver)
        existingCryptor?.dispose()
        if (existingCryptor != null) {
            Log.i("AndroidRTCClient", "Rebinding audio receiver cryptor for '$participant' oldReceiverKey=${existingReceiverKey ?: "<nil>"} oldTrackId=${existingTrackId ?: "<nil>"} newReceiverKey=$receiverKey newTrackId=$trackId")
        }

        var cryptor: FrameCryptor? = null
        try {
            cryptor = FrameCryptorFactory.createFrameCryptorForRtpReceiver(
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
        } finally {
            if (cryptor == null) {
                enableAndroidRemoteAudioReceiverTrack(receiver)
            }
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
                } else if (newState == FrameCryptor.FrameCryptionState.DECRYPTIONFAILED) {
                    Log.e("AndroidRTCClient", "[$tag] ❌ Decryption failed for '$participantId' (failure tolerance exceeded)")
                }
                frameCryptorStateHandler?.invoke(tag, participantId, stateDescription)
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

/// Rounds the local overlay in the public EGL path. `clipToOutline` cannot
/// clip a `setZOrderMediaOverlay` hole-punch, and both `SurfaceView` /
/// `SurfaceControl.Transaction` corner APIs are missing from compileSdk 36
/// stubs (hidden; reflection denied). Translucent corners show the remote
/// video underneath.
private class RoundedRectGlDrawer : RendererCommon.GlDrawer {
    @Volatile
    var radiusPx: Float = 0f

    private var oesShader: ShaderProgram? = null
    private var rgbShader: ShaderProgram? = null
    private var yuvShader: ShaderProgram? = null

    override fun drawOes(
        oesTextureId: Int,
        texMatrix: FloatArray,
        frameWidth: Int,
        frameHeight: Int,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        val shader = oesShader ?: createShader(ShaderKind.OES).also { oesShader = it }
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        draw(shader, texMatrix, viewportX, viewportY, viewportWidth, viewportHeight)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    override fun drawRgb(
        textureId: Int,
        texMatrix: FloatArray,
        frameWidth: Int,
        frameHeight: Int,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        val shader = rgbShader ?: createShader(ShaderKind.RGB).also { rgbShader = it }
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
        draw(shader, texMatrix, viewportX, viewportY, viewportWidth, viewportHeight)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    override fun drawYuv(
        yuvTextures: IntArray,
        texMatrix: FloatArray,
        frameWidth: Int,
        frameHeight: Int,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        val shader = yuvShader ?: createShader(ShaderKind.YUV).also { yuvShader = it }
        var unit = 0
        while (unit < 3) {
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, yuvTextures[unit])
            unit += 1
        }
        draw(shader, texMatrix, viewportX, viewportY, viewportWidth, viewportHeight)
        unit = 0
        while (unit < 3) {
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
            unit += 1
        }
    }

    override fun release() {
        oesShader?.release()
        rgbShader?.release()
        yuvShader?.release()
        oesShader = null
        rgbShader = null
        yuvShader = null
    }

    private fun draw(
        shader: ShaderProgram,
        texMatrix: FloatArray,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        shader.shader.useProgram()
        GLES20.glUniformMatrix4fv(shader.texMatLoc, 1, false, texMatrix, 0)
        GLES20.glUniform1f(shader.radiusLoc, radiusPx)
        GLES20.glUniform2f(shader.originLoc, viewportX.toFloat(), viewportY.toFloat())
        GLES20.glUniform2f(shader.sizeLoc, viewportWidth.toFloat(), viewportHeight.toFloat())
        shader.shader.setVertexAttribArray("in_pos", 2, NDC)
        shader.shader.setVertexAttribArray("in_tc", 2, TEX)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisable(GLES20.GL_BLEND)
        GlUtil.checkNoGLES2Error("RoundedRectGlDrawer.draw")
    }

    private fun createShader(kind: ShaderKind): ShaderProgram {
        val shader = GlShader(VERTEX, fragmentSource(kind))
        shader.useProgram()
        when (kind) {
            ShaderKind.YUV -> {
                GLES20.glUniform1i(shader.getUniformLocation("y_tex"), 0)
                GLES20.glUniform1i(shader.getUniformLocation("u_tex"), 1)
                GLES20.glUniform1i(shader.getUniformLocation("v_tex"), 2)
            }
            ShaderKind.OES, ShaderKind.RGB -> {
                GLES20.glUniform1i(shader.getUniformLocation("tex"), 0)
            }
        }
        return ShaderProgram(
            shader = shader,
            texMatLoc = shader.getUniformLocation("tex_mat"),
            radiusLoc = shader.getUniformLocation("uRadiusPx"),
            originLoc = shader.getUniformLocation("uViewportOrigin"),
            sizeLoc = shader.getUniformLocation("uViewportSize"),
        )
    }

    private class ShaderProgram(
        val shader: GlShader,
        val texMatLoc: Int,
        val radiusLoc: Int,
        val originLoc: Int,
        val sizeLoc: Int,
    ) {
        fun release() {
            shader.release()
        }
    }

    private enum class ShaderKind { OES, RGB, YUV }

    companion object {
        private val NDC: FloatBuffer = GlUtil.createFloatBuffer(
            floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        )
        private val TEX: FloatBuffer = GlUtil.createFloatBuffer(
            floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)
        )
        private const val VERTEX =
            "varying vec2 tc;\n" +
                "attribute vec4 in_pos;\n" +
                "attribute vec4 in_tc;\n" +
                "uniform mat4 tex_mat;\n" +
                "void main() {\n" +
                "  gl_Position = in_pos;\n" +
                "  tc = (tex_mat * in_tc).xy;\n" +
                "}\n"
        private const val ROUNDED_ALPHA =
            "uniform float uRadiusPx;\n" +
                "uniform vec2 uViewportOrigin;\n" +
                "uniform vec2 uViewportSize;\n" +
                "float roundedAlpha() {\n" +
                "  if (uRadiusPx <= 0.5) return 1.0;\n" +
                "  vec2 p = gl_FragCoord.xy - uViewportOrigin;\n" +
                "  vec2 halfSize = uViewportSize * 0.5;\n" +
                "  vec2 q = abs(p - halfSize) - halfSize + vec2(uRadiusPx);\n" +
                "  float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - uRadiusPx;\n" +
                "  return 1.0 - smoothstep(-0.75, 0.75, dist);\n" +
                "}\n"

        private fun fragmentSource(kind: ShaderKind): String {
            val header = when (kind) {
                ShaderKind.OES ->
                    "#extension GL_OES_EGL_image_external : require\n" +
                        "precision mediump float;\n" +
                        "varying vec2 tc;\n" +
                        "uniform samplerExternalOES tex;\n"
                ShaderKind.RGB ->
                    "precision mediump float;\n" +
                        "varying vec2 tc;\n" +
                        "uniform sampler2D tex;\n"
                ShaderKind.YUV ->
                    "precision mediump float;\n" +
                        "varying vec2 tc;\n" +
                        "uniform sampler2D y_tex;\n" +
                        "uniform sampler2D u_tex;\n" +
                        "uniform sampler2D v_tex;\n"
            }
            val sample = when (kind) {
                ShaderKind.OES, ShaderKind.RGB ->
                    "vec4 sampleColor() { return texture2D(tex, tc); }\n"
                ShaderKind.YUV ->
                    "vec4 sampleColor() {\n" +
                        "  float y = texture2D(y_tex, tc).r * 1.16438;\n" +
                        "  float u = texture2D(u_tex, tc).r;\n" +
                        "  float v = texture2D(v_tex, tc).r;\n" +
                        "  return vec4(y + 1.59603 * v - 0.874202,\n" +
                        "    y - 0.391762 * u - 0.812968 * v + 0.531668,\n" +
                        "    y + 2.01723 * u - 1.08563, 1.0);\n" +
                        "}\n"
            }
            return header + ROUNDED_ALPHA + sample +
                "void main() {\n" +
                "  vec4 color = sampleColor();\n" +
                "  gl_FragColor = vec4(color.rgb, color.a * roundedAlpha());\n" +
                "}\n"
        }
    }
}

/// Local preview is a SurfaceView media overlay. TextureView over the
/// full-screen remote hole-punch still skipped at 30/0/30 (Device3 16:20).
/// clipToOutline does not clip the hole-punch. Round in `RoundedRectGlDrawer`.
class LocalPreviewTextureRenderer(
    context: android.content.Context,
) : SurfaceView(context), VideoSink, SurfaceHolder.Callback {
    private val eglRenderer = EglRenderer("LocalPreview")
    private val roundedDrawer = RoundedRectGlDrawer()
    private var eglReady = false
    private var surfaceBound = false
    private var pendingMirror = true
    private var pendingEglBase: EglBase? = null
    private var loggedFirstPreviewFrame = false
    private var cornerRadiusDp = 12f
    var onReady: (() -> Unit)? = null

    init {
        // Above the remote SurfaceView, below call chrome. Must be set before
        // the holder surface exists. TRANSLUCENT so GL corner alpha composites.
        setZOrderMediaOverlay(true)
        holder.setFormat(PixelFormat.TRANSLUCENT)
        holder.addCallback(this)
    }

    fun initialize(eglBase: EglBase, mirror: Boolean) {
        pendingMirror = mirror
        pendingEglBase = eglBase
        syncDrawerRadius()
        if (!eglReady) {
            eglRenderer.init(eglBase.eglBaseContext, EglBase.CONFIG_RGBA, roundedDrawer)
            eglReady = true
        }
        Log.i(
            "AndroidPreviewCaptureView",
            "LocalPreviewInitializing EglRenderer revision=" +
                AndroidRTCViewSupport.LOCAL_PREVIEW_PIPELINE_REVISION +
                " sharedEgl=true compositor=SurfaceView corner=GlRoundedRect",
        )
        eglRenderer.setMirror(mirror)
        eglRenderer.disableFpsReduction()
        tryBindSurface()
        AndroidRTCViewSupport.registerLocalPreviewRenderer(this)
        if (isReady()) {
            onReady?.invoke()
        }
    }

    fun initializeEglFallback() {
        if (eglReady || AndroidRTCViewSupport.isCamera2PreviewSurfaceAttached()) return
        val eglBase = pendingEglBase ?: return
        syncDrawerRadius()
        eglRenderer.init(eglBase.eglBaseContext, EglBase.CONFIG_RGBA, roundedDrawer)
        eglRenderer.setMirror(pendingMirror)
        eglRenderer.disableFpsReduction()
        eglReady = true
        tryBindSurface()
        if (isReady()) {
            onReady?.invoke()
        }
        Log.i(
            "AndroidPreviewCaptureView",
            "Local preview EGL rebound sharedEgl=true compositor=SurfaceView corner=GlRoundedRect",
        )
    }

    /// Camera2 TextureView path leftover. SurfaceView has no setTransform.
    fun setTransform(@Suppress("UNUSED_PARAMETER") matrix: Matrix) {}

    fun markCamera2PreviewAttached() {
        if (eglReady) {
            try {
                eglRenderer.releaseEglSurface { }
            } catch (_: Throwable) {
            }
            surfaceBound = false
        }
        onReady?.invoke()
        AndroidRTCViewSupport.applyLocalPreviewCamera2Transform()
    }

    fun setLocalPreviewCornerRadiusDp(radiusDp: Float) {
        cornerRadiusDp = radiusDp
        syncDrawerRadius()
    }

    private fun syncDrawerRadius() {
        val density = resources.displayMetrics.density
        val next = cornerRadiusDp * density
        if (kotlin.math.abs(roundedDrawer.radiusPx - next) > 0.5f) {
            roundedDrawer.radiusPx = next
            Log.i(
                "AndroidPreviewCaptureView",
                "LocalPreview surface cornerRadiusPx=$next via=GlRoundedRect",
            )
        } else {
            roundedDrawer.radiusPx = next
        }
    }

    fun currentMirror(): Boolean = pendingMirror

    fun setMirror(mirror: Boolean) {
        pendingMirror = mirror
        if (AndroidRTCViewSupport.isCamera2PreviewSurfaceAttached()) {
            AndroidRTCViewSupport.applyLocalPreviewCamera2Transform()
            return
        }
        if (eglReady) {
            eglRenderer.setMirror(mirror)
        }
    }

    fun releaseRenderer() {
        Log.i("AndroidPreviewCaptureView", "LocalPreviewTextureRenderer.releaseRenderer eglReady=$eglReady")
        AndroidRTCViewSupport.unregisterLocalPreviewCameraSurface(this)
        try {
            eglRenderer.release()
        } catch (_: Throwable) {
        }
        eglReady = false
        surfaceBound = false
        pendingEglBase = null
        loggedFirstPreviewFrame = false
    }

    fun isReady(): Boolean {
        if (AndroidRTCViewSupport.isCamera2PreviewSurfaceAttached()) {
            return width > 0 && height > 0 && holder.surface?.isValid == true
        }
        return eglReady && surfaceBound && width > 0 && height > 0
    }

    override fun onFrame(frame: VideoFrame) {
        if (!eglReady || AndroidRTCViewSupport.isCamera2PreviewSurfaceAttached()) return
        if (!loggedFirstPreviewFrame) {
            loggedFirstPreviewFrame = true
            val kind = when (frame.buffer) {
                is VideoFrame.TextureBuffer -> "TextureBuffer"
                is VideoFrame.I420Buffer -> "I420"
                else -> frame.buffer.javaClass.simpleName
            }
            Log.i(
                "AndroidPreviewCaptureView",
                "LocalPreview first frame buffer=$kind rotation=${frame.rotation} " +
                    "${frame.buffer.width}x${frame.buffer.height}",
            )
        }
        eglRenderer.onFrame(frame)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        syncDrawerRadius()
        if (eglReady) {
            tryBindSurface()
            if (isReady()) {
                onReady?.invoke()
            }
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        syncDrawerRadius()
        if (width > 0 && height > 0) {
            eglRenderer.setLayoutAspectRatio(width.toFloat() / height.toFloat())
        }
        if (eglReady) {
            tryBindSurface()
            if (isReady()) {
                onReady?.invoke()
            }
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        AndroidRTCViewSupport.unregisterLocalPreviewCameraSurface(this)
        surfaceBound = false
        if (eglReady) {
            try {
                eglRenderer.releaseEglSurface { }
            } catch (_: Throwable) {
            }
        }
    }

    private fun tryBindSurface() {
        if (!eglReady || surfaceBound) return
        val surface = holder.surface ?: return
        if (!surface.isValid) return
        try {
            eglRenderer.createEglSurface(surface)
            eglRenderer.clearImage(0f, 0f, 0f, 0f)
            surfaceBound = true
        } catch (_: Throwable) {
        }
    }
}

class AndroidPreviewCaptureViewNative(
    private val client: AndroidRTCClient,
) {
    /// Unused leftover SurfaceView. Not in the view hierarchy. Unregister +
    /// release happen here in Kotlin — do not read this through Skip Swift
    /// after client shutdown (JNI getter SIGTRAPs).
    val surfaceViewRenderer: SurfaceViewRenderer =
        AndroidRTCViewSupport.createSurfaceViewRenderer(
            normalizeToUpright = false,
            logTag = "ANDROIDPREVIEWCAPTUREVIEW"
        )

    val previewDisplayView: LocalPreviewTextureRenderer =
        LocalPreviewTextureRenderer(ProcessInfo.processInfo.androidContext)

    private var pendingTrack: RTCVideoTrack? = null
    private var previewWantsCaptureFanout = false
    private var localOutlineRadiusDp = 12f
    private var released = false

    init {
        previewDisplayView.onReady = {
            applyLocalPreviewRoundedOutline()
            // Size-changed / available must not rebind after mute or detach.
            if (previewWantsCaptureFanout) {
                bindLocalPreviewCaptureFanout()
            }
        }
    }

    fun initializePreview(eglBase: EglBase, mirror: Boolean) {
        Log.i(
            "AndroidPreviewCaptureView",
            "initializePreview sidecar revision=" +
                AndroidRTCViewSupport.LOCAL_PREVIEW_PIPELINE_REVISION,
        )
        previewDisplayView.initialize(eglBase, mirror)
        if (previewWantsCaptureFanout && previewDisplayView.isReady()) {
            bindLocalPreviewCaptureFanout()
        }
    }

    fun setMirror(mirrored: Boolean) {
        previewDisplayView.setMirror(mirrored)
    }

    fun setHidden(hidden: Boolean) {
        if (released) return
        val onMainThread = Looper.myLooper() == Looper.getMainLooper()
        val applyHidden = applyHidden@{
            if (released) return@applyHidden
            AndroidRTCViewSupport.setViewHiddenForCallChromeMinimize(
                view = previewDisplayView,
                hidden = hidden,
                logTag = "AndroidPreviewCaptureView"
            )
            AndroidRTCViewSupport.localPreviewHostOrNull(previewDisplayView)?.let { host ->
                AndroidRTCViewSupport.setViewHiddenForCallChromeMinimize(
                    view = host,
                    hidden = hidden,
                    logTag = "AndroidPreviewCaptureView"
                )
            }
        }
        if (onMainThread) {
            applyHidden()
        } else {
            Handler(Looper.getMainLooper()).post { applyHidden() }
        }
    }

    fun releaseLocalPreviewEgl() {
        release()
    }

    fun release() {
        previewWantsCaptureFanout = false
        pendingTrack = null
        AndroidRTCViewSupport.removeLocalPreviewCaptureSink(previewDisplayView)
        setHidden(true)
        AndroidRTCViewSupport.detachFromParent(previewDisplayView)
        AndroidRTCViewSupport.localPreviewHostOrNull(previewDisplayView)?.let { host ->
            AndroidRTCViewSupport.detachFromParent(host)
        }
        AndroidRTCViewSupport.removeLocalPreviewHost(previewDisplayView)
        released = true
        try {
            if (client.removeRendererIfTracked(surfaceViewRenderer)) {
                Log.i(
                    "AndroidPreviewCaptureView",
                    "unregistered leftover local SurfaceView from client",
                )
            }
        } catch (e: Throwable) {
            Log.w(
                "AndroidPreviewCaptureView",
                "client unregister skipped after shutdown: ${e.message}",
            )
        }
        Log.i("AndroidPreviewCaptureView", "Releasing local preview TextureView EGL")
        previewDisplayView.releaseRenderer()
        AndroidRTCViewSupport.releaseRenderer(surfaceViewRenderer, "AndroidPreviewCaptureView")
        Log.i("AndroidPreviewCaptureView", "Released local preview TextureView EGL")
    }

    fun configureRoundedOutline(radiusDp: Float) {
        localOutlineRadiusDp = radiusDp
        previewDisplayView.setLocalPreviewCornerRadiusDp(radiusDp)
        applyLocalPreviewRoundedOutline()
    }

    private fun applyLocalPreviewRoundedOutline() {
        previewDisplayView.setLocalPreviewCornerRadiusDp(localOutlineRadiusDp)
        AndroidRTCViewSupport.applyRoundedOutline(
            view = previewDisplayView,
            radiusDp = localOutlineRadiusDp
        )
        AndroidRTCViewSupport.localPreviewHostOrNull(previewDisplayView)?.let { host ->
            AndroidRTCViewSupport.applyRoundedOutline(view = host, radiusDp = localOutlineRadiusDp)
        }
    }

    private fun bindLocalPreviewCaptureFanout() {
        AndroidRTCViewSupport.addLocalPreviewCaptureSink(previewDisplayView)
        pendingTrack?.let { leftover ->
            AndroidRTCViewSupport.removeTrackSink(leftover, previewDisplayView)
        }
        pendingTrack = null
    }

    fun attach(track: RTCVideoTrack) {
        // Drop any prior VideoTrack sink so encoder adaptation cannot cap the PiP.
        AndroidRTCViewSupport.removeTrackSink(track, previewDisplayView)
        previewWantsCaptureFanout = true
        pendingTrack = track
        // Register the sink even before TextureView has a surface. Waiting for
        // isReady() left Device3 at LocalPreview 0 fps (`Texture not ready, queued`)
        // while the camera ran at 15. EGL drops until the surface exists.
        bindLocalPreviewCaptureFanout()
        Log.i(
            "AndroidPreviewCaptureView",
            "Bound local preview to capturer fanout (not VideoTrack sink)"
        )
    }

    fun detach(track: RTCVideoTrack) {
        previewWantsCaptureFanout = false
        AndroidRTCViewSupport.removeTrackSink(track, previewDisplayView)
        AndroidRTCViewSupport.removeLocalPreviewCaptureSink(previewDisplayView)
        if (pendingTrack?.platformTrack == track.platformTrack) {
            pendingTrack = null
        }
    }

    fun hasActiveSink(): Boolean {
        return previewWantsCaptureFanout &&
            AndroidRTCViewSupport.hasLocalPreviewCaptureSink(previewDisplayView)
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
    private var released = false

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
        if (released) return
        val onMainThread = Looper.myLooper() == Looper.getMainLooper()
        val applyHidden = applyHidden@{
            if (released) return@applyHidden
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
        val attachedBeforeRelease = attachedTrack
        val pendingBeforeRelease = pendingTrack
        attachedBeforeRelease?.let {
            AndroidRTCViewSupport.removeTrackSink(it, surfaceViewRenderer)
        }
        if (pendingBeforeRelease != null &&
            pendingBeforeRelease.platformTrack != attachedBeforeRelease?.platformTrack
        ) {
            AndroidRTCViewSupport.removeTrackSink(pendingBeforeRelease, surfaceViewRenderer)
        }
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
        sinkAttachFirstFrameObserver = null
        (surfaceViewRenderer as? CustomSurfaceViewRenderer)?.renderedFrameObserver = null
        setHidden(true)
        AndroidRTCViewSupport.aspectFitContainerOrNull(surfaceViewRenderer)?.let { container ->
            AndroidRTCViewSupport.detachFromParent(container)
        }
        AndroidRTCViewSupport.detachFromParent(surfaceViewRenderer)
        released = true
        var releaseRendererHere = true
        try {
            releaseRendererHere = client.removeRendererIfTracked(surfaceViewRenderer)
        } catch (e: Throwable) {
            Log.w(
                "AndroidSampleCaptureView",
                "client unregister skipped after shutdown: ${e.message}",
            )
        }
        if (releaseRendererHere) {
            AndroidRTCViewSupport.releaseRenderer(surfaceViewRenderer, "AndroidSampleCaptureView")
        } else {
            Log.i(
                "AndroidSampleCaptureView",
                "renderer already released by client reset or never initialized",
            )
        }
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
        // Match Swift `shouldDeferLiveWrapperSinkRebindWhileTileDeliversRecentFrames`:
        // never wait for tail frames on a dead Java wrapper (leave / SFU prune).
        // Only skip a same-wrapper live sink that is still painting.
        if (!AndroidRTCViewSupport.isLiveVideoTrack(stale)) return false
        if (!AndroidRTCViewSupport.isLiveVideoTrack(live)) return false
        if (!AndroidRemoteVideoTrackAttachPolicy.tracksShareRendererSinkSource(stale, live)) return false
        return rendererHasRecentFramesForCurrentSinkOnMainThread()
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
                val tile = conferenceTileHostSize()
                val aspectFitWrap = tile != null &&
                    AndroidRendererLayoutPolicy.isLikelyAspectFitWrapSurfaceMeasure(
                        width,
                        height,
                        tile.first,
                        tile.second,
                    )
                if (aspectFitWrap) {
                    // Letterbox wrap-content is the same SurfaceView. Accept the holder
                    // size so egl_init_stale cannot force a sink teardown.
                    lastEglInitSurfaceWidth = width
                    lastEglInitSurfaceHeight = height
                    logRendererLayoutState("surface_holder_aspect_fit_skip", previousWidth, previousHeight)
                    return@installSurfaceReadyCallback
                }
                if (previousWidth > 0 && previousHeight > 0
                    && previousWidth != width && previousHeight != height
                ) {
                    // Accept the holder size so egl_init_stale cannot force
                    // attach / reconcile to undo this skip in the same frame.
                    lastEglInitSurfaceWidth = width
                    lastEglInitSurfaceHeight = height
                    logRendererLayoutState("surface_holder_rotation_skip", previousWidth, previousHeight)
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

    private fun conferenceTileHostSize(): Pair<Int, Int>? {
        val host = AndroidRTCViewSupport.aspectFitContainerOrNull(surfaceViewRenderer)
        val width = host?.width ?: 0
        val height = host?.height ?: 0
        if (width <= 0 || height <= 0) return null
        return Pair(width, height)
    }

    private fun shouldReinitRendererEglForHolderResize(
        previousWidth: Int,
        previousHeight: Int,
        newWidth: Int,
        newHeight: Int,
    ): Boolean {
        if (newWidth <= 0 || newHeight <= 0) return false
        if (isLikelyTransientFullscreenSurfaceMeasure(newWidth, newHeight)) return false
        val tile = conferenceTileHostSize()
        if (!AndroidRendererLayoutPolicy.shouldReinitRendererEglForImmediateHolderResize(
                previousWidth = previousWidth,
                previousHeight = previousHeight,
                newWidth = newWidth,
                newHeight = newHeight,
                windowOrientationMatchesConfiguration = AndroidRTCViewSupport
                    .windowOrientationMatchesConfiguration(surfaceViewRenderer),
                tileWidth = tile?.first ?: 0,
                tileHeight = tile?.second ?: 0,
            )
        ) {
            return false
        }
        // Compose reports a fullscreen holder blip before tile constraints settle.
        if (isLikelyTransientFullscreenSurfaceMeasure(previousWidth, previousHeight)) return true
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

    private fun shouldAllowImmediateEglReinitForCurrentLayout(): Boolean {
        val width = surfaceViewRenderer.width
        val height = surfaceViewRenderer.height
        if (width <= 0 || height <= 0) return false
        val tile = conferenceTileHostSize()
        val previousWidth = if (lastEglInitSurfaceWidth > 0) lastEglInitSurfaceWidth else lastRendererWidth
        val previousHeight = if (lastEglInitSurfaceHeight > 0) lastEglInitSurfaceHeight else lastRendererHeight
        return AndroidRendererLayoutPolicy.shouldAllowAttachDrivenEglReinit(
            previousWidth = previousWidth,
            previousHeight = previousHeight,
            newWidth = width,
            newHeight = height,
            eglNeedsResync = rendererEglNeedsSurfaceResync(),
            windowOrientationMatchesConfiguration = AndroidRTCViewSupport
                .windowOrientationMatchesConfiguration(surfaceViewRenderer),
            tileWidth = tile?.first ?: 0,
            tileHeight = tile?.second ?: 0,
            lastRendererWidth = lastRendererWidth,
            lastRendererHeight = lastRendererHeight,
        )
    }

    private fun shouldReinitializeRendererEglForLayout(): Boolean {
        return shouldAllowImmediateEglReinitForCurrentLayout()
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

    /// After Compose has laid out the new orientation, one EGL reinit is allowed.
    private fun requiresRendererEglReinitAfterComposeLayout(
        width: Int,
        height: Int,
    ): Boolean {
        if (attachedTrack == null && pendingTrack == null) return false
        if (isLikelyTransientFullscreenSurfaceMeasure(width, height)) return false
        val tile = conferenceTileHostSize()
        if (tile != null &&
            AndroidRendererLayoutPolicy.isLikelyAspectFitWrapSurfaceMeasure(
                width,
                height,
                tile.first,
                tile.second,
            )
        ) {
            return false
        }
        return AndroidRendererLayoutPolicy.shouldReinitRendererEglAfterComposeLayoutSettled(
            viewWidth = width,
            viewHeight = height,
            lastRendererWidth = lastRendererWidth,
            lastRendererHeight = lastRendererHeight,
            eglNeedsResync = rendererEglNeedsSurfaceResync(),
            windowOrientationMatchesConfiguration = AndroidRTCViewSupport
                .windowOrientationMatchesConfiguration(surfaceViewRenderer),
        )
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
            // Unassigned pool slots must not steal the shared EGL context from local
            // preview / live remotes. Remember the new size; attach initializes EGL.
            lastRendererWidth = surfaceViewRenderer.width
            lastRendererHeight = surfaceViewRenderer.height
            logRendererLayoutState("egl_reinit_idle_pool_slot_skipped")
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
        val bothAxesChanged = previousWidth > 0 && previousHeight > 0
            && previousWidth != width && previousHeight != height
        if (bothAxesChanged) {
            return
        }
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
        if (shouldAllowImmediateEglReinitForCurrentLayout()) {
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

    /// 2-up → 1:1: drop the 317×564 letterbox and fill the Compose tile.
    /// Compose must also remount the AndroidView (`composeTileKey`); this
    /// flips native scale state if the same view instance is reused.
    fun applySoloFullscreenLayout() {
        if (released) return
        AndroidRTCViewSupport.runOnMainThreadSyncUnit {
            AndroidRTCViewSupport.remoteCameraHostContainer(
                renderer = surfaceViewRenderer,
                prefersAspectFit = false,
                cornerRadiusDp = 0f,
                fillWhenOrientationMatches = true,
            )
            surfaceViewRenderer.requestLayout()
            (surfaceViewRenderer.parent as? View)?.requestLayout()
        }
    }

    private fun rendererDidInitializeOnMainThread() {
        ensureFirstFrameHandlerRegistered()
        lastRendererWidth = surfaceViewRenderer.width
        lastRendererHeight = surfaceViewRenderer.height
        if (!surfaceCallbackSetup) {
            setupSurfaceCallback()
        }
        if (pendingTrack == null &&
            attachedTrack != null &&
            rendererHasSink &&
            sinkMatchesCurrentRendererGeneration() &&
            isSurfaceReady() &&
            !rendererEglNeedsSurfaceResync()
        ) {
            logRendererLayoutState("renderer_did_initialize_reuse")
            return
        }
        lastEglInitSurfaceWidth = 0
        lastEglInitSurfaceHeight = 0
        hasRenderedFirstFrameSinceSinkAttach = false
        logRendererLayoutState("renderer_did_initialize")
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
    /// Skip when the renderer size is unchanged. Missing sink is an attach event, not a layout event.
    /// Treating `!rendererHasSink` as dirty re-entered update → controller Task → reattach → update
    /// (Device3 10:43 ANR, 4M GC, 0 fps, no receiver cryptors).
    fun rendererDidUpdateLayoutFromCompose(): Boolean {
        if (composeLayoutUpdatePosted) return false
        val width = surfaceViewRenderer.width
        val height = surfaceViewRenderer.height
        if (width <= 0 || height <= 0) return false
        if (width == lastRendererWidth &&
            height == lastRendererHeight &&
            !rendererEglNeedsSurfaceResync()
        ) {
            return false
        }
        composeLayoutUpdatePosted = true
        composeLayoutHandler.post {
            composeLayoutUpdatePosted = false
            rendererDidUpdateLayoutOnMainThread()
        }
        return true
    }

    private fun rendererDidUpdateLayoutOnMainThread() {
        val width = surfaceViewRenderer.width
        val height = surfaceViewRenderer.height
        if (requiresRendererEglReinitAfterComposeLayout(width, height)) {
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
        if (shouldAllowImmediateEglReinitForCurrentLayout()) {
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
