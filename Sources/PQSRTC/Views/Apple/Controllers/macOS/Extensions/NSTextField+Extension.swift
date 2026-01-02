//
//  NSTextField+Extension.swift
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

extension NSTextField {
    /// Creates an `NSTextField` configured like a storyboard “Label”.
    ///
    /// The macOS in-call UI uses this helper to avoid repeating AppKit configuration boilerplate.
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

    /// Creates an `NSTextField` configured like a storyboard “Wrapping Label”.
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
