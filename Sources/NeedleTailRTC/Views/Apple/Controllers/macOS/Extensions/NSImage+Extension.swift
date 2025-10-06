//
//  NSImage+Extension.swift
//  needle-tail-rtc
//
//  Created by Cole M on 3/18/25.
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

extension NSImage {
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
