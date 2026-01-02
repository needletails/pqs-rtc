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

/// `NSScrollView` used by the macOS in-call UI.
///
/// This scroll view hosts a ``VideoCallCollectionView`` as its `documentView` and
/// disables scrollers/background drawing to better match the call UI.
final class VideoCallScrollView: NSScrollView {
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupScrollView()
        self.documentView = VideoCallCollectionView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupScrollView()
        self.documentView = VideoCallCollectionView()
    }
    
    /// Applies common appearance/scroll settings for the call UI.
    private func setupScrollView() {
        self.wantsLayer = true
        self.layer?.backgroundColor = Constants.DARK_CHARCOAL_COLOR
        self.drawsBackground = false
        self.verticalScroller?.isEnabled = false
        self.horizontalScroller?.isEnabled = false
    }
}
#endif
