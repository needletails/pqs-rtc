package pqsrtc.module

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.ViewParent
import android.view.ViewTreeObserver
import java.util.WeakHashMap

/**
 * Single native owner for in-app call tile input and movement.
 *
 * One transparent sibling on `android.R.id.content` sits above Compose in the same window.
 * ACTION_DOWN inside a registered visible tile is consumed; everything else returns false
 * so chat and call controls keep the gesture. Drag writes `translationX`/`translationY` on
 * the tile-sized native host that wraps the renderer (never a full-screen
 * Compose/messaging parent). Layout
 * cannot remasure EGL because pointer-move does not change view width/height.
 */
object AndroidCallChromeNativeSupport {
    private const val TAG = "NudgeCallChromeDrag"

    private val dragSessions = LinkedHashMap<String, DragSession>()
    private val controlExclusions = LinkedHashMap<String, View>()

    @Volatile
    private var inAppPipTapHandler: (() -> Unit)? = null

    private var hitLayer: CallChromeHitLayer? = null
    private var hitLayerParent: ViewGroup? = null
    private var keepHitLayerFrontListener: ViewTreeObserver.OnGlobalLayoutListener? = null
    private var activityTouchSession: DragSession? = null

    fun setInAppPipTapHandler(handler: (() -> Unit)?) {
        inAppPipTapHandler = handler
    }

    /**
     * Call-control chrome sits above tiles in z-order. Touches inside a registered
     * control view are never consumed by drag, even when a tile visually overlaps.
     */
    fun registerControlExclusion(key: String, view: View) {
        controlExclusions[key] = view
        Log.i(
            TAG,
            "exclusion attached key=$key ${view.width}x${view.height}",
        )
    }

    fun detachControlExclusion(key: String) {
        if (controlExclusions.remove(key) != null) {
            Log.i(TAG, "exclusion detached key=$key")
        }
    }

    fun attachNativeCallChromeDrag(
        seed: View,
        key: String,
        enableTap: Boolean,
        edgeDp: Float,
    ) {
        if (isNearlyFullScreen(seed)) {
            Log.w(
                TAG,
                "refusing full-screen seed key=$key ${seed.width}x${seed.height}",
            )
            return
        }

        val edgePx = edgeDp * seed.resources.displayMetrics.density
        val existing = dragSessions[key]
        if (existing != null && existing.seed === seed && existing.enableTap == enableTap) {
            existing.edgePx = edgePx
            return
        }

        existing?.detach()
        val session = DragSession(
            key = key,
            seed = seed,
            enableTap = enableTap,
            edgePx = edgePx,
        )
        dragSessions[key] = session
        session.attach()
        ensureHitLayer(seed)
        Log.i(
            TAG,
            "attached key=$key enableTap=$enableTap edgePx=${edgePx.toInt()} " +
                "seed=${seed.width}x${seed.height}",
        )
    }

    fun resetNativeCallChromeDrag(key: String) {
        val session = dragSessions[key] ?: return
        session.resetTranslation()
        Log.i(TAG, "reset key=$key")
    }

    fun detachNativeCallChromeDrag(key: String, seed: View? = null) {
        val session = dragSessions[key] ?: return
        if (seed != null && session.seed !== seed) {
            return
        }
        dragSessions.remove(key)?.detach()
        if (activityTouchSession === session) {
            activityTouchSession = null
        }
        if (dragSessions.isEmpty()) {
            removeHitLayer()
        }
    }

    /**
     * MainActivity calls this before normal dispatch. SurfaceView and Skip/Compose
     * cannot swallow a tile gesture before this owner sees it; non-tile touches
     * return false immediately and continue through the app normally.
     */
    fun dispatchActivityTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            val session = sessionAt(event.rawX, event.rawY)
            activityTouchSession = session
            return session?.handleTouch(event) ?: false
        }

        val session = activityTouchSession ?: return false
        val handled = session.handleTouch(event)
        if (event.actionMasked == MotionEvent.ACTION_UP ||
            event.actionMasked == MotionEvent.ACTION_CANCEL
        ) {
            activityTouchSession = null
        }
        return handled
    }

    private fun ensureHitLayer(seed: View) {
        val activity = seed.findActivity()
        val content = activity?.findViewById<ViewGroup>(android.R.id.content)
        if (activity == null || content == null) {
            Log.w(TAG, "hit layer unavailable key sessions=${dragSessions.keys}")
            return
        }

        val current = hitLayer
        if (current != null && current.parent === content) {
            return
        }

        removeHitLayer()
        val layer = CallChromeHitLayer(activity)
        hitLayer = layer
        hitLayerParent = content
        content.addView(
            layer,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        val listener = ViewTreeObserver.OnGlobalLayoutListener {
            val parent = hitLayerParent ?: return@OnGlobalLayoutListener
            val overlay = hitLayer ?: return@OnGlobalLayoutListener
            if (overlay.parent === parent &&
                parent.childCount > 0 &&
                parent.getChildAt(parent.childCount - 1) !== overlay
            ) {
                overlay.bringToFront()
            }
        }
        keepHitLayerFrontListener = listener
        content.viewTreeObserver.addOnGlobalLayoutListener(listener)
        Log.i(TAG, "hit layer attached")
    }

    private fun removeHitLayer() {
        val parent = hitLayerParent
        val listener = keepHitLayerFrontListener
        if (parent != null && listener != null) {
            val observer = parent.viewTreeObserver
            if (observer.isAlive) {
                observer.removeOnGlobalLayoutListener(listener)
            }
        }
        keepHitLayerFrontListener = null
        val layer = hitLayer
        (layer?.parent as? ViewGroup)?.removeView(layer)
        hitLayer = null
        hitLayerParent = null
        if (layer != null) {
            Log.i(TAG, "hit layer detached")
        }
    }

    private fun sessionAt(rawX: Float, rawY: Float): DragSession? {
        if (hitsControlExclusion(rawX, rawY)) {
            return null
        }
        var selected: DragSession? = null
        var selectedArea = Float.MAX_VALUE
        for (session in dragSessions.values) {
            if (!session.isHitEnabled()) continue
            val bounds = session.screenBounds() ?: continue
            if (!bounds.contains(rawX, rawY)) continue
            val area = bounds.width() * bounds.height()
            if (selected == null || area < selectedArea) {
                selected = session
                selectedArea = area
            }
        }
        return selected
    }

    private fun hitsControlExclusion(rawX: Float, rawY: Float): Boolean {
        val visible = Rect()
        for (view in controlExclusions.values) {
            if (!view.isAttachedToWindow || !view.isShown) continue
            if (!view.getGlobalVisibleRect(visible) || visible.isEmpty) continue
            if (visible.contains(rawX.toInt(), rawY.toInt())) {
                return true
            }
        }
        return false
    }

    private fun rawScreenBounds(view: View): RectF {
        val layer = hitLayer
        if (layer != null && layer.isAttachedToWindow && layer.width > 0 && layer.height > 0) {
            val location = IntArray(2)
            layer.getLocationOnScreen(location)
            return RectF(
                location[0].toFloat(),
                location[1].toFloat(),
                (location[0] + layer.width).toFloat(),
                (location[1] + layer.height).toFloat(),
            )
        }
        val metrics = view.resources.displayMetrics
        return RectF(0f, 0f, metrics.widthPixels.toFloat(), metrics.heightPixels.toFloat())
    }

    private fun availableScreenBounds(view: View): RectF {
        val screen = rawScreenBounds(view)
        applyControlExclusionInsets(screen)
        return screen
    }

    /**
     * Keep snapped / clamped tiles out of the top and bottom control bars.
     * Only strip-sized exclusions apply so a mis-sized probe cannot collapse the screen.
     * @return extra bottom gap already applied (12dp above the return chip).
     */
    private fun applyControlExclusionInsets(screen: RectF): Float {
        val visible = Rect()
        val midY = (screen.top + screen.bottom) / 2f
        val maxBarHeight = screen.height() * 0.4f
        val minBarWidth = screen.width() * 0.35f
        var insetBottom = false
        var appliedChipGap = 0f
        var density = (hitLayer ?: controlExclusions.values.firstOrNull())
            ?.resources
            ?.displayMetrics
            ?.density
            ?: 1f
        for ((key, view) in controlExclusions) {
            if (!view.isAttachedToWindow || !view.isShown) continue
            density = view.resources.displayMetrics.density
            if (!view.getGlobalVisibleRect(visible) || visible.isEmpty) continue
            val height = visible.height().toFloat()
            val width = visible.width().toFloat()
            val isChip = key == "call-chip"
            val minWidth = if (isChip) 80f * density else minBarWidth
            if (height <= 0f || height >= maxBarHeight || width < minWidth) continue
            if (visible.centerY() >= midY) {
                val gapPx = if (isChip) 12f * density else 0f
                screen.bottom = minOf(screen.bottom, visible.top.toFloat() - gapPx)
                insetBottom = true
                if (isChip) {
                    appliedChipGap = maxOf(appliedChipGap, gapPx)
                }
            } else {
                screen.top = maxOf(screen.top, visible.bottom.toFloat())
            }
        }
        if (!insetBottom &&
            controlExclusions.keys.any {
                it == "call-controls" || it == "call-chip" || it.endsWith("bottom")
            }
        ) {
            val reserveDp = if (controlExclusions.containsKey("call-chip")) 116f else 128f
            screen.bottom -= reserveDp * density
            if (controlExclusions.containsKey("call-chip")) {
                appliedChipGap = 12f * density
            }
        }
        return appliedChipGap
    }

    private class DragSession(
        val key: String,
        val seed: View,
        val enableTap: Boolean,
        var edgePx: Float,
    ) {
        private var target: View = seed
        private var committedTx = 0f
        private var committedTy = 0f
        private var downRawX = 0f
        private var downRawY = 0f
        private var downTx = 0f
        private var downTy = 0f
        private var dragging = false
        private var movedPastSlop = false
        private var dragMinTx = 0f
        private var dragMaxTx = 0f
        private var dragMinTy = 0f
        private var dragMaxTy = 0f
        private var hasDragLimits = false
        private var layoutListener: View.OnLayoutChangeListener? = null
        private var targetLayoutListener: View.OnLayoutChangeListener? = null
        private var attachListener: View.OnAttachStateChangeListener? = null

        fun attach() {
            resolveTarget()
            if (attachListener == null) {
                val listener = object : View.OnAttachStateChangeListener {
                    override fun onViewAttachedToWindow(view: View) {
                        resolveTarget()
                        ensureHitLayer(seed)
                    }

                    override fun onViewDetachedFromWindow(view: View) {
                        if (dragging) {
                            dragging = false
                            disallowParentIntercept(false)
                        }
                    }
                }
                attachListener = listener
                seed.addOnAttachStateChangeListener(listener)
            }
            if (layoutListener == null) {
                val listener = View.OnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
                    if (dragging) return@OnLayoutChangeListener
                    val sizeChanged =
                        right - left != oldRight - oldLeft ||
                            bottom - top != oldBottom - oldTop
                    if (sizeChanged) {
                        resolveTarget()
                    }
                    applyCommittedTranslation()
                }
                layoutListener = listener
                seed.addOnLayoutChangeListener(listener)
            }
        }

        fun detach() {
            attachListener?.let { seed.removeOnAttachStateChangeListener(it) }
            attachListener = null
            layoutListener?.let { seed.removeOnLayoutChangeListener(it) }
            layoutListener = null
            targetLayoutListener?.let { target.removeOnLayoutChangeListener(it) }
            targetLayoutListener = null
            disallowParentIntercept(false)
            resetTranslation()
        }

        fun resolveTarget() {
            val next = findTileTranslationTarget(seed)
            if (next !== target) {
                targetLayoutListener?.let { target.removeOnLayoutChangeListener(it) }
                targetLayoutListener = null
                if (target !== seed) {
                    target.translationX = 0f
                    target.translationY = 0f
                }
                target = next
                if (target !== seed) {
                    val listener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                        if (dragging) return@OnLayoutChangeListener
                        applyCommittedTranslation()
                    }
                    targetLayoutListener = listener
                    target.addOnLayoutChangeListener(listener)
                }
            }
            unclipAncestors(target)
            applyCommittedTranslation()
        }

        fun resetTranslation() {
            dragging = false
            movedPastSlop = false
            committedTx = 0f
            committedTy = 0f
            target.animate().cancel()
            target.setLayerType(View.LAYER_TYPE_NONE, null)
            target.translationX = 0f
            target.translationY = 0f
        }

        fun isHitEnabled(): Boolean {
            if (!seed.isAttachedToWindow || !seed.isShown || seed.alpha <= 0.01f) {
                return false
            }
            if (!target.isAttachedToWindow || !target.isShown || target.alpha <= 0.01f) {
                return false
            }
            if (isNearlyFullScreen(seed) || isNearlyFullScreen(target)) {
                Log.w(
                    TAG,
                    "ignoring full-screen chrome tile key=$key " +
                        "seed=${seed.width}x${seed.height} target=${target.width}x${target.height}",
                )
                return false
            }
            val bounds = screenBounds() ?: return false
            if (isNearlyFullScreen(bounds)) {
                Log.w(
                    TAG,
                    "ignoring full-screen hit bounds key=$key " +
                        "${bounds.width().toInt()}x${bounds.height().toInt()}",
                )
                return false
            }
            return RectF.intersects(bounds, availableScreenBounds(target))
        }

        fun screenBounds(): RectF? {
            if (!target.isAttachedToWindow || target.width <= 0 || target.height <= 0) {
                return null
            }
            val visible = Rect()
            if (!target.getGlobalVisibleRect(visible) || visible.isEmpty) {
                return null
            }
            return RectF(visible)
        }

        fun handleTouch(event: MotionEvent): Boolean {
            val slop = 12f * seed.resources.displayMetrics.density
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    if (!isHitEnabled()) return false
                    dragging = true
                    movedPastSlop = false
                    downRawX = event.rawX
                    downRawY = event.rawY
                    downTx = target.translationX
                    downTy = target.translationY
                    unclipAncestors(target)
                    cacheDragLimits()
                    target.setLayerType(View.LAYER_TYPE_HARDWARE, null)
                    disallowParentIntercept(true)
                    Log.i(
                        TAG,
                        "down key=$key raw=${event.rawX.toInt()},${event.rawY.toInt()} " +
                            "target=${target.width}x${target.height}",
                    )
                    return true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (!dragging) return false
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!movedPastSlop && dx * dx + dy * dy >= slop * slop) {
                        movedPastSlop = true
                    }
                    applyTranslation(downTx + dx, downTy + dy)
                    return true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (!dragging) return false
                    dragging = false
                    hasDragLimits = false
                    disallowParentIntercept(false)
                    if (event.actionMasked == MotionEvent.ACTION_UP &&
                        enableTap &&
                        !movedPastSlop
                    ) {
                        committedTx = target.translationX
                        committedTy = target.translationY
                        target.setLayerType(View.LAYER_TYPE_NONE, null)
                        invokePipTap()
                    } else if (movedPastSlop) {
                        snapToNearestCorner()
                    } else {
                        committedTx = target.translationX
                        committedTy = target.translationY
                        target.setLayerType(View.LAYER_TYPE_NONE, null)
                    }
                    return true
                }
            }
            return false
        }

        private fun invokePipTap() {
            val handler = inAppPipTapHandler
            if (handler == null) {
                Log.w(TAG, "tap key=$key ignored (no handler)")
                return
            }
            Log.i(TAG, "tap key=$key")
            handler.invoke()
        }

        private fun applyCommittedTranslation() {
            if (dragging) return
            if (target.translationX != committedTx) {
                target.translationX = committedTx
            }
            if (target.translationY != committedTy) {
                target.translationY = committedTy
            }
        }

        private fun applyTranslation(desiredTx: Float, desiredTy: Float) {
            val clamped = if (hasDragLimits) {
                Pair(
                    desiredTx.coerceIn(minOf(dragMinTx, dragMaxTx), maxOf(dragMinTx, dragMaxTx)),
                    desiredTy.coerceIn(minOf(dragMinTy, dragMaxTy), maxOf(dragMinTy, dragMaxTy)),
                )
            } else {
                clampTranslation(desiredTx, desiredTy) ?: return
            }
            if (target.translationX != clamped.first) {
                target.translationX = clamped.first
            }
            if (target.translationY != clamped.second) {
                target.translationY = clamped.second
            }
        }

        private fun cacheDragLimits() {
            val limits = translationLimits() ?: run {
                hasDragLimits = false
                return
            }
            dragMinTx = limits[0]
            dragMaxTx = limits[1]
            dragMinTy = limits[2]
            dragMaxTy = limits[3]
            hasDragLimits = true
        }

        private fun translationLimits(): FloatArray? {
            if (target.width <= 0 || target.height <= 0) return null
            val location = IntArray(2)
            target.getLocationOnScreen(location)
            val screen = rawScreenBounds(target)
            val chipGap = applyControlExclusionInsets(screen)
            val bottomPad = if (chipGap > 0f) 0f else edgePx
            val currentTx = target.translationX
            val currentTy = target.translationY
            val baseLeft = location[0] - currentTx
            val baseTop = location[1] - currentTy
            return floatArrayOf(
                screen.left + edgePx - baseLeft,
                screen.right - edgePx - target.width - baseLeft,
                screen.top + edgePx - baseTop,
                screen.bottom - bottomPad - target.height - baseTop,
            )
        }

        private fun snapToNearestCorner() {
            if (target.width <= 0 || target.height <= 0) return
            val location = IntArray(2)
            target.getLocationOnScreen(location)
            val screen = rawScreenBounds(target)
            val chipGap = applyControlExclusionInsets(screen)
            val bottomPad = if (chipGap > 0f) 0f else edgePx
            val centerX = location[0] + target.width / 2f
            val centerY = location[1] + target.height / 2f
            val midX = (screen.left + screen.right) / 2f
            val midY = (screen.top + screen.bottom) / 2f
            val destLeft = if (centerX < midX) {
                screen.left + edgePx
            } else {
                screen.right - edgePx - target.width
            }
            val destTop = if (centerY < midY) {
                screen.top + edgePx
            } else {
                screen.bottom - bottomPad - target.height
            }
            val currentTx = target.translationX
            val currentTy = target.translationY
            val destTx = destLeft - (location[0] - currentTx)
            val destTy = destTop - (location[1] - currentTy)
            val clamped = clampTranslation(destTx, destTy) ?: return
            committedTx = clamped.first
            committedTy = clamped.second
            Log.i(
                TAG,
                "snap key=$key corner=${if (centerX < midX) "leading" else "trailing"}-" +
                    "${if (centerY < midY) "top" else "bottom"}",
            )
            target.animate()
                .translationX(committedTx)
                .translationY(committedTy)
                .setDuration(180)
                .setListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) {
                        target.setLayerType(View.LAYER_TYPE_NONE, null)
                    }

                    override fun onAnimationCancel(animation: Animator) {
                        target.setLayerType(View.LAYER_TYPE_NONE, null)
                    }
                })
                .start()
        }

        private fun clampTranslation(desiredTx: Float, desiredTy: Float): Pair<Float, Float>? {
            val limits = translationLimits() ?: return null
            return Pair(
                desiredTx.coerceIn(minOf(limits[0], limits[1]), maxOf(limits[0], limits[1])),
                desiredTy.coerceIn(minOf(limits[2], limits[3]), maxOf(limits[2], limits[3])),
            )
        }

        private fun disallowParentIntercept(disallow: Boolean) {
            var parent: ViewParent? = seed.parent
            while (parent != null) {
                parent.requestDisallowInterceptTouchEvent(disallow)
                parent = parent.parent
            }
            hitLayer?.parent?.requestDisallowInterceptTouchEvent(disallow)
        }
    }

    /**
     * Translate the tile-sized host that owns the SurfaceView/TextureView.
     * Moving the child clips against that host's `clipToOutline`. Never walk
     * past the first tile-sized parent — larger Compose roots drag chat/chrome.
     */
    private fun findTileTranslationTarget(seed: View): View {
        if (!isNearlyFullScreen(seed) && isCallChromeTileSize(seed)) {
            return seed
        }
        val parent = seed.parent
        if (parent is ViewGroup &&
            !isNearlyFullScreen(parent) &&
            isCallChromeTileSize(parent)
        ) {
            Log.i(
                TAG,
                "tile target ${parent.width}x${parent.height} from seed ${seed.width}x${seed.height}",
            )
            return parent
        }
        return seed
    }

    private fun isCallChromeTileSize(view: View): Boolean {
        if (view.width <= 0 || view.height <= 0) {
            return false
        }
        val metrics = view.resources.displayMetrics
        val shortSide = minOf(metrics.widthPixels, metrics.heightPixels).toFloat()
        return view.width <= shortSide * 0.55f && view.height <= shortSide * 1.15f
    }

    private fun isNearlyFullScreen(view: View): Boolean {
        if (view.width <= 0 || view.height <= 0) {
            return false
        }
        val metrics = view.resources.displayMetrics
        return view.width >= metrics.widthPixels * 0.6f &&
            view.height >= metrics.heightPixels * 0.6f
    }

    private fun isNearlyFullScreen(bounds: RectF): Boolean {
        val metrics = hitLayer?.resources?.displayMetrics
            ?: return bounds.width() * bounds.height() > 1_000_000f
        return bounds.width() >= metrics.widthPixels * 0.6f &&
            bounds.height() >= metrics.heightPixels * 0.6f
    }

    private fun unclipAncestors(tile: View) {
        val metrics = tile.resources.displayMetrics
        val screenW = metrics.widthPixels
        val screenH = metrics.heightPixels
        var parent = tile.parent
        while (parent is ViewGroup) {
            parent.clipChildren = false
            parent.clipToPadding = false
            parent.clipToOutline = false
            if (parent.width >= screenW - 8 && parent.height >= screenH - 8) {
                break
            }
            parent = parent.parent
        }
    }

    private class CallChromeHitLayer(context: Context) : View(context) {
        private var activeSession: DragSession? = null

        init {
            setBackgroundColor(Color.TRANSPARENT)
            isClickable = false
            isFocusable = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            elevation = 10_000f
        }

        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                val session = sessionAt(event.rawX, event.rawY)
                activeSession = session
                return session?.handleTouch(event) ?: false
            }

            val session = activeSession ?: return false
            val handled = session.handleTouch(event)
            if (event.actionMasked == MotionEvent.ACTION_UP ||
                event.actionMasked == MotionEvent.ACTION_CANCEL
            ) {
                activeSession = null
            }
            return handled
        }

        override fun onDetachedFromWindow() {
            activeSession = null
            super.onDetachedFromWindow()
        }
    }
}

private fun View.findActivity(): Activity? {
    // WebRTC renderers are created with ProcessInfo's application context. Once
    // AndroidView attaches them, an Activity-backed parent exists even though the
    // renderer/host context itself remains the application context.
    var view: View? = this
    while (view != null) {
        view.context.findActivityInContext()?.let { return it }
        view = view.parent as? View
    }
    return rootView?.context?.findActivityInContext()
}

private fun Context.findActivityInContext(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}

private data class HostOutlineSignature(
    val radiusDp: Float,
    val width: Int,
    val height: Int,
)

private val appliedHostOutlines = WeakHashMap<View, HostOutlineSignature>()

internal fun applyHostRoundedOutline(view: View, radiusDp: Float) {
    val signature = HostOutlineSignature(
        radiusDp = radiusDp,
        width = view.width,
        height = view.height,
    )
    if (appliedHostOutlines[view] == signature) {
        return
    }
    appliedHostOutlines[view] = signature
    val radiusPx = radiusDp * view.resources.displayMetrics.density
    view.clipToOutline = radiusDp > 0f
    if (radiusDp > 0f) {
        view.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(v: View, outline: Outline) {
                outline.setRoundRect(0, 0, v.width, v.height, radiusPx)
            }
        }
    } else {
        view.outlineProvider = ViewOutlineProvider.BACKGROUND
    }
    view.invalidateOutline()
}
