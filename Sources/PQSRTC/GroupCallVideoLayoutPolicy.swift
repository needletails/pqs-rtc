import Foundation

/// Platform-neutral size used by group-call layout policy.
public struct GroupCallLayoutSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var minSide: Double { min(width, height) }
    public var isLandscape: Bool { width > height }
}

/// Platform-neutral rectangle used by group-call layout policy.
public struct GroupCallLayoutRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func isContained(in container: GroupCallLayoutSize, epsilon: Double = 0.5) -> Bool {
        x >= -epsilon
            && y >= -epsilon
            && maxX <= container.width + epsilon
            && maxY <= container.height + epsilon
    }

    public func overlaps(_ other: GroupCallLayoutRect, epsilon: Double = 0.5) -> Bool {
        x + epsilon < other.maxX
            && maxX > other.x + epsilon
            && y + epsilon < other.maxY
            && maxY > other.y + epsilon
    }

    public func contains(_ other: GroupCallLayoutRect, epsilon: Double = 0.5) -> Bool {
        x - epsilon <= other.x
            && y - epsilon <= other.y
            && maxX + epsilon >= other.maxX
            && maxY + epsilon >= other.maxY
    }
}

public struct GroupCallLayoutInsets: Equatable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let conferenceDefault = GroupCallLayoutInsets(top: 15, leading: 15, bottom: 15, trailing: 15)
}

public enum GroupCallLayoutPlatform: String, Sendable, CaseIterable {
    case iOS
    case android
    case macOS
}

public enum GroupCallLayoutMode: String, Sendable {
    case conference
    case screenShare
}

public struct ScreenShareDominantLayout: Equatable, Sendable {
    public var screen: GroupCallLayoutRect
    public var cameras: [GroupCallLayoutRect]

    public init(screen: GroupCallLayoutRect, cameras: [GroupCallLayoutRect]) {
        self.screen = screen
        self.cameras = cameras
    }

    public var allFrames: [GroupCallLayoutRect] { [screen] + cameras }
}

public struct ScreenShareLayoutSnapshotItem: Equatable, Sendable {
    public let id: String
    public let isPreview: Bool
    public let isScreenShare: Bool

    public init(id: String, isPreview: Bool, isScreenShare: Bool) {
        self.id = id
        self.isPreview = isPreview
        self.isScreenShare = isScreenShare
    }
}

/// Pure geometry and snapshot policy for group-call camera grids, screen-share dominant
/// layouts, local preview overlays, and transition-time mounted-cell bounds.
public enum GroupCallVideoLayoutPolicy {
    public static let landscapeTileAspect = 16.0 / 9.0
    public static let portraitTileAspect = 9.0 / 16.0
    /// Conference (non-share) tiles stay landscape 16:9.
    public static let targetAspect = landscapeTileAspect

    public static func isWideCollection(_ size: GroupCallLayoutSize) -> Bool {
        size.width > max(1, size.height) * 1.08
    }

    /// Incoming upright frame decides the remote camera **item**. Unknown defaults to
    /// landscape so a landscape remote spans the strip instead of sitting in a 9:16 box.
    /// The local collection / leftover band is not used — that is what wrongly resized
    /// the share tile and trapped landscape content in a portrait cell.
    public static func cameraTileAspectForRemoteContent(
        uprightWidth: Double,
        uprightHeight: Double
    ) -> Double {
        guard uprightWidth > 0, uprightHeight > 0 else { return landscapeTileAspect }
        return uprightWidth >= uprightHeight ? landscapeTileAspect : portraitTileAspect
    }

    /// Default strip-tile aspect while a remote size is unknown: landscape (end-to-end).
    /// The collection size is ignored; callers that need a portrait item must pass
    /// ``portraitTileAspect`` or ``cameraTileAspectForRemoteContent(uprightWidth:uprightHeight:)``.
    public static func screenShareCameraTileAspect(collectionSize: GroupCallLayoutSize) -> Double {
        _ = collectionSize
        return landscapeTileAspect
    }

    public static func visibleCameraCountForPage(
        totalCameras: Int,
        platform: GroupCallLayoutPlatform,
        mode: GroupCallLayoutMode
    ) -> Int {
        let count = max(0, totalCameras)
        switch (platform, mode) {
        case (.iOS, .conference), (.android, .conference):
            return min(count, 12)
        case (.android, .screenShare):
            return min(count, 8)
        case (.iOS, .screenShare), (.macOS, _):
            return count
        }
    }

    public static func conferenceContentInsets(for itemCount: Int) -> GroupCallLayoutInsets {
        let scale: Double
        switch itemCount {
        case ...4:
            scale = 1.0
        case 5...9:
            scale = 0.75
        default:
            scale = 0.5
        }
        let base = GroupCallLayoutInsets.conferenceDefault
        return GroupCallLayoutInsets(
            top: base.top * scale,
            leading: base.leading * scale,
            bottom: base.bottom * scale,
            trailing: base.trailing * scale
        )
    }

    public static func conferenceTileSpacing(containerWidth: Double, itemCount: Int) -> Double {
        guard itemCount > 1 else { return 0 }
        return containerWidth < 600 ? 6 : 10
    }

    /// Apple collections are full-bleed so a solo remote can sit under the status
    /// bar. Conference tiles still need `safeAreaTop` added to the content inset.
    public static func applyingAppleTopSafeArea(
        _ insets: GroupCallLayoutInsets,
        platform: GroupCallLayoutPlatform,
        safeAreaTop: Double
    ) -> GroupCallLayoutInsets {
        guard platform != .android, safeAreaTop > 0 else { return insets }
        return GroupCallLayoutInsets(
            top: insets.top + safeAreaTop,
            leading: insets.leading,
            bottom: insets.bottom,
            trailing: insets.trailing
        )
    }

    public static func conferenceTileFrames(
        itemCount: Int,
        containerSize: GroupCallLayoutSize,
        platform: GroupCallLayoutPlatform,
        preferVerticalStack: Bool = false,
        preferHorizontalStrip: Bool = false,
        insets: GroupCallLayoutInsets? = nil,
        targetAspect: Double = GroupCallVideoLayoutPolicy.targetAspect,
        fillSoloTile: Bool = true,
        safeAreaTop: Double = 0
    ) -> [GroupCallLayoutRect] {
        guard itemCount > 0 else { return [] }
        switch platform {
        case .android:
            return androidConferenceTileFrames(
                itemCount: itemCount,
                containerSize: containerSize,
                preferHorizontalStrip: preferHorizontalStrip,
                preferVerticalStack: preferVerticalStack,
                targetAspect: targetAspect,
                fillSoloTile: fillSoloTile
            )
        case .iOS, .macOS:
            let resolvedInsets = applyingAppleTopSafeArea(
                insets ?? conferenceContentInsets(for: itemCount),
                platform: platform,
                safeAreaTop: safeAreaTop
            )
            return appleConferenceTileFrames(
                itemCount: itemCount,
                containerSize: containerSize,
                insets: resolvedInsets,
                preferVerticalStack: preferVerticalStack,
                preferHorizontalStrip: preferHorizontalStrip,
                targetAspect: targetAspect
            )
        }
    }

    /// Portrait stacks 2...4 participants in one column; landscape uses one row.
    /// Larger rosters keep the shared conference grid. Screen-share leftover bands
    /// pass `preferHorizontalStrip` so cameras stay on the strip, not this grid.
    public static func conferenceGridDimensions(
        itemCount: Int,
        containerSize: GroupCallLayoutSize,
        preferVerticalStack: Bool = false,
        preferHorizontalStrip: Bool = false
    ) -> (columns: Int, rows: Int) {
        guard itemCount > 0 else { return (1, 1) }
        if preferVerticalStack {
            return (1, itemCount)
        }
        if preferHorizontalStrip {
            return (itemCount, 1)
        }
        let isPortrait = containerSize.height >= containerSize.width
        return androidConferenceGridDimensions(itemCount: itemCount, isPortrait: isPortrait)
    }

    public static func screenShareDominantFrames(
        cameraTileCount: Int,
        containerSize: GroupCallLayoutSize,
        platform: GroupCallLayoutPlatform,
        cameraTileAspect: Double? = nil,
        cameraTileAspects: [Double]? = nil,
        safeAreaTop: Double = 0
    ) -> ScreenShareDominantLayout {
        let visibleCameras = visibleCameraCountForPage(
            totalCameras: cameraTileCount,
            platform: platform,
            mode: .screenShare
        )
        let containerRect = GroupCallLayoutRect(
            x: 0,
            y: 0,
            width: containerSize.width,
            height: containerSize.height
        )
        guard visibleCameras > 0 else {
            return ScreenShareDominantLayout(screen: containerRect, cameras: [])
        }

        let aspects = resolvedCameraTileAspects(
            count: visibleCameras,
            cameraTileAspect: cameraTileAspect,
            cameraTileAspects: cameraTileAspects
        )
        let isWide = isWideCollection(containerSize)
        if isWide {
            let screenFraction: Double
            switch visibleCameras {
            case 1:
                screenFraction = 0.74
            default:
                screenFraction = 0.82
            }
            let screenWidth = max(1, containerSize.width * screenFraction)
            let cameraWidth = max(1, containerSize.width - screenWidth)
            let screen = GroupCallLayoutRect(
                x: 0,
                y: 0,
                width: screenWidth,
                height: containerSize.height
            )
            let cameras = screenShareCameraStripFrames(
                aspects: aspects,
                stripSize: GroupCallLayoutSize(width: cameraWidth, height: containerSize.height),
                platform: platform,
                preferVerticalStack: true,
                safeAreaTop: platform == .android ? 0 : safeAreaTop
            ).map { frame in
                GroupCallLayoutRect(
                    x: screenWidth + frame.x,
                    y: frame.y,
                    width: frame.width,
                    height: frame.height
                )
            }
            return ScreenShareDominantLayout(screen: screen, cameras: cameras)
        }

        let columns = min(visibleCameras, 4)
        let rows = Int(ceil(Double(visibleCameras) / Double(columns)))
        let screenFraction: Double
        switch visibleCameras {
        case 1:
            screenFraction = 0.70
        case 2...4:
            screenFraction = 0.82
        default:
            screenFraction = rows > 2 ? 0.74 : 0.78
        }
        let screenHeight = max(1, containerSize.height * screenFraction)
        let cameraHeight = max(1, containerSize.height - screenHeight)
        let screen = GroupCallLayoutRect(
            x: 0,
            y: 0,
            width: containerSize.width,
            height: screenHeight
        )
        let stripSize = GroupCallLayoutSize(width: containerSize.width, height: cameraHeight)
        let preferVerticalStack = cameraHeight > containerSize.width * 1.08
        let cameras = screenShareCameraStripFrames(
            aspects: aspects,
            stripSize: stripSize,
            platform: platform,
            preferVerticalStack: preferVerticalStack,
            safeAreaTop: 0
        ).map { frame in
            GroupCallLayoutRect(
                x: frame.x,
                y: screenHeight + frame.y,
                width: frame.width,
                height: frame.height
            )
        }
        return ScreenShareDominantLayout(screen: screen, cameras: cameras)
    }

    /// Camera items inside the leftover share strip, in strip-local coordinates.
    /// The share tile is not part of this result — iOS keeps that in a separate full-bleed group.
    public static func screenShareCameraStripFrames(
        aspects: [Double],
        stripSize: GroupCallLayoutSize,
        platform: GroupCallLayoutPlatform,
        preferVerticalStack: Bool,
        safeAreaTop: Double = 0
    ) -> [GroupCallLayoutRect] {
        let count = aspects.count
        guard count > 0 else { return [] }
        let insets = applyingAppleTopSafeArea(
            conferenceContentInsets(for: count),
            platform: platform,
            safeAreaTop: safeAreaTop
        )
        let first = aspects[0]
        let allMatch = aspects.allSatisfy { abs($0 - first) < 0.01 }
        if allMatch {
            let isPhoneShape = min(stripSize.width, stripSize.height) < 600
            let useHorizontalStrip = !preferVerticalStack
                && isPhoneShape
                && count <= 4
                && stripSize.width > stripSize.height
            return conferenceTileFrames(
                itemCount: count,
                containerSize: stripSize,
                platform: platform,
                preferVerticalStack: preferVerticalStack,
                preferHorizontalStrip: useHorizontalStrip,
                insets: insets,
                targetAspect: first,
                fillSoloTile: false
            )
        }

        let available = GroupCallLayoutSize(
            width: max(1, stripSize.width - insets.leading - insets.trailing),
            height: max(1, stripSize.height - insets.top - insets.bottom)
        )
        let spacing = conferenceTileSpacing(containerWidth: stripSize.width, itemCount: count)
        var tiles = aspects.map { fitAspect(targetAspect: $0, in: available) }
        if preferVerticalStack {
            let totalHeight = tiles.reduce(0.0) { $0 + $1.height } + Double(max(0, count - 1)) * spacing
            let scale = totalHeight > available.height ? available.height / totalHeight : 1
            tiles = tiles.map {
                GroupCallLayoutSize(width: $0.width * scale, height: $0.height * scale)
            }
            var y = insets.top
            return tiles.map { tile in
                let frame = GroupCallLayoutRect(
                    x: insets.leading + max(0, available.width - tile.width) / 2,
                    y: y,
                    width: tile.width,
                    height: tile.height
                )
                y += tile.height + spacing
                return frame
            }
        }

        let totalWidth = tiles.reduce(0.0) { $0 + $1.width } + Double(max(0, count - 1)) * spacing
        let scale = totalWidth > available.width ? available.width / totalWidth : 1
        tiles = tiles.map {
            GroupCallLayoutSize(width: $0.width * scale, height: $0.height * scale)
        }
        let usedWidth = tiles.reduce(0.0) { $0 + $1.width } + Double(max(0, count - 1)) * spacing
        var x = insets.leading + max(0, available.width - usedWidth) / 2
        return tiles.map { tile in
            let frame = GroupCallLayoutRect(
                x: x,
                y: insets.top,
                width: tile.width,
                height: tile.height
            )
            x += tile.width + spacing
            return frame
        }
    }

    private static func resolvedCameraTileAspects(
        count: Int,
        cameraTileAspect: Double?,
        cameraTileAspects: [Double]?
    ) -> [Double] {
        if let cameraTileAspects, cameraTileAspects.count == count {
            return cameraTileAspects
        }
        if let cameraTileAspect {
            return Array(repeating: cameraTileAspect, count: count)
        }
        if let cameraTileAspects, !cameraTileAspects.isEmpty {
            return (0..<count).map { index in
                index < cameraTileAspects.count ? cameraTileAspects[index] : landscapeTileAspect
            }
        }
        return Array(repeating: landscapeTileAspect, count: count)
    }

    public static func usesHorizontalPhoneCameraStrip(
        cameraTileCount: Int,
        containerSize: GroupCallLayoutSize
    ) -> Bool {
        let isPhoneShape = min(containerSize.width, containerSize.height) < 600
        return !isWideCollection(containerSize) && isPhoneShape && cameraTileCount >= 1 && cameraTileCount <= 4
    }

    public static func localPreviewOverlaySize(
        platform: GroupCallLayoutPlatform,
        containerSize: GroupCallLayoutSize,
        isTablet: Bool = false,
        isMinimized: Bool = false
    ) -> GroupCallLayoutSize {
        switch platform {
        case .android:
            let minSide = containerSize.minSide
            let tablet = isTablet || minSide >= 450
            let maxOverlayWidth: Double
            let widthFraction: Double
            if isMinimized {
                maxOverlayWidth = tablet ? 150 : 108
                widthFraction = tablet ? 0.18 : 0.22
            } else {
                maxOverlayWidth = tablet ? 240 : 180
                widthFraction = tablet ? 0.28 : 0.34
            }
            let overlayWidth = min(maxOverlayWidth, minSide * widthFraction)
            let overlayHeight = containerSize.isLandscape
                ? overlayWidth * (9.0 / 16.0)
                : overlayWidth * (16.0 / 9.0)
            return GroupCallLayoutSize(width: overlayWidth, height: overlayHeight)
        case .iOS:
            let width = containerSize.width
            let height = containerSize.height
            let aspect = max(width, height) / max(1, min(width, height))
            let landscape = width > height
            let uncapped: GroupCallLayoutSize
            if landscape {
                let overlayWidth = isTablet
                    ? (isMinimized ? width / 3 : width / 4)
                    : (isMinimized ? width / 4 : width / 3)
                uncapped = GroupCallLayoutSize(width: overlayWidth, height: overlayWidth / aspect)
            } else if isTablet {
                let overlayWidth = isMinimized ? height / 3 : height / 4
                uncapped = GroupCallLayoutSize(width: overlayWidth, height: overlayWidth * aspect)
            } else {
                let overlayWidth = isMinimized ? width / 6.5 : height / 4.5
                let overlayHeight = isMinimized
                    ? (width / 6.5) * aspect
                    : (height / 5.5) * aspect
                uncapped = GroupCallLayoutSize(width: overlayWidth, height: overlayHeight)
            }
            return constrainedLocalPreviewSize(uncapped, in: containerSize)
        case .macOS:
            if isMinimized {
                return GroupCallLayoutSize(width: 112, height: 63)
            }
            return GroupCallLayoutSize(width: 160, height: 90)
        }
    }

    /// An explicit interface box (rotation target, Split View column) is trusted.
    /// Only a stale fallback (typically `UIScreen.bounds`) is flipped to match
    /// the requested orientation.
    public static func resolvedLocalPreviewHostSize(
        explicitContainer: GroupCallLayoutSize?,
        fallbackContainer: GroupCallLayoutSize,
        requestedIsLandscape: Bool
    ) -> GroupCallLayoutSize {
        if let explicitContainer, explicitContainer.width > 1, explicitContainer.height > 1 {
            return explicitContainer
        }
        let raw = fallbackContainer
        if requestedIsLandscape && raw.width <= raw.height {
            return GroupCallLayoutSize(
                width: max(raw.width, raw.height),
                height: min(raw.width, raw.height)
            )
        }
        if !requestedIsLandscape && raw.width >= raw.height {
            return GroupCallLayoutSize(
                width: min(raw.width, raw.height),
                height: max(raw.width, raw.height)
            )
        }
        return raw
    }

    /// Keeps the PiP from swallowing a compact iPad column after the overlay
    /// is sized from the live container instead of `UIScreen.bounds`.
    public static func constrainedLocalPreviewSize(
        _ size: GroupCallLayoutSize,
        in container: GroupCallLayoutSize
    ) -> GroupCallLayoutSize {
        let maxWidth = max(1, container.width * 0.48)
        let maxHeight = max(1, container.height * 0.40)
        let scale = min(
            1,
            maxWidth / max(1, size.width),
            maxHeight / max(1, size.height)
        )
        return GroupCallLayoutSize(width: size.width * scale, height: size.height * scale)
    }

    public static func localPreviewOverlayFrame(
        platform: GroupCallLayoutPlatform,
        containerSize: GroupCallLayoutSize,
        isTablet: Bool = false,
        isMinimized: Bool = false,
        trailingPadding: Double = 20,
        bottomPadding: Double = 20
    ) -> GroupCallLayoutRect {
        let size = localPreviewOverlaySize(
            platform: platform,
            containerSize: containerSize,
            isTablet: isTablet,
            isMinimized: isMinimized
        )
        return GroupCallLayoutRect(
            x: max(0, containerSize.width - size.width - trailingPadding),
            y: max(0, containerSize.height - size.height - bottomPadding),
            width: size.width,
            height: size.height
        )
    }

    public static func snapshotModelsForScreenShareLayout(
        models: [ScreenShareLayoutSnapshotItem],
        previewDetached: Bool
    ) -> [ScreenShareLayoutSnapshotItem] {
        var data = models
        if previewDetached {
            data.removeAll { $0.isPreview }
        }
        data.sort { lhs, rhs in
            if lhs.isScreenShare != rhs.isScreenShare {
                return lhs.isScreenShare && !rhs.isScreenShare
            }
            return lhs.id < rhs.id
        }
        return data
    }

    /// Current on-screen cell bounds win over `view.bounds`.
    ///
    /// After screen-share start the camera `NTMTKView` often still reports the previous
    /// portrait/fullscreen rect. Metal then rasterizes to that stale destination and the
    /// present path stretches the texture into the 16:9 strip cell (looks like aspect-fill).
    /// `transitionPending` is kept for call-site compatibility; it does not change the result
    /// when a usable cell is available.
    public static func effectiveMountedVideoBounds(
        viewBounds: GroupCallLayoutRect,
        cellContentBounds: GroupCallLayoutRect,
        layoutAttributesBounds: GroupCallLayoutRect,
        transitionPending: Bool
    ) -> GroupCallLayoutRect {
        func isUsable(_ rect: GroupCallLayoutRect) -> Bool {
            rect.width > 1 && rect.height > 1
        }
        _ = transitionPending
        if isUsable(cellContentBounds) {
            return cellContentBounds
        }
        if isUsable(layoutAttributesBounds) {
            return layoutAttributesBounds
        }
        return viewBounds
    }

    // MARK: - Apple conference math (lifted from CollectionViewSections.conferenceCustomItems)

    private static func appleConferenceTileFrames(
        itemCount: Int,
        containerSize: GroupCallLayoutSize,
        insets: GroupCallLayoutInsets,
        preferVerticalStack: Bool,
        preferHorizontalStrip: Bool = false,
        targetAspect: Double
    ) -> [GroupCallLayoutRect] {
        let availableWidth = max(1, containerSize.width - insets.leading - insets.trailing)
        let availableHeight = max(1, containerSize.height - insets.top - insets.bottom)
        let spacing = conferenceTileSpacing(containerWidth: containerSize.width, itemCount: itemCount)
        let grid = conferenceGridDimensions(
            itemCount: itemCount,
            containerSize: containerSize,
            preferVerticalStack: preferVerticalStack,
            preferHorizontalStrip: preferHorizontalStrip
        )

        let columns = max(1, grid.columns)
        let rows = max(1, grid.rows)
        let totalHorizontalSpacing = Double(columns - 1) * spacing
        let tile = conferenceTileSize(
            columns: columns,
            rows: rows,
            availableSize: GroupCallLayoutSize(width: availableWidth, height: availableHeight),
            spacing: spacing,
            targetAspect: targetAspect
        )
        let tileWidth = tile.width
        let tileHeight = tile.height
        let gridWidth = Double(columns) * tileWidth + totalHorizontalSpacing
        let originX = insets.leading + max(0, availableWidth - gridWidth) / 2
        let originY = insets.top

        return (0..<itemCount).map { index in
            let row = index / columns
            let column = index % columns
            let itemsInThisRow = min(columns, itemCount - row * columns)
            let rowWidth = Double(itemsInThisRow) * tileWidth + Double(max(0, itemsInThisRow - 1)) * spacing
            let rowOriginX = originX + max(0, gridWidth - rowWidth) / 2
            return GroupCallLayoutRect(
                x: rowOriginX + Double(column) * (tileWidth + spacing),
                y: originY + Double(row) * (tileHeight + spacing),
                width: tileWidth,
                height: tileHeight
            )
        }
    }

    private static func bestConferenceGrid(
        itemCount: Int,
        availableSize: GroupCallLayoutSize,
        spacing: Double,
        targetAspect: Double
    ) -> (columns: Int, rows: Int) {
        guard itemCount > 0 else { return (1, 1) }
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
            }
            return (1, 2)
        }

        var bestGrid = (columns: 1, rows: itemCount)
        var bestScore = -Double.greatestFiniteMagnitude
        for columns in 1...itemCount {
            let rows = Int(ceil(Double(itemCount) / Double(columns)))
            let tile = conferenceTileSize(
                columns: columns,
                rows: rows,
                availableSize: availableSize,
                spacing: spacing,
                targetAspect: targetAspect
            )
            guard tile.width > 0, tile.height > 0 else { continue }
            var score = tile.area
            score += Double(columns) * tile.area * 0.03
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

    private static func conferenceTileSize(
        columns: Int,
        rows: Int,
        availableSize: GroupCallLayoutSize,
        spacing: Double,
        targetAspect: Double
    ) -> (width: Double, height: Double, area: Double) {
        let totalHorizontalSpacing = Double(max(0, columns - 1)) * spacing
        let totalVerticalSpacing = Double(max(0, rows - 1)) * spacing
        let maxTileWidth = (availableSize.width - totalHorizontalSpacing) / Double(columns)
        let maxTileHeight = (availableSize.height - totalVerticalSpacing) / Double(rows)
        guard maxTileWidth > 0, maxTileHeight > 0 else {
            return (0, 0, 0)
        }
        if maxTileWidth / maxTileHeight > targetAspect {
            let height = maxTileHeight
            let width = height * targetAspect
            return (width, height, width * height)
        }
        let width = maxTileWidth
        let height = width / targetAspect
        return (width, height, width * height)
    }

    // MARK: - Android conference math (lifted from AndroidRemoteGrid.conferenceGridDimensions)

    public static func androidConferenceGridDimensions(
        itemCount: Int,
        isPortrait: Bool
    ) -> (columns: Int, rows: Int) {
        let count = max(0, itemCount)
        switch count {
        case 0, 1:
            return (1, 1)
        case 2...4:
            return isPortrait ? (1, count) : (count, 1)
        case 5...6:
            return (3, 2)
        case 7...9:
            return (3, 3)
        default:
            let columns = 4
            return (columns, Int(ceil(Double(count) / Double(columns))))
        }
    }

    private static func androidConferenceTileFrames(
        itemCount: Int,
        containerSize: GroupCallLayoutSize,
        preferHorizontalStrip: Bool,
        preferVerticalStack: Bool,
        targetAspect: Double,
        fillSoloTile: Bool
    ) -> [GroupCallLayoutRect] {
        if itemCount == 1 {
            if fillSoloTile {
                return [
                    GroupCallLayoutRect(
                        x: 0,
                        y: 0,
                        width: containerSize.width,
                        height: containerSize.height
                    )
                ]
            }
            let insets = conferenceContentInsets(for: 1)
            let available = GroupCallLayoutSize(
                width: max(1, containerSize.width - insets.leading - insets.trailing),
                height: max(1, containerSize.height - insets.top - insets.bottom)
            )
            let tile = fitAspect(targetAspect: targetAspect, in: available)
            return [
                GroupCallLayoutRect(
                    x: insets.leading + max(0, available.width - tile.width) / 2,
                    y: insets.top,
                    width: tile.width,
                    height: tile.height
                )
            ]
        }
        let padding: Double
        if preferHorizontalStrip {
            padding = conferenceContentInsets(for: itemCount).leading
        } else {
            padding = conferenceContentInsets(for: itemCount).leading
        }
        let spacing = conferenceTileSpacing(containerWidth: containerSize.width, itemCount: itemCount)
        if preferHorizontalStrip {
            let availableWidth = max(1, containerSize.width - padding * 2)
            let availableHeight = max(1, containerSize.height - padding * 2)
            let totalSpacing = Double(max(0, itemCount - 1)) * spacing
            let maxTileWidth = (availableWidth - totalSpacing) / Double(itemCount)
            let tile = fitAspect(
                targetAspect: targetAspect,
                in: GroupCallLayoutSize(width: maxTileWidth, height: availableHeight)
            )
            let rowWidth = Double(itemCount) * tile.width + totalSpacing
            let originX = padding + max(0, availableWidth - rowWidth) / 2
            let originY = padding
            return (0..<itemCount).map { index in
                GroupCallLayoutRect(
                    x: originX + Double(index) * (tile.width + spacing),
                    y: originY,
                    width: tile.width,
                    height: tile.height
                )
            }
        }

        let isPortrait = containerSize.height >= containerSize.width
        let grid: (columns: Int, rows: Int)
        if preferVerticalStack {
            grid = (columns: 1, rows: itemCount)
        } else {
            grid = androidConferenceGridDimensions(itemCount: itemCount, isPortrait: isPortrait)
        }
        let columns = max(1, grid.columns)
        let rows = max(1, grid.rows)
        let availableWidth = max(1, containerSize.width - padding * 2)
        let availableHeight = max(1, containerSize.height - padding * 2)
        let totalHorizontalSpacing = Double(columns - 1) * spacing
        let tile = conferenceTileSize(
            columns: columns,
            rows: rows,
            availableSize: GroupCallLayoutSize(width: availableWidth, height: availableHeight),
            spacing: spacing,
            targetAspect: targetAspect
        )
        let tileWidth = tile.width
        let tileHeight = tile.height
        let gridWidth = Double(columns) * tileWidth + totalHorizontalSpacing
        let originX = padding + max(0, availableWidth - gridWidth) / 2
        let originY = padding
        return (0..<itemCount).map { index in
            let row = index / columns
            let column = index % columns
            let itemsInThisRow = min(columns, itemCount - row * columns)
            let rowWidth = Double(itemsInThisRow) * tileWidth + Double(max(0, itemsInThisRow - 1)) * spacing
            let rowOriginX = originX + max(0, gridWidth - rowWidth) / 2
            return GroupCallLayoutRect(
                x: rowOriginX + Double(column) * (tileWidth + spacing),
                y: originY + Double(row) * (tileHeight + spacing),
                width: tileWidth,
                height: tileHeight
            )
        }
    }

    private static func fitAspect(
        targetAspect: Double,
        in cell: GroupCallLayoutSize
    ) -> GroupCallLayoutSize {
        guard cell.width > 0, cell.height > 0 else {
            return GroupCallLayoutSize(width: 0, height: 0)
        }
        if cell.width / cell.height > targetAspect {
            let height = cell.height
            return GroupCallLayoutSize(width: height * targetAspect, height: height)
        }
        let width = cell.width
        return GroupCallLayoutSize(width: width, height: width / targetAspect)
    }
}
