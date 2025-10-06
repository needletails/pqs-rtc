//
//  NSTextField+Extension.swift
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

extension NSTextField {
    
    /// Return an `NSTextField` configured exactly like one created by dragging a “Label” into a storyboard.
    class func newLabel() -> NSTextField {
        let label = NSTextField()
        label.wantsLayer = true
        label.isEditable = false
        label.isSelectable = false
        label.backgroundColor = .clear
        label.isBordered = false
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.alignment = .natural
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: label.controlSize))
        //        label.lineBreakMode = .byClipping
        label.cell?.isScrollable = true
        label.cell?.wraps = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    
    /// Return an `NSTextField` configured exactly like one created by dragging a “Wrapping Label” into a storyboard.
    class func newWrappingLabel() -> NSTextField {
        let label = newLabel()
        label.lineBreakMode = .byWordWrapping
        label.cell?.isScrollable = true
        label.cell?.wraps = true
        label.maximumNumberOfLines = 60
        return label
    }
}
#endif
