//
//  iOSScreenCaptureSource.swift
//  pqs-rtc
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
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import NeedleTailLogger
import WebRTC

/// Receives full-device ReplayKit Broadcast Upload frames from the app extension and
/// pushes them into a WebRTC `RTCVideoSource`.
final class iOSScreenCaptureSource: @unchecked Sendable {

    private let logger = NeedleTailLogger("[iOSScreenCaptureSource]")
    private static let appGroupIdentifier = "group.com.needletails.NudgeCommunications"
    private static let portFileName = "rp-port"
    private static let optionsFileName = "rp-options.json"

    private weak var videoSource: RTCVideoSource?
    private let capturer = RTCVideoCapturer()
    private let relayQueue = DispatchQueue(label: "com.needletails.pqsrtc.replaykit.broadcast-receiver", qos: .userInteractive)
    private let stateLock = NSLock()
    private var listenerSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var isRunning = false
    private var loggedUnsupportedAudioPacket = false
    private let onBroadcastFinished: (@Sendable () -> Void)?

    init(onBroadcastFinished: (@Sendable () -> Void)? = nil) {
        self.onBroadcastFinished = onBroadcastFinished
    }

    /// Starts the app-side receiver. The host app should launch `RPSystemBroadcastPickerView`
    /// after this returns so the extension can connect to the published port.
    func startCapture(videoSource: RTCVideoSource) async throws {
        try await startCapture(options: ScreenShareOptions(), videoSource: videoSource)
    }

    /// Starts the app-side receiver with the selected broadcast options.
    func startCapture(options: ScreenShareOptions, videoSource: RTCVideoSource) async throws {
        if currentIsRunning {
            await stopCapture()
        }
        self.videoSource = videoSource

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw RTCErrors.mediaError("ReplayKit app group container unavailable for \(Self.appGroupIdentifier)")
        }

        removeRelayFiles(containerURL: containerURL)

        let listener = try createListenerSocket()
        let port = try boundPort(for: listener)

        do {
            try writeRelayOptions(options, containerURL: containerURL)
            try "\(port)".write(
                to: containerURL.appendingPathComponent(Self.portFileName),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            closeSocket(listener)
            throw RTCErrors.mediaError("Failed to publish ReplayKit relay port/options: \(error.localizedDescription)")
        }

        markRelayRunning(listener: listener)

        relayQueue.async { [weak self] in
            self?.acceptLoop(listener: listener)
        }

        logger.log(level: .info, message: "iOS ReplayKit broadcast relay receiver started port=\(port) optimizeForVideo=\(options.optimizeForVideo) shareSystemAudio=\(options.shareSystemAudio)")
    }

    /// Stops the receiver and removes app-group discovery files.
    func stopCapture() async {
        closeRelaySockets()
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            removeRelayFiles(containerURL: containerURL)
        }
        self.videoSource = nil
        logger.log(level: .info, message: "iOS ReplayKit broadcast relay receiver stopped")
    }

    private var currentIsRunning: Bool {
        stateLock.withLock {
            isRunning
        }
    }

    private func markRelayRunning(listener: Int32) {
        stateLock.withLock {
            listenerSocket = listener
            clientSocket = -1
            isRunning = true
            loggedUnsupportedAudioPacket = false
        }
    }

    private func createListenerSocket() throws -> Int32 {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listener >= 0 else {
            throw RTCErrors.mediaError("Failed to create ReplayKit relay listener socket")
        }

        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listener, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            closeSocket(listener)
            throw RTCErrors.mediaError("Failed to bind ReplayKit relay listener")
        }

        guard Darwin.listen(listener, 1) == 0 else {
            closeSocket(listener)
            throw RTCErrors.mediaError("Failed to listen for ReplayKit relay connection")
        }
        return listener
    }

    private func boundPort(for listener: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.getsockname(listener, socketPointer, &length)
            }
        }
        guard result == 0 else {
            throw RTCErrors.mediaError("Failed to read ReplayKit relay listener port")
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func writeRelayOptions(_ options: ScreenShareOptions, containerURL: URL) throws {
        let raw: [String: Any] = [
            "shareSystemAudio": options.shareSystemAudio && RTCSession.supportsScreenShareSystemAudioEgress,
            "optimizeForVideo": options.optimizeForVideo
        ]
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try data.write(to: containerURL.appendingPathComponent(Self.optionsFileName), options: .atomic)
    }

    private func acceptLoop(listener: Int32) {
        while relayIsRunning(listener: listener) {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else {
                if relayIsRunning(listener: listener) {
                    logger.log(level: .warning, message: "ReplayKit relay accept failed")
                }
                break
            }

            stateLock.withLock {
                clientSocket = client
            }

            logger.log(level: .info, message: "ReplayKit broadcast extension connected")
            readLoop(client: client)
            clearClientSocket(client)
        }
    }

    private func readLoop(client: Int32) {
        while relayIsRunning(client: client) {
            guard let header = readExactly(from: client, byteCount: ReplayKitBroadcastRelayPacket.headerLength) else {
                break
            }
            guard let payloadLength = ReplayKitBroadcastRelayPacket.payloadLength(inHeader: header) else {
                logger.log(level: .warning, message: "ReplayKit relay received invalid packet header")
                break
            }
            guard let payload = readExactly(from: client, byteCount: Int(payloadLength)) else {
                break
            }

            var packetData = header
            packetData.append(payload)
            do {
                let packet = try ReplayKitBroadcastRelayPacket.parse(packetData)
                if !handle(packet: packet) {
                    break
                }
            } catch {
                logger.log(level: .warning, message: "ReplayKit relay packet parse failed: \(error)")
                break
            }
        }
    }

    private func handle(packet: ReplayKitBroadcastRelayPacket) -> Bool {
        switch packet.type {
        case .started:
            logger.log(level: .info, message: "ReplayKit broadcast started")
        case .videoFrame:
            handleVideoPacket(packet)
        case .paused:
            logger.log(level: .info, message: "ReplayKit broadcast paused")
        case .resumed:
            logger.log(level: .info, message: "ReplayKit broadcast resumed")
        case .finished:
            logger.log(level: .info, message: "ReplayKit broadcast finished")
            onBroadcastFinished?()
            return false
        case .audioApp, .audioMic:
            if !loggedUnsupportedAudioPacket {
                loggedUnsupportedAudioPacket = true
                logger.log(level: .warning, message: "ReplayKit audio packets received, but screen-share audio egress is not supported by this WebRTC build")
            }
        }
        return true
    }

    private func handleVideoPacket(_ packet: ReplayKitBroadcastRelayPacket) {
        guard let videoSource else { return }
        guard let pixelBuffer = pixelBuffer(fromJPEG: packet.payload, width: Int(packet.width), height: Int(packet.height)) else {
            logger.log(level: .warning, message: "ReplayKit relay failed to decode video packet")
            return
        }
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcPixelBuffer, rotation: ._0, timeStampNs: packet.timestampNs)
        videoSource.capturer(capturer, didCapture: frame)
    }

    private func pixelBuffer(fromJPEG data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        let outputWidth = max(2, width > 0 ? width : image.width)
        let outputHeight = max(2, height > 0 ? height : image.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return pixelBuffer
    }

    private func readExactly(from socket: Int32, byteCount: Int) -> Data? {
        guard byteCount >= 0 else { return nil }
        if byteCount == 0 { return Data() }

        var data = Data(count: byteCount)
        var total = 0
        while total < byteCount {
            let readCount = data.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.recv(socket, baseAddress.advanced(by: total), byteCount - total, 0)
            }
            guard readCount > 0 else { return nil }
            total += readCount
        }
        return data
    }

    private func relayIsRunning(listener: Int32) -> Bool {
        stateLock.withLock {
            isRunning && listenerSocket == listener
        }
    }

    private func relayIsRunning(client: Int32) -> Bool {
        stateLock.withLock {
            isRunning && clientSocket == client
        }
    }

    private func clearClientSocket(_ client: Int32) {
        let shouldClose = stateLock.withLock {
            if clientSocket == client {
                clientSocket = -1
                return true
            }
            return false
        }
        if shouldClose {
            closeSocket(client)
        }
    }

    private func closeRelaySockets() {
        let (listener, client) = stateLock.withLock {
            let listener = listenerSocket
            let client = clientSocket
            listenerSocket = -1
            clientSocket = -1
            isRunning = false
            return (listener, client)
        }

        closeSocket(client)
        closeSocket(listener)
    }

    private func closeSocket(_ socket: Int32) {
        guard socket >= 0 else { return }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func removeRelayFiles(containerURL: URL) {
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(Self.portFileName))
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(Self.optionsFileName))
    }
}
#endif
