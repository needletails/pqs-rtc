//
//  VideoCallScrollView.swift
//  needle-tail-rtc
//
//  Created by Cole M on 1/11/25.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
//
#if os(macOS)
import AppKit

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
    
    private func setupScrollView() {
        self.wantsLayer = true
        self.layer?.backgroundColor = Constants.DARK_CHARCOAL_COLOR
        self.drawsBackground = false
        self.verticalScroller?.isEnabled = false
        self.horizontalScroller?.isEnabled = false
    }
}
#endif
