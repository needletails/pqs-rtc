import Foundation
import Testing

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
@preconcurrency import WebRTC

/// A receiver FrameCryptor built on the session's key provider must refuse keyless cleartext
/// frames, whatever trailer they carry. The sender here stands in for a hostile SFU: it sends
/// plain H264 with "PQSRTCMagicBytes" appended and holds no frame key.
@Suite(.serialized)
struct FrameCryptorMagicBytesBypassTests {
    enum TestError: Error {
        case iceGatheringTimedOut
    }

    @Test
    func receiverCryptorRefusesKeylessFramesEndingInMagicBytes() async throws {
        RTCInitializeSSL()
        let session = await RTCSession(iceServers: [], username: "", password: "", delegate: nil)
        let keyProvider = try #require(await session.keyProvider)

        let decodes = Counter()
        let factory = RTCPeerConnectionFactory(
            encoderFactory: MagicSuffixEncoderFactory(suffix: Data("PQSRTCMagicBytes".utf8)),
            decoderFactory: CountingDecoderFactory(decodes: decodes))
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreLoopbackNetworkAdapter = false
        factory.setOptions(options)

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let sender = try #require(factory.peerConnection(with: config, constraints: constraints, delegate: nil))
        let receiver = try #require(factory.peerConnection(with: config, constraints: constraints, delegate: nil))
        defer {
            sender.close()
            receiver.close()
        }

        let source = factory.videoSource()
        let capturer = RTCVideoCapturer(delegate: source)
        _ = sender.add(factory.videoTrack(with: source, trackId: "video"), streamIds: ["stream"])

        let offer = try await sender.offer(for: constraints)
        try await sender.setLocalDescription(offer)
        try await waitForIceGatheringComplete(sender)
        try await receiver.setRemoteDescription(try #require(sender.localDescription))

        let rtpReceiver = try #require(receiver.transceivers.first { $0.mediaType == .video }?.receiver)
        let refusals = Counter()
        let cryptorDelegate = RefusalRecorder(refusals: refusals)
        let cryptor = try #require(RTCFrameCryptor(
            factory: factory,
            rtpReceiver: rtpReceiver,
            participantId: "remote",
            algorithm: .aesGcm,
            keyProvider: keyProvider))
        cryptor.delegate = cryptorDelegate
        cryptor.enabled = true

        let answer = try await receiver.answer(for: constraints)
        try await receiver.setLocalDescription(answer)
        try await waitForIceGatheringComplete(receiver)
        try await sender.setRemoteDescription(try #require(receiver.localDescription))

        // Feed frames until one is decoded or the cryptor refuses one, then a little longer.
        let buffer = RTCI420Buffer(width: 320, height: 240)
        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(15)
        var settled = false
        while clock.now < deadline {
            let frame = RTCVideoFrame(
                buffer: buffer,
                rotation: ._0,
                timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
            source.capturer(capturer, didCapture: frame)
            try await Task.sleep(for: .milliseconds(33))
            if !settled, decodes.value > 0 || refusals.value > 0 {
                settled = true
                deadline = min(deadline, clock.now + .seconds(1))
            }
        }

        #expect(decodes.value == 0, "keyless cleartext frames ending in the magic bytes reached the decoder (\(decodes.value) decoded)")
        #expect(refusals.value > 0, "the receiver FrameCryptor never refused a keyless frame")

        cryptor.enabled = false
        withExtendedLifetime(cryptorDelegate) {}
        await session.shutdown(with: nil)
    }

    private func waitForIceGatheringComplete(_ peerConnection: RTCPeerConnection) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while peerConnection.iceGatheringState != .complete {
            guard clock.now < deadline else { throw TestError.iceGatheringTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class RefusalRecorder: NSObject, RTCFrameCryptorDelegate, @unchecked Sendable {
    private let refusals: Counter

    init(refusals: Counter) {
        self.refusals = refusals
    }

    func frameCryptor(
        _ frameCryptor: RTCFrameCryptor,
        didStateChangeWithParticipantId participantId: String,
        with stateChanged: RTCFrameCryptorState
    ) {
        switch stateChanged {
        case .decryptionFailed, .missingKey, .internalError:
            refusals.increment()
        default:
            break
        }
    }
}

/// Real VideoToolbox H264 encoder whose output frames get `suffix` appended, unencrypted.
private final class MagicSuffixEncoderFactory: NSObject, RTCVideoEncoderFactory, @unchecked Sendable {
    private let inner = RTCVideoEncoderFactoryH264()
    private let suffix: Data

    init(suffix: Data) {
        self.suffix = suffix
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        inner.createEncoder(info).map { MagicSuffixEncoder(inner: $0, suffix: suffix) }
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        inner.supportedCodecs()
    }
}

private final class MagicSuffixEncoder: NSObject, RTCVideoEncoder, @unchecked Sendable {
    private let inner: any RTCVideoEncoder
    private let suffix: Data

    init(inner: any RTCVideoEncoder, suffix: Data) {
        self.inner = inner
        self.suffix = suffix
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        guard let callback else {
            inner.setCallback(nil)
            return
        }
        let suffix = suffix
        inner.setCallback { frame, info in
            frame.buffer = frame.buffer + suffix
            return callback(frame, info)
        }
    }

    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        inner.startEncode(with: settings, numberOfCores: numberOfCores)
    }

    func release() -> Int {
        inner.release()
    }

    func encode(
        _ frame: RTCVideoFrame,
        codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
        frameTypes: [NSNumber]
    ) -> Int {
        inner.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        inner.setBitrate(bitrateKbit, framerate: framerate)
    }

    func implementationName() -> String {
        inner.implementationName()
    }

    func scalingSettings() -> RTCVideoEncoderQpThresholds? {
        inner.scalingSettings()
    }

    var resolutionAlignment: Int { inner.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { inner.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { inner.supportsNativeHandle }
}

/// Real H264 decoder that counts every frame handed to it.
private final class CountingDecoderFactory: NSObject, RTCVideoDecoderFactory, @unchecked Sendable {
    private let inner = RTCVideoDecoderFactoryH264()
    private let decodes: Counter

    init(decodes: Counter) {
        self.decodes = decodes
    }

    func createDecoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoDecoder)? {
        inner.createDecoder(info).map { CountingDecoder(inner: $0, decodes: decodes) }
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        inner.supportedCodecs()
    }
}

private final class CountingDecoder: NSObject, RTCVideoDecoder, @unchecked Sendable {
    private let inner: any RTCVideoDecoder
    private let decodes: Counter

    init(inner: any RTCVideoDecoder, decodes: Counter) {
        self.inner = inner
        self.decodes = decodes
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        inner.setCallback(callback)
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        inner.startDecode(withNumberOfCores: numberOfCores)
    }

    func release() -> Int {
        inner.release()
    }

    func decode(
        _ encodedImage: RTCEncodedImage,
        missingFrames: Bool,
        codecSpecificInfo info: (any RTCCodecSpecificInfo)?,
        renderTimeMs: Int64
    ) -> Int {
        decodes.increment()
        return inner.decode(encodedImage, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }

    func implementationName() -> String {
        inner.implementationName()
    }
}
#endif
