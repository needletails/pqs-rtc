//
//  UIImage+Extension.swift
//  needle-tail-rtc
//
//  Created by Cole M on 3/17/25.
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
#if os(iOS)
import UIKit

extension UIImage {
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
