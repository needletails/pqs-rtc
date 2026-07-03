//
//  AndroidScreenCaptureService.swift
//  pqs-rtc
//
//  Copyright (c) 2025 NeedleTails Organization.
//

#if SKIP
import Foundation
import android.app.Service
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat

/// Computes capture dimensions and frame rate for Android MediaProjection.
public enum AndroidScreenShareCaptureMetrics {
    public static func compute(optimizeForVideo: Bool) -> (width: Int, height: Int, fps: Int) {
        var width = 1280
        var height = 720
        var fps = optimizeForVideo ? 24 : 15
        // Keep the capture buffer in the display's actual orientation. MediaProjection scales the
        // screen into the virtual-display surface, so forcing landscape dimensions on a portrait
        // phone letterboxes the shared content into a tiny strip.
        // SKIP INSERT: val ctx = ProcessInfo.processInfo.androidContext
        // SKIP INSERT: if (ctx != null) {
        // SKIP INSERT:     val metrics = DisplayMetrics()
        // SKIP INSERT:     val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        // SKIP INSERT:     wm?.defaultDisplay?.getRealMetrics(metrics)
        // SKIP INSERT:     val rawW = metrics.widthPixels.coerceAtLeast(2)
        // SKIP INSERT:     val rawH = metrics.heightPixels.coerceAtLeast(2)
        // SKIP INSERT:     val longEdge = maxOf(rawW, rawH)
        // SKIP INSERT:     val maxEdge = if (optimizeForVideo) 1920 else 1600
        // SKIP INSERT:     val scale = minOf(1.0, maxEdge.toDouble() / longEdge.toDouble())
        // SKIP INSERT:     var scaledW = ((rawW * scale).toInt() / 2) * 2
        // SKIP INSERT:     var scaledH = ((rawH * scale).toInt() / 2) * 2
        // SKIP INSERT:     width = scaledW.coerceIn(360, 1920)
        // SKIP INSERT:     height = scaledH.coerceIn(360, 1920)
        // SKIP INSERT: }
        return (width, height, fps)
    }
}

/// Starts/stops the Android 14+ media-projection foreground service required before capture.
public enum AndroidScreenCaptureForeground {
    private static let channelId = "pqsrtc.screen.capture"
    private static let readyLock = NSLock()
    private static var isForegroundReady = false
    private static let lock = NSLock()
    private static var runningCount = 0

    fileprivate static func markForegroundReady() {
        readyLock.lock()
        isForegroundReady = true
        readyLock.unlock()
    }

    fileprivate static func markForegroundStopped() {
        readyLock.lock()
        isForegroundReady = false
        readyLock.unlock()
    }

    public static func startIfNeeded() {
        lock.lock()
        runningCount += 1
        lock.unlock()
        // Re-issue the start intent whenever the service is not foreground-ready, even if the
        // running count says it should be. A crashed or system-killed service otherwise leaves
        // the counter stuck at > 0 and every later share times out waiting for readiness.
        // `onStartCommand` is idempotent: re-delivery just re-runs `startForeground`.
        readyLock.lock()
        let alreadyReady = isForegroundReady
        readyLock.unlock()
        guard !alreadyReady else { return }
        guard let ctx = ProcessInfo.processInfo.androidContext else { return }
        createChannelIfNeeded(ctx)
        let intent = Intent()
        intent.setComponent(ComponentName(ctx, "pqsrtc.module.AndroidScreenCaptureService"))
        if Build.VERSION.SDK_INT >= Build.VERSION_CODES.O {
            ctx.startForegroundService(intent)
        } else {
            ctx.startService(intent)
        }
    }

    /// Blocks until the media-projection FGS has called `startForeground`, or times out.
    /// Required on API 34+ before `MediaProjectionManager.getMediaProjection()`.
    public static func awaitReady(timeoutMs: Int = 5000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            readyLock.lock()
            let ready = isForegroundReady
            readyLock.unlock()
            if ready { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        readyLock.lock()
        defer { readyLock.unlock() }
        return isForegroundReady
    }

    /// Starts the FGS when needed and waits until it is foreground-ready.
    public static func startAndAwaitReady(timeoutMs: Int = 5000) -> Bool {
        startIfNeeded()
        return awaitReady(timeoutMs: timeoutMs)
    }

    public static func stopIfRunning() {
        lock.lock()
        guard runningCount > 0 else {
            lock.unlock()
            return
        }
        runningCount -= 1
        let shouldStop = runningCount == 0
        lock.unlock()
        guard shouldStop else { return }
        guard let ctx = ProcessInfo.processInfo.androidContext else { return }
        let intent = Intent()
        intent.setComponent(ComponentName(ctx, "pqsrtc.module.AndroidScreenCaptureService"))
        ctx.stopService(intent)
        markForegroundStopped()
    }

    fileprivate static func createChannelIfNeeded(_ context: Context) {
        // SKIP INSERT: if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // SKIP INSERT: val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        // SKIP INSERT: if (manager.getNotificationChannel(channelId) != null) return
        // SKIP INSERT: val channel = NotificationChannel(
        // SKIP INSERT:     channelId,
        // SKIP INSERT:     "Screen sharing",
        // SKIP INSERT:     NotificationManager.IMPORTANCE_LOW
        // SKIP INSERT: )
        // SKIP INSERT: channel.description = "Active while Nudge is sharing your screen"
        // SKIP INSERT: channel.setShowBadge(false)
        // SKIP INSERT: manager.createNotificationChannel(channel)
    }
}

// SKIP @nobridge
public final class AndroidScreenCaptureService: Service {
    fileprivate let notificationId = 991337

    public init() {
        super.init()
    }

    public override func onBind(intent: Intent?) -> IBinder? {
        return nil
    }

    public override func onStartCommand(intent: Intent?, flags: Int, startId: Int) -> Int {
        AndroidScreenCaptureForeground.createChannelIfNeeded(self)
        // SKIP INSERT: val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        // SKIP INSERT: val pendingIntent = PendingIntent.getActivity(
        // SKIP INSERT:     this,
        // SKIP INSERT:     0,
        // SKIP INSERT:     launchIntent,
        // SKIP INSERT:     PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        // SKIP INSERT: )
        // SKIP INSERT: val channelId = "pqsrtc.screen.capture"
        // SKIP INSERT: val notification = NotificationCompat.Builder(this, channelId)
        // SKIP INSERT:     .setContentTitle("Sharing screen")
        // SKIP INSERT:     .setContentText("Nudge is sharing your screen")
        // SKIP INSERT:     .setSmallIcon(android.R.drawable.presence_video_online)
        // SKIP INSERT:     .setOngoing(true)
        // SKIP INSERT:     .setContentIntent(pendingIntent)
        // SKIP INSERT:     .setCategory(NotificationCompat.CATEGORY_SERVICE)
        // SKIP INSERT:     .build()
        // SKIP INSERT: if (Build.VERSION.SDK_INT >= 34) {
        // SKIP INSERT:     startForeground(
        // SKIP INSERT:         notificationId,
        // SKIP INSERT:         notification,
        // SKIP INSERT:         ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        // SKIP INSERT:     )
        // SKIP INSERT: } else {
        // SKIP INSERT:     startForeground(notificationId, notification)
        // SKIP INSERT: }
        AndroidScreenCaptureForeground.markForegroundReady()
        // SKIP INSERT: return android.app.Service.START_STICKY
    }

    public override func onDestroy() {
        AndroidScreenCaptureForeground.markForegroundStopped()
        // SKIP INSERT: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
        // SKIP INSERT:     stopForeground(android.app.Service.STOP_FOREGROUND_REMOVE)
        // SKIP INSERT: } else {
        // SKIP INSERT:     stopForeground(true)
        // SKIP INSERT: }
        super.onDestroy()
    }
}
#endif
