//
//  NTMTKViewRepresentable.swift
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

#if !os(Android)
import Foundation
import SwiftUI
#endif

#if os(iOS)
import UIKit

/// SwiftUI wrapper for `NTMTKView` (iOS).
///
/// `NTMTKView` is a Metal-backed renderer used for displaying local/remote video frames.
/// This representable creates the view and starts rendering automatically.
public struct NTMTKViewRepresentable: UIViewRepresentable {
    public typealias UIViewType = NTMTKView
    
    private let type: NTMTKView.ViewType
    private let contextName: String
    
    /// Creates a SwiftUI wrapper around `NTMTKView`.
    ///
    /// - Parameters:
    ///   - type: The view’s role (for example, local preview vs. remote render).
    ///   - contextName: A stable identifier used to isolate Metal pipeline state.
    public init(type: NTMTKView.ViewType, contextName: String) {
        self.type = type
        self.contextName = contextName
    }
    
    public func makeUIView(context: Context) -> NTMTKView {
        do {
            let view = try NTMTKView(type: type, contextName: contextName)
            Task { @MainActor in
                await view.startRendering()
            }
            return view
        } catch {
            assertionFailure("Could not create NTMTKView: \(error)")
            let view = NTMTKView(fallbackType: type, contextName: contextName)
            Task { @MainActor in
                await view.startRendering()
            }
            return view
        }
    }
    
    public func updateUIView(_ uiView: NTMTKView, context: Context) {
        // No dynamic updates yet
    }

    /// Shuts down the Metal rendering pipeline when SwiftUI tears down the view.
    public static func dismantleUIView(_ uiView: NTMTKView, coordinator: ()) {
        uiView.shutdownMetalStream()
    }
}

#elseif os(macOS)
import AppKit

/// SwiftUI wrapper for `NTMTKView` (macOS).
///
/// `NTMTKView` is a Metal-backed renderer used for displaying local/remote video frames.
/// This representable creates the view and starts rendering automatically.
public struct NTMTKViewRepresentable: NSViewRepresentable {
    public typealias NSViewType = NTMTKView
    
    private let type: NTMTKView.ViewType
    private let contextName: String
    
    /// Creates a SwiftUI wrapper around `NTMTKView`.
    ///
    /// - Parameters:
    ///   - type: The view’s role (for example, local preview vs. remote render).
    ///   - contextName: A stable identifier used to isolate Metal pipeline state.
    public init(type: NTMTKView.ViewType, contextName: String) {
        self.type = type
        self.contextName = contextName
    }
    
    public func makeNSView(context: Context) -> NTMTKView {
        do {
            let view = try NTMTKView(type: type, contextName: contextName)
            Task { @MainActor in
                await view.startRendering()
            }
            return view
        } catch {
            assertionFailure("Could not create NTMTKView: \(error)")
            let view = NTMTKView(fallbackType: type, contextName: contextName)
            Task { @MainActor in
                await view.startRendering()
            }
            return view
        }
    }
    
    public func updateNSView(_ nsView: NTMTKView, context: Context) {
        // No dynamic updates yet
    }

    /// Shuts down the Metal rendering pipeline when SwiftUI tears down the view.
    public static func dismantleNSView(_ nsView: NTMTKView, coordinator: ()) {
        nsView.shutdownMetalStream()
    }
}
#endif


