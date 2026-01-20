//
//  RemoteViewItem.swift
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

import Foundation
import Observation
import SkipFuse
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS) || os(macOS)

// MARK: - Collection View Cell

#if os(iOS)
/// A collection view cell for displaying remote video content in iOS applications.
/// 
/// This cell is designed to host video views and provides a clean, minimal interface
/// for video conferencing applications.
@MainActor
public final class RemoteViewItemCell: UICollectionViewCell {
    
    // MARK: - Constants
    
    /// Reuse identifier for the collection view cell
    public static let reuseIdentifier = "remote-video-item-cell-reuse-identifier"
    
    // MARK: - Initialization
    
    /// Creates a new instance of RemoteViewItemCell with the specified frame.
    /// 
    /// - Parameter frame: The frame rectangle for the cell
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupCell()
    }
    
    /// Creates a new instance of RemoteViewItemCell from a coder.
    /// 
    /// - Parameter coder: The coder to use for initialization
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCell()
    }
    
    // MARK: - Private Methods
    
    private func setupCell() {
        contentView.layoutMargins = .zero
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        // Ensure reused cells never accumulate multiple NTMTKViews or constraints.
        contentView.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Installs a video view as the cell’s sole content, pinned edge-to-edge.
    func setVideoView(_ view: UIView) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }
}
#endif

// MARK: - Conference Call Sections

/// Enumeration representing different sections in a conference call collection view.
/// 
/// This enum provides a type-safe way to identify different sections within
/// the conference call interface.
public enum ConferenceCallSections: Int, CaseIterable, Sendable {
    /// The initial section of the conference call interface
    case initial = 0
}

// MARK: - Video Views Manager

/// A manager class for handling video views in a conference call.
/// 
/// This class provides a centralized way to manage video view models and supports
/// both Combine-based reactive programming and traditional property observation.
@MainActor
@Observable
public final class VideoViews {
    
    // MARK: - Properties
    /// The collection of video view models
    public var views: [VideoViewModel] = []
    
    // MARK: - Initialization
    
    /// Creates a new instance of VideoViews
    public init() {}
    
    // MARK: - Public Methods
    
    /// Retrieves the current collection of video view models.
    /// 
    /// - Returns: An array of video view models
    public func getViews() async -> [VideoViewModel] {
        return views
    }
    
    /// Adds a video view model to the collection.
    /// 
    /// - Parameter viewModel: The video view model to add
    public func addView(_ viewModel: VideoViewModel) {
        views.append(viewModel)
    }
    
    /// Removes a video view model from the collection.
    /// 
    /// - Parameter viewModel: The video view model to remove
    public func removeView(_ viewModel: VideoViewModel) {
        views.removeAll { $0.id == viewModel.id }
    }
    
    /// Removes all video view models from the collection.
    public func removeAllViews() {
        views.removeAll()
    }
    
    /// Updates the collection with new video view models.
    /// 
    /// - Parameter newViews: The new collection of video view models
    public func updateViews(_ newViews: [VideoViewModel]) {
        views = newViews
    }
    
    /// Finds a video view model by its identifier.
    /// 
    /// - Parameter id: The unique identifier of the video view model
    /// - Returns: The matching video view model, or nil if not found
    public func findView(withId id: UUID) -> VideoViewModel? {
        return views.first { $0.id == id }
    }
    
    /// Returns the number of video view models in the collection.
    /// 
    /// - Returns: The count of video view models
    public var count: Int {
        return views.count
    }
    
    /// Checks if the collection is empty.
    /// 
    /// - Returns: True if the collection has no video view models, false otherwise
    public var isEmpty: Bool {
        return views.isEmpty
    }
}

// MARK: - Video View Model

/// A model representing a video view in a conference call.
/// 
/// This struct encapsulates the data needed to display a video view,
/// including a unique identifier and the associated video view component.
@MainActor
public struct VideoViewModel: Hashable, Identifiable {
    
    // MARK: - Properties
    
    /// Unique identifier for the video view model
    public let id: UUID
    
    /// The video view component associated with this model
    public let videoView: NTMTKView
    
    // MARK: - Initialization
    
    /// Creates a new video view model with the specified video view.
    /// 
    /// - Parameter videoView: The video view component to associate with this model
    public init(videoView: NTMTKView) {
        self.id = UUID()
        self.videoView = videoView
    }
    
    /// Creates a new video view model with a specific identifier and video view.
    /// 
    /// - Parameters:
    ///   - id: The unique identifier for this model
    ///   - videoView: The video view component to associate with this model
    public init(id: UUID, videoView: NTMTKView) {
        self.id = id
        self.videoView = videoView
    }
    
    // MARK: - Hashable Conformance
    
    /// Compares two video view models for equality.
    /// 
    /// - Parameters:
    ///   - lhs: The left-hand side video view model
    ///   - rhs: The right-hand side video view model
    /// - Returns: True if the models have the same identifier, false otherwise
    public nonisolated static func == (lhs: VideoViewModel, rhs: VideoViewModel) -> Bool {
        return lhs.id == rhs.id
    }
    
    /// Generates a hash value for the video view model.
    /// 
    /// - Parameter hasher: The hasher to use for generating the hash value
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
#endif
