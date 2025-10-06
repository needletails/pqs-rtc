//
//  VideoCallCollectionView.swift
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

final class VideoCallCollectionView: NSCollectionView {
    
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
}
#endif
