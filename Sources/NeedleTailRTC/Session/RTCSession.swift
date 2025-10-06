#if canImport(WebRTC)
import WebRTC
#endif
import Foundation
import DequeModule
import NeedleTailLogger
import NTKLoop
import NeedleTailAsyncSequence

public actor RTCSession {
    
    let connectionManager = RTCConnectionManager()
    public let callState: CallStateMachine
    private let streamId = "stream"
    let logger: NeedleTailLogger
    private var iceId = 0
    private let iceServers: [String]
    private let username: String
    private let password: String
    private var stateTask: Task<Void, Error>?
    private var notificationsTask: Task<Void, Error>?
    nonisolated(unsafe) var notificationStreamContinuation: AsyncStream<PeerConnectionNotifications?>.Continuation?
    
    private var notRunning = true
    private var lastId = 0
    private let runLoop = NTKLoop()
    private var readyForCandidates = false
    private var iceDeque = Deque<IceCandidate>()
    private var pcState = PeerConnectionState.none
    
    // Public accessor functions for Skip compatibility
    public func getDelegate() -> SessionDelegate? { delegate }
    public func getRunLoop() -> NTKLoop { runLoop }
    public func getPcState() -> PeerConnectionState { pcState }
    public func getLastId() -> Int { lastId }
    public func getNotRunning() -> Bool { notRunning }
    public func getIceDeque() -> Deque<IceCandidate> { iceDeque }
    public func getReadyForCandidates() -> Bool { readyForCandidates }
    
    // Setters for private properties
    public func setDelegateInternal(_ newDelegate: SessionDelegate?) { delegate = newDelegate }
    public func setPcState(_ newState: PeerConnectionState) { pcState = newState }
    public func setLastId(_ newId: Int) { lastId = newId }
    public func setNotRunning(_ newValue: Bool) { notRunning = newValue }
    public func setReadyForCandidates(_ newValue: Bool) { readyForCandidates = newValue }
    public func setIceDeque(_ newDeque: Deque<IceCandidate>) { iceDeque = newDeque }
    public func setIceId(_ newId: Int) { iceId = newId }
    public func getIceId() -> Int { iceId }
    public func getStateTask() -> Task<Void, Error>? { stateTask }
    public func setStateTask(_ newTask: Task<Void, Error>?) { stateTask = newTask }
    public func setUserMetadata(_ callee: String, avatar: Data) async {
        self.callee = callee
        self.avatar = avatar
    }
    
    // Additional getters for private properties
    public func getIceServers() -> [String] { iceServers }
    public func getUsername() -> String { username }
    public func getPassword() -> String { password }
    
    let inboundCandidateConsumer = NeedleTailAsyncConsumer<IceCandidate>()
    var callee: String = ""
    var avatar: Data?
    
    public init(
        iceServers: [String],
        username: String,
        password: String,
        logger: NeedleTailLogger = NeedleTailLogger("[RTCSession]")
    ) {
        self.iceServers = iceServers
        self.username = username
        self.password = password
        self.logger = logger
        self.callState = CallStateMachine()
        logger.log(level: .info, message: "Created WebRTC Client")
    }
    
    public enum PeerConnectionState: Sendable {
        case setRemote, none
    }
    
    var calls: [Call] {
        get async {
            await delegate?.calls ?? []
        }
    }
    
    private weak var delegate: SessionDelegate?
    var _delegate: SessionDelegate? {
        get async {
            delegate
        }
    }
    
    // Platform-specific factory/client initialization
#if os(Android)
    // SkipRTC RTCClient for Android platform - use shared singleton
    static let rtcClient: RTCClient = RTCClient.shared
#elseif canImport(WebRTC)
    // iOS/macOS WebRTC factory initialization
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
#endif
    
    // SkipRTC initialization method
#if os(Android)
    func initializeSkipRTC(iceServers: [String]) async {
        Self.rtcClient.initializeFactory(iceServers: iceServers)
    }
#endif
    
    // Platform-specific audio session management
#if !os(Android)
#if os(iOS)
    nonisolated let audioSession = RTCAudioSession.sharedInstance()
#endif
#if os(macOS)
    var audioPlayer: AVAudioPlayer?
#endif
#endif
    
    deinit {
#if DEBUG
        logger.log(level: .debug, message: "Reclaimed memory in WebRTC Client")
#endif
    }
    
    
    /// Adds audio to a stream with proper error handling
    /// - Parameter connection: The connection to add audio to
    /// - Returns: Updated connection with audio track
    /// - Throws: AudioError if audio addition fails
    func addAudioToStream(with connection: RTCConnection) async throws -> RTCConnection {
        logger.log(level: .info, message: "Adding audio to stream for connection: \(connection.id)")
        
        do {
#if !os(Android)
            // Create audio track
            let audioTrack = try self.createAudioTrack(with: connection)
            
            // Add audio track to peer connection
            _ = connection.peerConnection.add(audioTrack, streamIds: [streamId])
#elseif os(Android)
            // Create audio track
            let audioTrack = try await self.createAudioTrack(with: connection)
            
            // Use NeedleTailRTC's prepareAudioSendRecv method to handle audio track addition
            Self.rtcClient.prepareAudioSendRecv(id: connection.id)
#endif
            
            
            logger.log(level: .info, message: "Successfully added audio to stream for connection: \(connection.id)")
            return connection
            
        } catch let error as AudioError {
            logger.log(level: .error, message: "Failed to add audio to stream: \(error.localizedDescription)")
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error adding audio to stream: \(error)")
            throw AudioError.audioTrackCreationFailed("Failed to add audio to stream: \(error.localizedDescription)")
        }
    }
    
    /// Adds video to a stream with proper error handling
    /// - Parameter connection: The connection to add video to
    /// - Returns: Updated connection with video track
    /// - Throws: RTCErrors if video addition fails
    public func addVideoToStream(with connection: RTCConnection) async throws -> RTCConnection {
        logger.log(level: .info, message: "Adding video to stream for connection: \(connection.id)")
        
        do {
            // Create local video track
            var (videoTrack, updatedConnection) = try await self.createLocalVideoTrack(with: connection)
            
#if !os(Android)
            // Set local video track
            updatedConnection.localVideoTrack = videoTrack.track
            _ = updatedConnection.peerConnection.add(videoTrack.track, streamIds: [streamId])
#else
            //             Set local video track
            updatedConnection.localVideoTrack = videoTrack.track
//            _ = updatedConnection.peerConnection.addTrack(videoTrack.track, [streamId].toList()) //TODO: 
#endif
            logger.log(level: .info, message: "Successfully added video to stream for connection: \(connection.id)")
            return updatedConnection
        } catch let error as RTCErrors {
            logger.log(level: .error, message: "Failed to add video to stream: \(error.localizedDescription)")
            throw error
        } catch {
            logger.log(level: .error, message: "Unexpected error adding video to stream: \(error)")
            throw RTCErrors.mediaError("Failed to add video to stream: \(error.localizedDescription)")
        }
    }
    
    func handleNotificationsStream() {
        if notificationsTask?.isCancelled == false {
            notificationsTask?.cancel()
        }
        notificationsTask = Task { [weak self] in
            guard let self else { return }
            await handlePeerConnectionNotifications()
        }
    }
    
    public func createStateStream(with call: Call) async {
        await callState.createStreams(with: call)
        handleStateStream()
    }
    
    private func handleStateStream() {
        if stateTask?.isCancelled == false { stateTask?.cancel() }
        stateTask = Task { [weak self] in
            guard let self else { return }
            guard let stateStream = await self.callState.getCurrentCallStream().first else { return }
            try await handleState(stateStream: stateStream)
        }
    }
    
    public func setCurrentCall(
        call: Call,
        callDirection: CallStateMachine.CallDirection) async {
            switch await callState.getCurrentState() {
            case .ready:
                await self.callState.transition(
                    to: .connecting(
                        callDirection,
                        call
                    )
                )
            default:
                break
            }
        }
    
    public func shutdown() async {
        for continuation in await callState.getStreamContinuations() {
            continuation.finish()
        }
        notificationsTask?.cancel()
        notificationsTask = nil
        await connectionManager.removeAllConnections()
        notificationStreamContinuation?.finish()
    }
    
    public func endCall(
        endState: CallStateMachine.EndState,
        sharedMessageId: String
    ) async {
        do {
            guard let currentCall = await calls.first(where: { $0.sharedMessageId == sharedMessageId }) else {
                throw RTCErrors.callNotFound
            }
            await callState.transition(to: .ended(endState, currentCall))
        } catch {
            logger.log(level: .error, message: "Error Ending Call: \(error)")
        }
    }
    
    public func removeRejected(call: Call) async {
        await delegate?.updateMetadata(for: call, callState: .ended(.partnerInitiatedRejected, call))
    }
    
    public func holdCall() async throws {
        if let current = await callState.getCurrentCall() {
            let direction = await callState.getCallDirection()
            await self.callState.transition(to: .held(direction, current))
            await delegate?.sendHoldCallMessage(to: current)
            try? await setAudioTrack(isEnabled: false, connectionId: current.sharedCommunicationId)
            await setVideoTrack(isEnabled: false, connectionId: current.sharedCommunicationId)
        }
    }
    
    public func resumeCall() async {
        if let current = await callState.getCurrentCall() {
            let direction = await callState.getCallDirection() ?? CallStateMachine.CallDirection.outbound(current.supportsVideo ? CallStateMachine.CallType.video : CallStateMachine.CallType.voice)
            await setVideoTrack(isEnabled: current.supportsVideo, connectionId: current.sharedCommunicationId)
            try? await setAudioTrack(isEnabled: true, connectionId: current.sharedCommunicationId)
            await self.callState.transition(to: .connecting(direction, current))
        }
    }
}

extension RTCSession {
    
    /// Sets the session delegate with proper validation and logging
    /// - Parameter delegate: The delegate to set for session callbacks
    public func setDelegate(_ delegate: SessionDelegate) {
        self.logger.log(level: .info, message: "Setting session delegate")
        self.setDelegateInternal(delegate)
    }
    
    /// Removes the current session delegate with proper cleanup
    public func removeDelegate() {
        self.logger.log(level: .info, message: "Removing session delegate")
        self.setDelegateInternal(nil)
    }
    
    /// Validates that the delegate is properly set
    /// - Returns: True if delegate is set, false otherwise
    public func hasDelegate() -> Bool {
        return getDelegate() != nil
    }
}


/// Errors that can occur during RTC operations
public enum RTCErrors: Error, Sendable {
    case reconnectionFailed
    case socketCreationFailed
    case timeout
    case missingRTCConnection
    case connectionNotFound
    case trackNotFound
    case callNotFound
    case invalidConfiguration(String)
    case networkError(String)
    case mediaError(String)
    
    public var errorDescription: String? {
        switch self {
        case .reconnectionFailed:
            return "Failed to reconnect to the network"
        case .socketCreationFailed:
            return "Failed to create network socket"
        case .timeout:
            return "Operation timed out"
        case .missingRTCConnection:
            return "RTC connection is missing"
        case .connectionNotFound:
            return "Connection not found"
        case .trackNotFound:
            return "Media track not found"
        case .callNotFound:
            return "Call not found"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .mediaError(let message):
            return "Media error: \(message)"
        }
    }
}
