//
//  CollectionViewSections.swift
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
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS) || os(macOS)

/// A utility struct that provides collection view layout sections for video conferencing UI.
/// 
/// This struct contains predefined layout configurations for different video conferencing scenarios,
/// including full-screen video display and multi-participant conference views.
@MainActor
public struct CollectionViewSections {
    
    // MARK: - Constants
    
    /// Default aspect ratio for video content (16:9)
    private static let defaultAspectRatio: CGFloat = 16.0 / 9.0
    
    /// Default content insets for conference view items
    private static let defaultContentInsets = NSDirectionalEdgeInsets(
        top: 15,
        leading: 15,
        bottom: 15,
        trailing: 15
    )
    
    // MARK: - Initialization
    
    /// Creates a new instance of CollectionViewSections
    public init() {}
    
    // MARK: - Layout Sections
    
    /// Creates a full-screen layout section for single video display.
    /// 
    /// - Returns: A collection layout section configured for full-screen video display
    /// - Note: On iOS, this creates a true full-screen layout. On macOS, it maintains a 16:9 aspect ratio.
    public func fullScreenItem() -> NSCollectionLayoutSection {
        #if os(iOS)
        return createFullScreenLayout()
        #elseif os(macOS)
        // Keep the remote tile pinned to the full collection bounds while the window is resized.
        // Renderer-level videoGravity/scale handles letterboxing; layout should not collapse.
        return createFullScreenLayout()
        #endif
    }
    
    /// Creates a full-screen layout section with a custom aspect ratio.
    /// 
    /// - Parameter aspectRatio: The desired aspect ratio (width / height)
    /// - Returns: A collection layout section configured for full-screen video display
    /// - Note: This method is primarily used on macOS to maintain consistent video proportions
    public func fullScreenItem(aspectRatio: CGFloat) -> NSCollectionLayoutSection {
        guard aspectRatio > 0 else {
            assertionFailure("Aspect ratio must be greater than 0")
#if os(iOS)
            return createFullScreenLayout()
#elseif os(macOS)
            return createAspectRatioLayout(aspectRatio: Self.defaultAspectRatio)
#endif
        }
#if os(iOS)
        return createFullScreenLayout()
#elseif os(macOS)
        return createAspectRatioLayout(aspectRatio: aspectRatio)
#endif
    }
    
    /// Creates a conference view layout section for multiple video participants.
    /// 
    /// - Parameter itemCount: The number of video items to display in the conference view
    /// - Returns: A collection layout section configured for multi-participant conference display
    /// - Note: The layout automatically adjusts item sizes based on the participant count
    public func conferenceViewSection(itemCount: Int) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        
        return createConferenceLayout(itemCount: itemCount, groupAbsoluteExtent: nil)
    }

    #if os(iOS)
    /// Conference layout sized for the current collection view container.
    ///
    /// Portrait phones need a different shape than desktop/landscape: a fixed `2 x 1`
    /// layout makes two-person calls look like narrow vertical strips. This variant
    /// chooses rows/columns from the live container and sizes the page group around a
    /// camera-friendly aspect ratio, packing tiles from the top.
    public func conferenceViewSection(
        itemCount: Int,
        containerSize: CGSize,
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }

        return createConferenceLayout(
            itemCount: itemCount,
            groupAbsoluteExtent: nil,
            containerSize: containerSize,
            safeAreaTop: safeAreaTop)
    }

    /// Conference tiles with an explicit aspect (used while the local user is presenting
    /// and the snapshot has cameras only — those items must follow device orientation).
    public func conferenceViewSection(
        itemCount: Int,
        containerSize: CGSize,
        targetAspect: CGFloat,
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        return createConferenceLayout(
            itemCount: itemCount,
            groupAbsoluteExtent: nil,
            containerSize: containerSize,
            targetAspect: targetAspect,
            safeAreaTop: safeAreaTop)
    }
    #endif
    
    #if os(macOS)
    /// Conference row with a non-zero group extent so items do not collapse when the compositional container is briefly `.zero` during window resize.
    public func conferenceViewSection(
        itemCount: Int,
        groupAbsoluteExtent: CGSize,
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        return createConferenceLayout(
            itemCount: itemCount,
            groupAbsoluteExtent: groupAbsoluteExtent,
            safeAreaTop: safeAreaTop
        )
    }
    #endif
    
    /// Creates a conference view layout section with custom content insets.
    /// 
    /// - Parameters:
    ///   - itemCount: The number of video items to display in the conference view
    ///   - contentInsets: Custom content insets for the video items
    /// - Returns: A collection layout section configured for multi-participant conference display
    public func conferenceViewSection(
        itemCount: Int,
        contentInsets: NSDirectionalEdgeInsets
    ) -> NSCollectionLayoutSection {
        guard itemCount > 0 else {
            assertionFailure("Item count must be greater than 0")
            return createSingleItemLayout()
        }
        
        return createConferenceLayout(itemCount: itemCount, contentInsets: contentInsets, groupAbsoluteExtent: nil)
    }
    
    // MARK: - Private Helper Methods
    
    #if os(iOS)
    private func createFullScreenLayout() -> NSCollectionLayoutSection {
        createFullScreenLayout(groupAbsoluteExtent: nil)
    }

    private func createFullScreenLayout(groupAbsoluteExtent: CGSize?) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)

        let groupLayoutSize: NSCollectionLayoutSize
        if let g = groupAbsoluteExtent, g.width >= 1, g.height >= 1 {
            groupLayoutSize = NSCollectionLayoutSize(
                widthDimension: .absolute(max(1, g.width)),
                heightDimension: .absolute(max(1, g.height)))
        } else {
            groupLayoutSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0))
        }

        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupLayoutSize,
            subitems: [item])

        return NSCollectionLayoutSection(group: group)
    }

    /// Pins the solo remote tile to the live collection bounds (critical after landscape rotation).
    public func fullScreenItem(groupAbsoluteExtent: CGSize) -> NSCollectionLayoutSection {
        createFullScreenLayout(groupAbsoluteExtent: groupAbsoluteExtent)
    }
    #endif
    
    #if os(macOS)
    private func createAspectRatioLayout(aspectRatio: CGFloat) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalWidth(1.0 / aspectRatio))
        
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalWidth(1.0 / aspectRatio)),
            subitems: [item])
        
        return NSCollectionLayoutSection(group: group)
    }
    
    private func createFullScreenLayout(groupAbsoluteExtent: CGSize? = nil) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupLayoutSize: NSCollectionLayoutSize
        if let g = groupAbsoluteExtent {
            let w = max(1, g.width)
            let h = max(1, g.height)
            groupLayoutSize = NSCollectionLayoutSize(
                widthDimension: .absolute(w),
                heightDimension: .absolute(h))
        } else {
            groupLayoutSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0))
        }
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupLayoutSize,
            subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }
    
    /// Single-tile layout with explicit group size (macOS VoIP resize / transient zero container).
    public func fullScreenItem(groupAbsoluteExtent: CGSize) -> NSCollectionLayoutSection {
        createFullScreenLayout(groupAbsoluteExtent: groupAbsoluteExtent)
    }
    #endif
    
    private func createConferenceLayout(
        itemCount: Int,
        contentInsets: NSDirectionalEdgeInsets = defaultContentInsets,
        groupAbsoluteExtent: CGSize? = nil,
        containerSize: CGSize? = nil,
        targetAspect: CGFloat = CGFloat(GroupCallVideoLayoutPolicy.targetAspect),
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        #if os(iOS)
        let maxItemsPerPage = 12
        let usesPaging = itemCount > maxItemsPerPage
        let layoutItemCount = min(itemCount, maxItemsPerPage)
        #else
        let usesPaging = false
        let layoutItemCount = itemCount
        #endif

        let resolvedContainerSize = groupAbsoluteExtent ?? containerSize
        var baseInsets = conferenceContentInsets(base: contentInsets, for: layoutItemCount)
        if safeAreaTop > 0 {
            baseInsets.top += safeAreaTop
        }

        let groupSize: NSCollectionLayoutSize
        if let resolvedContainerSize {
            groupSize = NSCollectionLayoutSize(
                widthDimension: .absolute(max(1, resolvedContainerSize.width)),
                heightDimension: .absolute(max(1, resolvedContainerSize.height))
            )
        } else {
            groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            )
        }

        let group = Self.makeConferenceCustomGroup(
            groupSize: groupSize,
            resolvedContainerSize: resolvedContainerSize,
            layoutItemCount: layoutItemCount,
            insets: baseInsets,
            targetAspect: targetAspect
        )

        let section = NSCollectionLayoutSection(group: group)

        #if os(iOS)
        if usesPaging {
            section.orthogonalScrollingBehavior = .groupPaging
        }
        #endif

        return section
    }

    nonisolated private static func makeConferenceCustomGroup(
        groupSize: NSCollectionLayoutSize,
        resolvedContainerSize: CGSize?,
        layoutItemCount: Int,
        insets: NSDirectionalEdgeInsets,
        targetAspect: CGFloat
    ) -> NSCollectionLayoutGroup {
        NSCollectionLayoutGroup.custom(layoutSize: groupSize) { environment in
            let containerWidth = resolvedContainerSize?.width
                ?? environment.container.effectiveContentSize.width
            let containerHeight = resolvedContainerSize?.height
                ?? environment.container.effectiveContentSize.height
            return conferenceCustomItems(
                itemCount: layoutItemCount,
                containerSize: CGSize(width: containerWidth, height: containerHeight),
                insets: insets,
                targetAspect: targetAspect
            )
        }
    }

    nonisolated private static func conferenceCustomItems(
        itemCount: Int,
        containerSize: CGSize,
        insets: NSDirectionalEdgeInsets,
        preferVerticalStack: Bool = false,
        targetAspect: CGFloat = CGFloat(GroupCallVideoLayoutPolicy.targetAspect)
    ) -> [NSCollectionLayoutGroupCustomItem] {
        guard itemCount > 0 else { return [] }

        let availableWidth = max(
            1,
            containerSize.width - insets.leading - insets.trailing
        )

        let availableHeight = max(
            1,
            containerSize.height - insets.top - insets.bottom
        )

        let spacing: CGFloat = {
            #if os(iOS)
            return containerSize.width < 600 ? 6 : 10
            #else
            return 10
            #endif
        }()

        let grid = GroupCallVideoLayoutPolicy.conferenceGridDimensions(
            itemCount: itemCount,
            containerSize: GroupCallLayoutSize(
                width: Double(containerSize.width),
                height: Double(containerSize.height)
            ),
            preferVerticalStack: preferVerticalStack
        )

        let columns = max(1, grid.columns)
        let rows = max(1, grid.rows)

        let totalHorizontalSpacing = CGFloat(columns - 1) * spacing
        let totalVerticalSpacing = CGFloat(rows - 1) * spacing

        let maxTileWidth = (availableWidth - totalHorizontalSpacing) / CGFloat(columns)
        let maxTileHeight = (availableHeight - totalVerticalSpacing) / CGFloat(rows)

        let tile = conferenceTileSize(
            columns: columns,
            rows: rows,
            availableSize: CGSize(width: availableWidth, height: availableHeight),
            spacing: spacing,
            targetAspect: targetAspect
        )

        let tileWidth = tile.width
        let tileHeight = tile.height

        let gridWidth = CGFloat(columns) * tileWidth + totalHorizontalSpacing
        let gridHeight = CGFloat(rows) * tileHeight + totalVerticalSpacing

        let originX = insets.leading + max(0, availableWidth - gridWidth) / 2
        let originY = insets.top

        return (0..<itemCount).map { index in
            let row = index / columns
            let column = index % columns

            let itemsInThisRow = min(columns, itemCount - row * columns)

            let rowWidth =
                CGFloat(itemsInThisRow) * tileWidth +
                CGFloat(max(0, itemsInThisRow - 1)) * spacing

            let rowOriginX = originX + max(0, gridWidth - rowWidth) / 2

            let frame = CGRect(
                x: rowOriginX + CGFloat(column) * (tileWidth + spacing),
                y: originY + CGFloat(row) * (tileHeight + spacing),
                width: tileWidth,
                height: tileHeight
            )

            return NSCollectionLayoutGroupCustomItem(frame: frame)
        }
    }

    private static func bestConferenceGrid(
        itemCount: Int,
        availableSize: CGSize,
        spacing: CGFloat,
        targetAspect: CGFloat
    ) -> (columns: Int, rows: Int) {
        guard itemCount > 0 else {
            return (1, 1)
        }

        if itemCount == 1 {
            return (1, 1)
        }

        if itemCount == 2 {
            let sideBySide = conferenceTileSize(
                columns: 2,
                rows: 1,
                availableSize: availableSize,
                spacing: spacing,
                targetAspect: targetAspect
            )

            let stacked = conferenceTileSize(
                columns: 1,
                rows: 2,
                availableSize: availableSize,
                spacing: spacing,
                targetAspect: targetAspect
            )

            if sideBySide.area >= stacked.area * 0.85 {
                return (2, 1)
            } else {
                return (1, 2)
            }
        }

        var bestGrid = (columns: 1, rows: itemCount)
        var bestScore: CGFloat = -CGFloat.greatestFiniteMagnitude

        for columns in 1...itemCount {
            let rows = Int(ceil(Double(itemCount) / Double(columns)))

            let tile = conferenceTileSize(
                columns: columns,
                rows: rows,
                availableSize: availableSize,
                spacing: spacing,
                targetAspect: targetAspect
            )

            guard tile.width > 0, tile.height > 0 else {
                continue
            }

            var score = tile.area

            score += CGFloat(columns) * tile.area * 0.03

            if itemCount >= 3, columns == 1, availableSize.height > availableSize.width * 1.12 {
                score *= 0.85
            }

            if score > bestScore {
                bestScore = score
                bestGrid = (columns, rows)
            }
        }

        return bestGrid
    }

    nonisolated private static func conferenceTileSize(
        columns: Int,
        rows: Int,
        availableSize: CGSize,
        spacing: CGFloat,
        targetAspect: CGFloat
    ) -> (width: CGFloat, height: CGFloat, area: CGFloat) {
        let totalHorizontalSpacing = CGFloat(max(0, columns - 1)) * spacing
        let totalVerticalSpacing = CGFloat(max(0, rows - 1)) * spacing

        let maxTileWidth = (availableSize.width - totalHorizontalSpacing) / CGFloat(columns)
        let maxTileHeight = (availableSize.height - totalVerticalSpacing) / CGFloat(rows)

        guard maxTileWidth > 0, maxTileHeight > 0 else {
            return (0, 0, 0)
        }

        if maxTileWidth / maxTileHeight > targetAspect {
            let height = maxTileHeight
            let width = height * targetAspect
            return (width, height, width * height)
        } else {
            let width = maxTileWidth
            let height = width / targetAspect
            return (width, height, width * height)
        }
    }
    

    private struct ConferenceLayoutMetrics {
        let columns: Int
        let rows: Int
        let groupSize: CGSize
        let sectionInsets: NSDirectionalEdgeInsets
    }

    #if os(iOS)
    private func conferenceLayoutMetrics(
        for itemCount: Int,
        in containerSize: CGSize?
    ) -> ConferenceLayoutMetrics? {
        guard let containerSize,
              containerSize.width > 1,
              containerSize.height > 1 else {
            return nil
        }

        let availableWidth = max(1, containerSize.width)
        let availableHeight = max(1, containerSize.height)
        let isPortraitPhoneShape = availableHeight > availableWidth * 1.12
        let targetAspect = isPortraitPhoneShape ? CGFloat(4.0 / 3.0) : Self.defaultAspectRatio
        let maxColumns = min(itemCount, isPortraitPhoneShape ? 3 : 4)

        var best: (columns: Int, rows: Int, size: CGSize, score: CGFloat)?

        for columns in 1...maxColumns {
            let rows = Int(ceil(Double(itemCount) / Double(columns)))
            let widthBoundTileWidth = availableWidth / CGFloat(columns)
            let widthBoundTileHeight = widthBoundTileWidth / targetAspect
            var groupWidth = availableWidth
            var groupHeight = widthBoundTileHeight * CGFloat(rows)

            if groupHeight > availableHeight {
                let heightBoundTileHeight = availableHeight / CGFloat(rows)
                let heightBoundTileWidth = heightBoundTileHeight * targetAspect
                groupWidth = min(availableWidth, heightBoundTileWidth * CGFloat(columns))
                groupHeight = availableHeight
            }

            let tileWidth = groupWidth / CGFloat(columns)
            let tileHeight = groupHeight / CGFloat(rows)
            let aspectError = abs((tileWidth / max(1, tileHeight)) - targetAspect)
            let area = groupWidth * groupHeight
            let portraitStackBonus: CGFloat = isPortraitPhoneShape && columns == 1 && itemCount <= 4 ? 80_000 : 0
            let overflowPenalty: CGFloat = groupWidth > availableWidth || groupHeight > availableHeight ? 1_000_000 : 0
            let score = area + portraitStackBonus - (aspectError * 120_000) - overflowPenalty

            if best == nil || score > best!.score {
                best = (columns, rows, CGSize(width: max(1, groupWidth), height: max(1, groupHeight)), score)
            }
        }

        let fallbackGrid = conferenceGridDimensions(for: itemCount)
        let resolved = best ?? (
            columns: fallbackGrid.columns,
            rows: fallbackGrid.rows,
            size: CGSize(width: availableWidth, height: availableHeight),
            score: 0
        )
        let topInset: CGFloat = 0
        let leadingInset = max(0, (availableWidth - resolved.size.width) / 2)

        return ConferenceLayoutMetrics(
            columns: resolved.columns,
            rows: resolved.rows,
            groupSize: resolved.size,
            sectionInsets: NSDirectionalEdgeInsets(
                top: topInset,
                leading: leadingInset,
                bottom: topInset,
                trailing: leadingInset
            )
        )
    }
    #endif

    /// Produces a balanced rows x columns grid for conference tiles.
    private func conferenceGridDimensions(for itemCount: Int) -> (columns: Int, rows: Int) {
        switch itemCount {
        case 1:
            return (1, 1)
        case 2:
            return (2, 1)
        case 3...4:
            return (2, 2)
        case 5...6:
            return (3, 2)
        case 7...9:
            return (3, 3)
        case 10...12:
            return (4, 3)
        default:
            // Keep more than 12 participants visible while avoiding ultra-thin single-row tiles.
            return (4, Int(ceil(Double(itemCount) / 4.0)))
        }
    }

    /// Scales default spacing down as participant count grows.
    private func conferenceContentInsets(
        base: NSDirectionalEdgeInsets,
        for itemCount: Int
    ) -> NSDirectionalEdgeInsets {
        let scale: CGFloat
        switch itemCount {
        case ...4:
            scale = 1.0
        case 5...9:
            scale = 0.75
        default:
            scale = 0.5
        }

        return NSDirectionalEdgeInsets(
            top: base.top * scale,
            leading: base.leading * scale,
            bottom: base.bottom * scale,
            trailing: base.trailing * scale
        )
    }
    
    private func createSingleItemLayout() -> NSCollectionLayoutSection {
        return fullScreenItem()
    }

    // MARK: - Screen-share dominant layout

    /// Layout where a single screen-share tile dominates and camera thumbnails stay secondary.
    /// Screen share should feel like the presentation surface, not another equal participant tile.
    ///
    /// - Parameter cameraTileCount: Number of camera tiles in the strip (0 means screen only).
    public func screenShareDominantSection(cameraTileCount: Int) -> NSCollectionLayoutSection {
        return createScreenShareDominantLayout(cameraTileCount: cameraTileCount, groupAbsoluteExtent: nil)
    }

    /// iOS section-provider variant with the current collection view size.
    ///
    /// `cameraTileAspects` are per remote **content** (incoming upright frame), not the
    /// local collection. The share item stays a separate full-bleed top/sidebar group.
    public func screenShareDominantSection(
        cameraTileCount: Int,
        containerSize: CGSize,
        cameraTileAspects: [CGFloat] = [],
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        return createScreenShareDominantLayout(
            cameraTileCount: cameraTileCount,
            groupAbsoluteExtent: containerSize,
            cameraTileAspects: cameraTileAspects,
            safeAreaTop: safeAreaTop
        )
    }

    #if os(macOS)
    /// macOS variant with explicit group extent to avoid zero-bounds during resize.
    public func screenShareDominantSection(
        cameraTileCount: Int,
        groupAbsoluteExtent: CGSize,
        cameraTileAspects: [CGFloat] = [],
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        return createScreenShareDominantLayout(
            cameraTileCount: cameraTileCount,
            groupAbsoluteExtent: groupAbsoluteExtent,
            cameraTileAspects: cameraTileAspects,
            safeAreaTop: safeAreaTop
        )
    }
    #endif

    private func createScreenShareDominantLayout(
        cameraTileCount: Int,
        groupAbsoluteExtent: CGSize?,
        cameraTileAspects: [CGFloat] = [],
        safeAreaTop: CGFloat = 0
    ) -> NSCollectionLayoutSection {
        func outerLayoutSize(for extent: CGSize?) -> NSCollectionLayoutSize {
            if let extent {
                return NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, extent.width)),
                    heightDimension: .absolute(max(1, extent.height))
                )
            }
            return NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalHeight(1.0)
            )
        }

        guard cameraTileCount > 0 else {
            if let g = groupAbsoluteExtent {
                let s = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width)),
                    heightDimension: .absolute(max(1, g.height))
                )
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(1.0)
                ))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: s, subitems: [item])
                return NSCollectionLayoutSection(group: group)
            }
            return fullScreenItem()
        }

        let visibleCameraCount = max(1, cameraTileCount)
        let collectionSize = GroupCallLayoutSize(
            width: Double(groupAbsoluteExtent?.width ?? 0),
            height: Double(groupAbsoluteExtent?.height ?? 0)
        )
        let isWide = GroupCallVideoLayoutPolicy.isWideCollection(collectionSize)
        let resolvedAspects = (0..<visibleCameraCount).map { index -> Double in
            if index < cameraTileAspects.count, cameraTileAspects[index] > 0 {
                return Double(cameraTileAspects[index])
            }
            return GroupCallVideoLayoutPolicy.landscapeTileAspect
        }

        // Share stays a normal full-bleed item in its own group. Only the camera
        // strip uses custom frames so remote content can be 16:9 or 9:16.
        let screenItem = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .fractionalHeight(1.0)
        ))
        screenItem.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)

        func cameraStripGroup(
            stripSize: CGSize?,
            layoutSize: NSCollectionLayoutSize,
            preferVerticalStack: Bool,
            stripSafeAreaTop: CGFloat
        ) -> NSCollectionLayoutGroup {
            return NSCollectionLayoutGroup.custom(layoutSize: layoutSize) { environment in
                let width = max(
                    1,
                    stripSize?.width ?? environment.container.effectiveContentSize.width
                )
                let height = max(
                    1,
                    stripSize?.height ?? environment.container.effectiveContentSize.height
                )
                return GroupCallVideoLayoutPolicy.screenShareCameraStripFrames(
                    aspects: resolvedAspects,
                    stripSize: GroupCallLayoutSize(width: Double(width), height: Double(height)),
                    platform: .iOS,
                    preferVerticalStack: preferVerticalStack,
                    safeAreaTop: Double(stripSafeAreaTop)
                ).map { rect in
                    NSCollectionLayoutGroupCustomItem(
                        frame: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                    )
                }
            }
        }

        let outerSize = outerLayoutSize(for: groupAbsoluteExtent)
        let outerGroup: NSCollectionLayoutGroup
        if isWide {
            let screenFraction: CGFloat
            switch visibleCameraCount {
            case 1:
                screenFraction = 0.74
            default:
                screenFraction = 0.82
            }
            let screenSize: NSCollectionLayoutSize
            let cameraSize: NSCollectionLayoutSize
            let cameraStripSize: CGSize?
            if let g = groupAbsoluteExtent {
                cameraStripSize = CGSize(
                    width: max(1, g.width * (1.0 - screenFraction)),
                    height: max(1, g.height)
                )
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width * screenFraction)),
                    heightDimension: .absolute(max(1, g.height))
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(cameraStripSize!.width),
                    heightDimension: .absolute(cameraStripSize!.height)
                )
            } else {
                cameraStripSize = nil
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(screenFraction),
                    heightDimension: .fractionalHeight(1.0)
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0 - screenFraction),
                    heightDimension: .fractionalHeight(1.0)
                )
            }
            let screenGroup = NSCollectionLayoutGroup.horizontal(layoutSize: screenSize, subitems: [screenItem])
            let cameraGroup = cameraStripGroup(
                stripSize: cameraStripSize,
                layoutSize: cameraSize,
                preferVerticalStack: true,
                stripSafeAreaTop: safeAreaTop
            )
            outerGroup = NSCollectionLayoutGroup.horizontal(layoutSize: outerSize, subitems: [screenGroup, cameraGroup])
        } else {
            let columns = min(visibleCameraCount, 4)
            let rows = Int(ceil(Double(visibleCameraCount) / Double(columns)))
            let screenFraction: CGFloat
            switch visibleCameraCount {
            case 1:
                screenFraction = 0.70
            case 2...4:
                screenFraction = 0.82
            default:
                screenFraction = rows > 2 ? 0.74 : 0.78
            }
            let cameraFraction = 1.0 - screenFraction
            let screenSize: NSCollectionLayoutSize
            let cameraSize: NSCollectionLayoutSize
            let cameraStripSize: CGSize?
            if let g = groupAbsoluteExtent {
                cameraStripSize = CGSize(
                    width: max(1, g.width),
                    height: max(1, g.height * cameraFraction)
                )
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(max(1, g.width)),
                    heightDimension: .absolute(max(1, g.height * screenFraction))
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(cameraStripSize!.width),
                    heightDimension: .absolute(cameraStripSize!.height)
                )
            } else {
                cameraStripSize = nil
                screenSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(screenFraction)
                )
                cameraSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .fractionalHeight(cameraFraction)
                )
            }
            let screenGroup = NSCollectionLayoutGroup.horizontal(layoutSize: screenSize, subitems: [screenItem])
            let preferVerticalStack = cameraStripSize.map { $0.height > $0.width * 1.08 } ?? false
            let cameraGroup = cameraStripGroup(
                stripSize: cameraStripSize,
                layoutSize: cameraSize,
                preferVerticalStack: preferVerticalStack,
                stripSafeAreaTop: 0
            )
            outerGroup = NSCollectionLayoutGroup.vertical(layoutSize: outerSize, subitems: [screenGroup, cameraGroup])
        }

        return NSCollectionLayoutSection(group: outerGroup)
    }
}
#endif
