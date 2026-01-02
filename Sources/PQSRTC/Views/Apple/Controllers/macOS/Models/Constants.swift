//
//  Constants.swift
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

/// Shared UI constants for the macOS in-call AppKit views.
///
/// This type groups colors and identifiers used across the macOS controller/view files.
enum Constants {
    /// Off-white text color used for labels.
    static let OFF_WHITE_COLOR = NSColor(calibratedRed: 221, green: 221, blue: 221, alpha: 1)

    /// Dark background color.
    static let NS_DARK_CHARCOAL_COLOR = NSColor(red: 21/255, green: 21/255, blue: 21/255, alpha: 1)

    /// Dark background color with 50% alpha.
    static let NS_DARK_CHARCOAL_COLOR_HALF = NSColor(red: 21/255, green: 21/255, blue: 21/255, alpha: 0.5)

    /// CoreGraphics-backed version of the dark background color.
    static let DARK_CHARCOAL_COLOR = NSColor(red: 21/255, green: 21/255, blue: 21/255, alpha: 1).cgColor

    /// Collection view item identifier used for video tiles.
    static let VIDEO_IDENTIFIER = NSUserInterfaceItemIdentifier(rawValue: "video-call-identifier")
}
#endif
