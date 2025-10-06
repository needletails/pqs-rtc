//
//  NSView+Extension.swift
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

@MainActor
fileprivate var isFadingLooping: Bool = true

extension NSView {
 
    // Function to start the fade in/out loop
    func fadeInOutLoop(duration: TimeInterval) {
        Task { [weak self] in
            guard let self else { return }
            while isFadingLooping {
                await fadeIn(duration: duration)
                await fadeOut(duration: duration)
            }
        }
    }

    // Function to perform fade in animation
    nonisolated private func fadeIn(duration: TimeInterval) async {
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.animator().alphaValue = 1.0
            }
        }
    }

    // Function to perform fade out animation
    nonisolated private func fadeOut(duration: TimeInterval) async {
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.animator().alphaValue = 0.0
            }
        }
    }

    // Function to stop the fade in/out loop
    func stopFadeInOutLoop() {
        NSAnimationContext.endGrouping()
        isFadingLooping = false
        // Remove the animation and reset the alpha value
        self.animator().alphaValue = 1.0 // Reset to fully visible
    }
    
    public func anchors(
        top: NSLayoutYAxisAnchor? = nil,
        leading: NSLayoutXAxisAnchor? = nil,
        bottom: NSLayoutYAxisAnchor? = nil,
        trailing: NSLayoutXAxisAnchor? = nil,
        centerY: NSLayoutYAxisAnchor? = nil,
        centerX: NSLayoutXAxisAnchor? = nil,
        paddingTop: CGFloat = 0,
        paddingLeading: CGFloat = 0,
        paddingBottom: CGFloat = 0,
        paddingTrailing: CGFloat = 0,
        width: CGFloat = 0,
        height: CGFloat = 0,
        minWidth: CGFloat = 0,
        minHeight: CGFloat = 0) {
        
        translatesAutoresizingMaskIntoConstraints = false
        
        if let top = top {
            self.topAnchor.constraint(equalTo: top, constant: paddingTop).isActive = true
        }
        if let leading = leading {
            self.leadingAnchor.constraint(equalTo: leading, constant: paddingLeading).isActive = true
        }
        if let bottom = bottom {
            self.bottomAnchor.constraint(equalTo: bottom, constant: -paddingBottom).isActive = true
        }
        if let trailing = trailing {
            self.trailingAnchor.constraint(equalTo: trailing, constant: -paddingTrailing).isActive = true
        }
        if let centerX = centerX {
            self.centerXAnchor.constraint(equalTo: centerX).isActive = true
        }
        if let centerY = centerY {
            self.centerYAnchor.constraint(equalTo: centerY).isActive = true
        }
        
        // Set default width and height
        if width > 0 {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if height > 0 {
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        
        // Set minimum width and height
        if minWidth > 0 {
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        }
        if minHeight > 0 {
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        }
    }

}
#endif
