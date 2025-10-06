//
//  NTMTKViewRepresentable.swift
//
//  Created by AI Assistant on 10/5/25.
//
//  SwiftUI wrappers for NTMTKView across platforms.
//
#if !os(Android)
import Foundation
import SwiftUI
#endif

#if os(iOS)
import UIKit

public struct NTMTKViewRepresentable: UIViewRepresentable {
    public typealias UIViewType = NTMTKView

    private let type: NTMTKView.ViewType
    private let contextName: String

    public init(type: NTMTKView.ViewType, contextName: String) {
        self.type = type
        self.contextName = contextName
    }

    public func makeUIView(context: Context) -> NTMTKView {
        let view = try! NTMTKView(type: type, contextName: contextName)
        Task { @MainActor in
            await view.startRendering()
        }
        return view
    }

    public func updateUIView(_ uiView: NTMTKView, context: Context) {
        // No dynamic updates yet
    }
}

#elseif os(macOS)
import AppKit

public struct NTMTKViewRepresentable: NSViewRepresentable {
    public typealias NSViewType = NTMTKView

    private let type: NTMTKView.ViewType
    private let contextName: String

    public init(type: NTMTKView.ViewType, contextName: String) {
        self.type = type
        self.contextName = contextName
    }

    public func makeNSView(context: Context) -> NTMTKView {
        let view = try! NTMTKView(type: type, contextName: contextName)
        Task { @MainActor in
            await view.startRendering()
        }
        return view
    }

    public func updateNSView(_ nsView: NTMTKView, context: Context) {
        // No dynamic updates yet
    }
}
#endif


