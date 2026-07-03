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
import CoreImage
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
    private static let stopFileName = "rp-stop"

    private weak var videoSource: RTCVideoSource?
    private let capturer = RTCVideoCapturer()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let relayQueue = DispatchQueue(label: "com.needletails.pqsrtc.replaykit.broadcast-receiver", qos: .userInteractive)
    private let stateLock = NSLock()
    private var listenerSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var isRunning = false
    private var loggedAudioConversionFailure = false
    private var loggedFirstAppAudioFrame = false
    private var loggedFirstNonSilentAppAudioFrame = false
    private var silentAppAudioFrameCount = 0
    private var systemAudioActive = false
    private let onBroadcastFinished: (@Sendable () -> Void)?
    private let onBroadcastStarted: (@Sendable () -> Void)?
    private let systemAudioEgress: ScreenShareSystemAudioEgress

    init(
        systemAudioEgress: ScreenShareSystemAudioEgress = NoOpScreenShareSystemAudioEgress(),
        onBroadcastFinished: (@Sendable () -> Void)? = nil,
        onBroadcastStarted: (@Sendable () -> Void)? = nil
    ) {
        self.systemAudioEgress = systemAudioEgress
        self.onBroadcastFinished = onBroadcastFinished
        self.onBroadcastStarted = onBroadcastStarted
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

        removeRelayFiles(containerURL: containerURL, includingStopRequest: true)

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

        if options.shareSystemAudio && RTCSession.supportsScreenShareSystemAudioEgress {
            stateLock.withLock { systemAudioActive = true }
            systemAudioEgress.activate()
        }

        relayQueue.async { [weak self] in
            self?.acceptLoop(listener: listener)
        }

        logger.log(level: .info, message: "iOS ReplayKit broadcast relay receiver started port=\(port) optimizeForVideo=\(options.optimizeForVideo) shareSystemAudio=\(options.shareSystemAudio)")
    }

    /// Stops the receiver and removes app-group discovery files.
    func stopCapture() async {
        deactivateSystemAudioIfNeeded()
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            publishBroadcastStopRequest(containerURL: containerURL)
            removeRelayFiles(containerURL: containerURL, includingStopRequest: false)
        }
        closeRelaySockets()
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
            loggedAudioConversionFailure = false
            loggedFirstAppAudioFrame = false
            loggedFirstNonSilentAppAudioFrame = false
            silentAppAudioFrameCount = 0
        }
    }

    private func deactivateSystemAudioIfNeeded() {
        let wasActive = stateLock.withLock {
            let active = systemAudioActive
            systemAudioActive = false
            loggedFirstNonSilentAppAudioFrame = false
            silentAppAudioFrameCount = 0
            return active
        }
        if wasActive {
            systemAudioEgress.deactivate()
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
            guard payloadLength <= ReplayKitBroadcastRelayPacket.maxPayloadLength else {
                logger.log(level: .warning, message: "ReplayKit relay packet too large: \(payloadLength) bytes")
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
            onBroadcastStarted?()
        case .videoFrame:
            handleVideoPacket(packet)
        case .paused:
            logger.log(level: .info, message: "ReplayKit broadcast paused")
        case .resumed:
            logger.log(level: .info, message: "ReplayKit broadcast resumed")
        case .finished:
            logger.log(level: .info, message: "ReplayKit broadcast finished")
            deactivateSystemAudioIfNeeded()
            onBroadcastFinished?()
            return false
        case .audioApp:
            handleAppAudioPacket(packet)
        case .audioMic:
            // Mic audio already flows on the main audio track; mixing it again
            // would double the voice path.
            break
        }
        return true
    }

    private func handleAppAudioPacket(_ packet: ReplayKitBroadcastRelayPacket) {
        let isActive = stateLock.withLock { systemAudioActive }
        guard isActive else { return }
        do {
            // Relay packets carry sampleRate/channelCount in width/height.
            let frame = try ScreenSharePCMSampleConverter.pcmFrame(
                fromReplayKitPayload: packet.payload,
                sampleRate: Int(packet.width),
                channelCount: Int(packet.height)
            )
            let shouldLogFirstFrame = stateLock.withLock {
                if loggedFirstAppAudioFrame { return false }
                loggedFirstAppAudioFrame = true
                return true
            }
            if shouldLogFirstFrame {
                logger.log(
                    level: .info,
                    message: "First ReplayKit app-audio frame pushed sampleRate=\(frame.sampleRate) channels=\(frame.channelCount) samples=\(frame.samples.count) peak=\(frame.peakMagnitude) rms=\(frame.rmsMagnitude)"
                )
            }
            let nonSilentLog = stateLock.withLock { () -> (shouldLog: Bool, silentFramesBefore: Int, silenceWarningFrameCount: Int?) in
                if frame.containsMeaningfulAudio {
                    if loggedFirstNonSilentAppAudioFrame {
                        return (false, silentAppAudioFrameCount, nil)
                    }
                    loggedFirstNonSilentAppAudioFrame = true
                    return (true, silentAppAudioFrameCount, nil)
                }

                guard !loggedFirstNonSilentAppAudioFrame else {
                    return (false, silentAppAudioFrameCount, nil)
                }
                silentAppAudioFrameCount += 1
                let shouldWarn = silentAppAudioFrameCount == 100 || silentAppAudioFrameCount == 500
                return (false, silentAppAudioFrameCount, shouldWarn ? silentAppAudioFrameCount : nil)
            }
            if nonSilentLog.shouldLog {
                logger.log(
                    level: .info,
                    message: "First non-silent ReplayKit app-audio frame sampleRate=\(frame.sampleRate) channels=\(frame.channelCount) samples=\(frame.samples.count) peak=\(frame.peakMagnitude) rms=\(frame.rmsMagnitude) silentFramesBefore=\(nonSilentLog.silentFramesBefore)"
                )
            }
            if let silenceWarningFrameCount = nonSilentLog.silenceWarningFrameCount {
                logger.log(
                    level: .warning,
                    message: "ReplayKit app audio still silent frames=\(silenceWarningFrameCount) lastPeak=\(frame.peakMagnitude) lastRms=\(frame.rmsMagnitude)"
                )
            }
            systemAudioEgress.push(frame)
        } catch {
            let shouldLog = stateLock.withLock {
                if loggedAudioConversionFailure { return false }
                loggedAudioConversionFailure = true
                return true
            }
            if shouldLog {
                logger.log(
                    level: .warning,
                    message: "Dropping ReplayKit app-audio packet; conversion failed: \(error)"
                )
            }
        }
    }

    private func handleVideoPacket(_ packet: ReplayKitBroadcastRelayPacket) {
        guard let videoSource else { return }
        guard let pixelBuffer = pixelBuffer(
            fromJPEG: packet.payload,
            orientationRawValue: packet.orientationRawValue
        ) else {
            logger.log(level: .warning, message: "ReplayKit relay failed to decode video packet")
            return
        }
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: ._0,
            timeStampNs: packet.timestampNs
        )
        videoSource.capturer(capturer, didCapture: frame)
    }

    private func pixelBuffer(
        fromJPEG data: Data,
        orientationRawValue: UInt8
    ) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        let uprightImage = ReplayKitScreenShareJPEGOrientation.uprightCIImage(
            CIImage(cgImage: image),
            orientationRawValue: orientationRawValue
        )
        let (normalizedImage, outputWidth, outputHeight) = ReplayKitScreenShareJPEGOrientation.normalizedUprightImage(uprightImage)
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

        ciContext.render(
            normalizedImage,
            to: pixelBuffer,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
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

    private func publishBroadcastStopRequest(containerURL: URL) {
        let stopURL = containerURL.appendingPathComponent(Self.stopFileName)
        let payload = "\(Date().timeIntervalSince1970)"
        do {
            try payload.write(to: stopURL, atomically: true, encoding: .utf8)
        } catch {
            logger.log(level: .warning, message: "Failed to publish ReplayKit broadcast stop request: \(error)")
        }
    }

    private func removeRelayFiles(containerURL: URL, includingStopRequest: Bool) {
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(Self.portFileName))
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(Self.optionsFileName))
        if includingStopRequest {
            try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(Self.stopFileName))
        }
    }
}

#endif
