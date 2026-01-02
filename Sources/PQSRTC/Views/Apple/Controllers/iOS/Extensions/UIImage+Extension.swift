//
//  UIImage+Extension.swift
//  pqs-rtc
//
//  Created by Cole M on 3/17/25.
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

#if os(iOS)
import UIKit

extension UIImage {
    /// Returns a circularly clipped version of the image with an optional border.
    ///
    /// - Parameters:
    ///   - size: Output image size.
    ///   - borderWidth: Border width in points.
    ///   - borderColor: Border color.
    /// - Returns: A new image rendered into a circle, or `nil` if the graphics context cannot be created.
    func circularImage(size: CGSize, borderWidth: CGFloat, borderColor: UIColor) -> UIImage? {
        let rect = CGRect(origin: .zero, size: size)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        let circlePath = UIBezierPath(ovalIn: rect)
        context.saveGState()
        circlePath.addClip()
        
        self.draw(in: rect)
        
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(borderWidth)
        circlePath.stroke()
        
        context.restoreGState()
        
        let circularImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return circularImage
    }
}
#endif
