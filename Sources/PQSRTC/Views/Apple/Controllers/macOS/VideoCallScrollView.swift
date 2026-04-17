//
//  VideoCallScrollView.swift
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

/// `NSScrollView` used by the macOS in-call UI.
///
/// This scroll view hosts a ``VideoCallCollectionView`` as its `documentView` and
/// disables scrollers/background drawing to better match the call UI.
final class VideoCallScrollView: NSScrollView {

    private let layoutProbeLog = NeedleTailLogger("[VideoCallLayoutProbe][ScrollView]")
    private static let isLayoutProbeEnabled: Bool = {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.environment["PQSRTC_LAYOUT_PROBE"] == "1"
        #endif
    }()
    /// Last values logged to avoid repeating identical lines every layout pass.
    private var lastProbeSignature: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupScrollView()
        self.installDocumentView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupScrollView()
        self.installDocumentView()
    }
    
    /// Applies common appearance/scroll settings for the call UI.
    private func setupScrollView() {
        self.wantsLayer = true
        self.layer?.backgroundColor = Constants.DARK_CHARCOAL_COLOR
        self.drawsBackground = false
        self.hasVerticalScroller = false
        self.hasHorizontalScroller = false
        self.autohidesScrollers = true
    }
    
    private func installDocumentView() {
        let collectionView = VideoCallCollectionView(frame: contentView.bounds)
        collectionView.autoresizingMask = [.width, .height]
        collectionView.translatesAutoresizingMaskIntoConstraints = true
        documentView = collectionView
    }

    /// The call surface is a fixed viewport, not a scrollable feed.
    /// Ignore wheel/trackpad scrolling so clip-view origin never drifts.
    override func scrollWheel(with event: NSEvent) {}
    
    override func layout() {
        super.layout()
        guard let documentView else { return }
        let clipView = contentView
        let clipBounds = clipView.bounds
        let previousDocFrame = documentView.frame
        let clipOriginDrift = clipBounds.origin != .zero
        if clipOriginDrift {
            // This call surface is intentionally non-scrollable. Keep clip-view origin pinned to zero
            // or NSCollectionView can report `visibleItems=0` while layout attributes remain valid.
            clipView.setBoundsOrigin(.zero)
            reflectScrolledClipView(clipView)
        }

        let targetDocFrame = NSRect(origin: .zero, size: clipView.bounds.size)
        let fullRectMismatch = previousDocFrame != targetDocFrame
        if fullRectMismatch {
            documentView.frame = targetDocFrame
        }
        if documentView.bounds.origin != .zero {
            documentView.setBoundsOrigin(.zero)
        }

        let sizeMismatch = previousDocFrame.size != targetDocFrame.size
        let sig = "\(Int(frame.size.width))x\(Int(frame.size.height))|\(Int(clipView.bounds.size.width))x\(Int(clipView.bounds.size.height))@\(Int(clipView.bounds.origin.x)),\(Int(clipView.bounds.origin.y))|\(Int(previousDocFrame.size.width))x\(Int(previousDocFrame.size.height))@\(Int(previousDocFrame.origin.x)),\(Int(previousDocFrame.origin.y))|\(sizeMismatch)|\(fullRectMismatch)|clipOriginDrift=\(clipOriginDrift)"
        if sig != lastProbeSignature {
            lastProbeSignature = sig
            guard Self.isLayoutProbeEnabled else { return }
            layoutProbeLog.log(
                level: .debug,
                message: "[VideoCallLayoutProbe] sv=\(Int(frame.size.width))x\(Int(frame.size.height)) clip=\(Int(clipView.bounds.size.width))x\(Int(clipView.bounds.size.height))@\(Int(clipView.bounds.origin.x)),\(Int(clipView.bounds.origin.y)) docPrev=\(Int(previousDocFrame.size.width))x\(Int(previousDocFrame.size.height))@\(Int(previousDocFrame.origin.x)),\(Int(previousDocFrame.origin.y)) docNow=\(Int(documentView.frame.size.width))x\(Int(documentView.frame.size.height))@\(Int(documentView.frame.origin.x)),\(Int(documentView.frame.origin.y)) sizeMismatch=\(sizeMismatch) fullRectMismatch=\(fullRectMismatch) clipOriginDrift=\(clipOriginDrift) note=forcedZeroOriginNonScrollableViewport"
            )
        }
    }
}
#endif
