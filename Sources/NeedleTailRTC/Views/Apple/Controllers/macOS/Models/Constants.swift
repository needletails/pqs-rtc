//
//  Constants.swift
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

enum Constants {
    static let OFF_WHITE_COLOR = NSColor(calibratedRed: 221, green: 221, blue: 221, alpha: 1)
    static let NS_DARK_CHARCOAL_COLOR = NSColor(red: 21/255, green: 21/255, blue: 21/255, alpha: 1)
    static let NS_DARK_CHARCOAL_COLOR_HALF = NSColor(red: 21/255, green: 21/255, blue: 21/255, alpha: 0.5)
    static let DARK_CHARCOAL_COLOR = NSColor(red: 21/255, green: 21/255, blue: 21/255, alpha: 1).cgColor
    static let VIDEO_IDENTIFIER = NSUserInterfaceItemIdentifier(rawValue: "video-call-identifier")
}
#endif
