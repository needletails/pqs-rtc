//
//  NSImage+Extension.swift
//  pqs-rtc
//
//  Created by Cole M on 3/18/25.
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

extension NSImage {
    /// Returns a new image clipped to a circle with an optional border.
    ///
    /// This is used by the macOS in-call UI to render avatars/profile images consistently.
    ///
    /// - Parameters:
    ///   - size: Output image size.
    ///   - borderWidth: Border line width in points.
    ///   - borderColor: Border stroke color.
    /// - Returns: A newly rendered circular image, or `nil` if rendering fails.
    func circularImage(size: NSSize, borderWidth: CGFloat, borderColor: NSColor) -> NSImage? {
        // Create a new NSImage with the specified size
        let circularImage = NSImage(size: size)
        circularImage.lockFocus()
        
        // Create a circular path
        let rect = NSRect(origin: .zero, size: size)
        let circlePath = NSBezierPath(ovalIn: rect)
        
        // Clip to the circular path
        circlePath.addClip()
        
        // Draw the image in the context
        self.draw(in: rect)
        
        // Set the stroke color and line width for the border
        borderColor.setStroke()
        circlePath.lineWidth = borderWidth
        
        // Stroke the circular path to create the border
        circlePath.stroke()
        
        // Unlock focus and return the new circular image
        circularImage.unlockFocus()
        
        return circularImage
    }
}
#endif
