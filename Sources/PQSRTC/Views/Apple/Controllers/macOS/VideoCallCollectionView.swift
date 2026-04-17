//
//  VideoCallCollectionView.swift
//  pqs-rtc
//
//  Created by Cole M on 1/11/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//
//  This file is part of the PQSRTC SDK, which provides
//  Frame Encrypted VoIP Capabilities
//

#if os(macOS)
import AppKit
import NeedleTailLogger

/// `NSCollectionView` used by the macOS in-call UI.
///
/// This view centralizes a few visual tweaks required by the call UI:
/// - ensures a consistent dark background
/// - disables scroll chrome for embedded scroll views
/// - hides visual effect views that would otherwise add blur/vibrancy
final class VideoCallCollectionView: NSCollectionView {
    private let layoutProbeLog = NeedleTailLogger("[VideoCallLayoutProbe][CollectionView]")
    private var lastKnownSize: CGSize = .zero
    private var layoutInvalidationScheduled = false
    private var lastProbeSignature: String = ""
    private var windowEndLiveResizeObserver: NSObjectProtocol?
    private var lastLayoutSnapshotSignature: String = ""
    private static let isLayoutProbeEnabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["PQSRTC_LAYOUT_PROBE"] == "1"
        #endif
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCollectionView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCollectionView()
    }
    
    private func configureCollectionView() {
        wantsLayer = true
        layer?.backgroundColor = Constants.DARK_CHARCOAL_COLOR
        autoresizingMask = [.width, .height]
        isSelectable = false
        let b = bounds.size
        if b.width > 0, b.height > 0 {
            lastKnownSize = b
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowEndLiveResizeObserver {
            NotificationCenter.default.removeObserver(windowEndLiveResizeObserver)
            self.windowEndLiveResizeObserver = nil
        }
        guard let window else { return }
        // After live resize, compositional layout + item frames sometimes stall; one explicit
        // invalidation aligns documentView bounds with clip and refreshes video tiles.
        windowEndLiveResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.logLayoutProbe("didEndLiveResize invalidateLayout bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height))")
            self.collectionViewLayout?.invalidateLayout()
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            self.logLayoutSnapshot(reason: "didEndLiveResize-immediate")
            self.schedulePostResizeLayoutSnapshots()
        }
    }
    
    /// Intercepts subview attachment to normalize appearance.
    ///
    /// - Important: This method intentionally adjusts select child view types (like `NSScrollView`)
    ///   to match the in-call UI requirements. Call `super.addSubview(_:)` after applying any
    ///   per-view tweaks.
    override func addSubview(_ view: NSView) {
        self.wantsLayer = true
        self.layer?.backgroundColor = Constants.DARK_CHARCOAL_COLOR
        if let v = view as? NSScrollView {
            v.drawsBackground = false
            v.hasHorizontalScroller = false
            v.hasVerticalScroller = false
        }
        if let vxf = view as? NSVisualEffectView {
            vxf.isHidden = true
        }
        super.addSubview(view)
    }
    
    override func layout() {
        super.layout()
        invalidateLayoutIfNeeded()
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateLayoutIfNeeded()
    }
    
    private func invalidateLayoutIfNeeded() {
        let b = bounds.size
        // Never treat transient zero bounds as the new baseline — during live resize AppKit can
        // report .zero briefly; recording it in `lastKnownSize` can suppress a later invalidate
        // when the view returns to a non-zero size (tiles stay at stale/zero layout).
        guard b.width > 0, b.height > 0 else { return }
        guard b != lastKnownSize else { return }
        let previous = lastKnownSize
        lastKnownSize = b
        if layoutInvalidationScheduled {
            let sig = "\(Int(b.width))x\(Int(b.height))|\(Int(previous.width))x\(Int(previous.height))|coalesce"
            if sig != lastProbeSignature {
                lastProbeSignature = sig
                logLayoutProbe("bounds=\(Int(b.width))x\(Int(b.height)) from=\(Int(previous.width))x\(Int(previous.height)) action=coalesceSkipAsyncAlreadyQueued")
            }
            return
        }
        layoutInvalidationScheduled = true
        let useSyncMain = Thread.isMainThread
        logLayoutProbe("bounds=\(Int(b.width))x\(Int(b.height)) from=\(Int(previous.width))x\(Int(previous.height)) action=\(useSyncMain ? "invalidateLayoutSyncMain" : "scheduleInvalidateOnNextMain")")
        let runInvalidate: () -> Void = { [weak self] in
            guard let self else { return }
            self.layoutInvalidationScheduled = false
            // Skip transient zero-sized layouts during live resize; a later pass will invalidate again.
            guard self.bounds.width > 0, self.bounds.height > 0 else {
                self.logLayoutProbe("action=asyncSkipZeroBounds bounds=\(self.bounds.width)x\(self.bounds.height)")
                return
            }
            self.logLayoutProbe("action=invalidateLayoutNow bounds=\(Int(self.bounds.width))x\(Int(self.bounds.height))")
            self.collectionViewLayout?.invalidateLayout()
        }
        if useSyncMain {
            runInvalidate()
        } else {
            DispatchQueue.main.async(execute: runInvalidate)
        }
    }

    private func schedulePostResizeLayoutSnapshots() {
        let delays: [TimeInterval] = [0.05, 0.2, 0.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.window != nil else { return }
                self.layoutSubtreeIfNeeded()
                let reason = "didEndLiveResize+\(Int(delay * 1000))ms"
                self.logLayoutSnapshot(reason: reason)
            }
        }
    }

    private func logLayoutSnapshot(reason: String) {
        let liveResize = window?.inLiveResize == true
        let sections = numberOfSections
        let totalItems = (0..<sections).reduce(0) { partial, section in
            partial + numberOfItems(inSection: section)
        }
        let visibleItemCount = visibleItems().count
        let attrs = collectionViewLayout?.layoutAttributesForElements(in: bounds) ?? []
        let attrSummary = attrs
            .prefix(3)
            .map { attr in
                let frame = attr.frame.integral
                let item = attr.indexPath?.item ?? -1
                return "i\(item)=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height))"
            }
            .joined(separator: " ")
        let sig = [
            reason,
            "\(Int(bounds.width))x\(Int(bounds.height))",
            "\(Int(frame.width))x\(Int(frame.height))",
            "\(sections)",
            "\(totalItems)",
            "\(visibleItemCount)",
            "\(attrs.count)",
            attrSummary
        ].joined(separator: "|")
        guard sig != lastLayoutSnapshotSignature else { return }
        lastLayoutSnapshotSignature = sig
        logLayoutProbe("snapshot reason=\(reason) inLiveResize=\(liveResize) bounds=\(Int(bounds.width))x\(Int(bounds.height)) frame=\(Int(frame.width))x\(Int(frame.height)) visibleRect=\(Int(visibleRect.width))x\(Int(visibleRect.height)) sections=\(sections) totalItems=\(totalItems) visibleItems=\(visibleItemCount) attrsInBounds=\(attrs.count) attrs=\(attrSummary.isEmpty ? "none" : attrSummary)")
    }

    private func logLayoutProbe(_ message: String) {
        guard Self.isLayoutProbeEnabled else { return }
        layoutProbeLog.log(level: .debug, message: "[VideoCallLayoutProbe] \(message)")
    }
}
#endif
