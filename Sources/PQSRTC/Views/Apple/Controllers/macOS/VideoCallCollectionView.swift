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

/// `NSCollectionView` used by the macOS in-call UI.
///
/// This view centralizes a few visual tweaks required by the call UI:
/// - ensures a consistent dark background
/// - disables scroll chrome for embedded scroll views
/// - hides visual effect views that would otherwise add blur/vibrancy
final class VideoCallCollectionView: NSCollectionView {
    private var lastKnownSize: CGSize = .zero
    private var layoutInvalidationScheduled = false
    
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
        lastKnownSize = bounds.size
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
        guard bounds.size != lastKnownSize else { return }
        lastKnownSize = bounds.size
        guard layoutInvalidationScheduled == false else { return }
        layoutInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutInvalidationScheduled = false
            // Skip transient zero-sized layouts during live resize; a later pass will invalidate again.
            guard self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.collectionViewLayout?.invalidateLayout()
        }
    }
}
#endif
