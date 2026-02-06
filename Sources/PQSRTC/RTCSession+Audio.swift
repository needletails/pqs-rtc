//
//  RTCSession+Audio.swift
//  pqs-rtc
//
//  Created by Cole M on 9/11/24.
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
import WebRTC
#endif
import Foundation
import NeedleTailLogger

/// Errors that can occur during audio operations
public enum AudioError: Error, Sendable {
    case connectionNotFound(String)
    case audioTrackCreationFailed(String)
    case audioSessionConfigurationFailed(String)
    case invalidAudioMode(String)
    case audioSessionActivationFailed(String)
    case audioSessionDeactivationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id):
            return "Audio connection not found with ID: \(id)"
        case .audioTrackCreationFailed(let reason):
            return "Failed to create audio track: \(reason)"
        case .audioSessionConfigurationFailed(let reason):
            return "Failed to configure audio session: \(reason)"
        case .invalidAudioMode(let mode):
            return "Invalid audio mode: \(mode)"
        case .audioSessionActivationFailed(let reason):
            return "Failed to activate audio session: \(reason)"
        case .audioSessionDeactivationFailed(let reason):
            return "Failed to deactivate audio session: \(reason)"
        }
    }
}

extension RTCSession {
    
    
    
    /// Sets the audio track enabled state for a specific connection
    /// - Parameters:
    ///   - isEnabled: Whether the audio track should be enabled
    ///   - connectionId: The connection ID to modify
    /// - Throws: AudioError if connection not found
    func setAudioTrack(isEnabled: Bool, connectionId: String) async throws {
        logger.log(level: .info, message: "Setting audio track enabled: \(isEnabled) for connection: \(connectionId)")
        
        guard !connectionId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            logger.log(level: .error, message: "Connection ID cannot be empty")
            throw AudioError.connectionNotFound("Empty connection ID")
        }
        
        let manager = connectionManager as RTCConnectionManager
        guard let connection: RTCConnection = await manager.findConnection(with: connectionId) else {
            logger.log(level: .error, message: "Connection not found for audio track modification: \(connectionId)")
            throw AudioError.connectionNotFound(connectionId)
        }
#if !os(Android)
        await setTrackEnabled(WebRTC.RTCAudioTrack.self, isEnabled: isEnabled, with: connection)
#elseif os(Android)
        self.rtcClient.setAudioEnabled(isEnabled)
#endif
        logger.log(level: .info, message: "Successfully set audio track enabled: \(isEnabled) for connection: \(connectionId)")
    }
    

#if !os(Android)
    /// Creates an audio track with proper error handling and validation
    /// - Returns: The created RTCAudioTrack
    /// - Throws: AudioError if creation fails
    func createAudioTrack(with connection: RTCConnection) throws -> WebRTC.RTCAudioTrack {
        logger.log(level: .info, message: "Creating local audio track for connection: \(connection.id)")
        let audioConstraints = WebRTC.RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = RTCSession.factory.audioSource(with: audioConstraints)
        // IMPORTANT (SFU + E2EE):
        // Track IDs must be unique per sender. Using only `connection.id` (room id) causes the SFU
        // to receive multiple participants with the same `track_id` (e.g. "audio_<roomId>"), which
        // breaks forwarding/demux and can also break frame-cryptor key routing.
        //
        // We use: audio_<localParticipantId>_<connectionId>
        let audioTrackId = "audio_\(connection.localParticipantId)_\(connection.id)"
        let audioTrack = RTCSession.factory.audioTrack(with: audioSource, trackId: audioTrackId)
        logger.log(level: .info, message: "Successfully created audio track")
        return audioTrack
    }
#else
    /// Creates an audio track with Android-specific audio capture
    /// - Parameter connection: The connection to add the audio track to
    /// - Returns: Tuple containing the audio track and updated connection
    /// - Throws: AudioError if creation fails
    func createAudioTrack(with connection: RTCConnection) async throws -> RTCAudioTrack {
        logger.log(level: .info, message: "Creating local audio track for connection: \(connection.id)")
        let audioConstraints = self.rtcClient.createConstraints()
        logger.log(level: .info, message: "Successfully created audio constraints \(audioConstraints)")
        let audioSource = self.rtcClient.createAudioSource(audioConstraints)
        logger.log(level: .info, message: "Successfully created audio source \(audioSource)")
        let audioTrack = self.rtcClient.createAudioTrack(id: connection.id, audioSource)
        logger.log(level: .info, message: "Successfully created audio track \(audioTrack)")
        return audioTrack
    }
#endif
    
#if os(iOS)
    /// Configures the audio session with proper error handling
    /// - Throws: AudioError if configuration fails
    nonisolated public func configureAudioSession() throws {
        do {
            audioSession.lockForConfiguration()
            defer {
                audioSession.unlockForConfiguration()
            }
            
            try audioSession.setCategory(.playAndRecord)
            try audioSession.setMode(.videoChat)
            
            logger.log(level: .info, message: "Successfully configured audio session")
            
        } catch {
            logger.log(level: .error, message: "Error configuring AVAudioSession category: \(error)")
            throw AudioError.audioSessionConfigurationFailed("Failed to set category/mode: \(error.localizedDescription)")
        }
    }
    
    /// Sets manual audio mode with logging
    /// - Parameter enabled: Whether manual audio should be enabled
    nonisolated public func setManualAudio(_ enabled: Bool) {
        audioSession.useManualAudio = enabled
        logger.log(level: .info, message: "Set manual audio mode: \(enabled)")
    }
    
    /// Sets audio enabled state with logging
    /// - Parameter enabled: Whether audio should be enabled
    nonisolated public func setAudio(_ enabled: Bool) {
        audioSession.isAudioEnabled = enabled
        logger.log(level: .info, message: "Set audio enabled: \(enabled)")
    }
    
    /// Sets external audio session with proper error handling
    /// - Throws: AudioError if configuration fails
    nonisolated public func setExternalAudioSession() throws {
        audioSession.lockForConfiguration()
        defer {
            audioSession.unlockForConfiguration()
        }
        
        setManualAudio(true)
        logger.log(level: .info, message: "Successfully set external audio session")
    }
    
    /// Sets the audio mode with proper validation and error handling
    /// - Parameter mode: The audio mode to set
    /// - Throws: AudioError if mode is invalid or setting fails
    public nonisolated func setAudioMode(mode: AVAudioSession.Mode) throws {
        logger.log(level: .info, message: "Setting audio mode: \(mode.rawValue)")
        
        // Validate audio mode
        let validModes: [AVAudioSession.Mode] = [.videoChat, .voiceChat, .default]
        guard validModes.contains(mode) else {
            logger.log(level: .error, message: "Invalid audio mode: \(mode.rawValue)")
            throw AudioError.invalidAudioMode(mode.rawValue)
        }

        do {
            // Lock for configuration first
            audioSession.lockForConfiguration()
            defer {
                audioSession.unlockForConfiguration()
            }
            
            // Track if session was active before changes
            let wasActive = audioSession.isActive
            
            // Set the correct category with the desired mode directly
            // This can be done while the session is active if we have the lock
            if mode == .videoChat || mode == .voiceChat {
                try audioSession.setCategory(.playAndRecord, mode: mode)
            } else {
                try audioSession.setCategory(.playback, mode: mode)
            }

            // Log current state
            logger.log(level: .info, message: "Current audio session category: \(audioSession.category)")
            logger.log(level: .info, message: "Current audio session mode: \(audioSession.mode)")

            // Set output port based on mode
            if mode == .videoChat {
                try audioSession.overrideOutputAudioPort(.speaker)
            } else {
                try audioSession.overrideOutputAudioPort(.none)
            }
            
            // Only activate if it wasn't already active
            // If it was active, it remains active and our changes are applied
            if !wasActive {
                try audioSession.setActive(true)
            }
            
            logger.log(level: .info, message: "Successfully set audio mode: \(mode.rawValue)")
        } catch {
            logger.log(level: .error, message: "Error changing AVAudioSession mode: \(error)")
            throw AudioError.audioSessionConfigurationFailed("Failed to set mode: \(error.localizedDescription)")
        }
    }
    
    /// Activates the audio session with proper error handling
    /// - Parameter session: The AVAudioSession to activate
    /// - Throws: AudioError if activation fails
    nonisolated public func activateAudioSession(session: AVAudioSession) throws {
        // Check if already activated before locking
        if isAudioActivated {
            return
        }
        
        do {
            audioSession.lockForConfiguration()
            defer {
                audioSession.unlockForConfiguration()
            }
            
            // Double-check after acquiring lock
            if isAudioActivated {
                return
            }
            
            isAudioActivated = true
            audioSession.audioSessionDidActivate(session)
            try audioSession.setCategory(.playAndRecord)
            try audioSession.setMode(.videoChat)
            setAudio(true)
            
            logger.log(level: .info, message: "Successfully activated audio session")
            
        } catch {
            logger.log(level: .error, message: "Error activating AVAudioSession: \(error)")
            throw AudioError.audioSessionActivationFailed("Failed to activate session: \(error.localizedDescription)")
        }
    }
    
    /// Deactivates the audio session with proper error handling
    /// - Parameter session: The AVAudioSession to deactivate
    /// - Throws: AudioError if deactivation fails
    nonisolated public func deactivateAudioSession(session: AVAudioSession) throws {
        // Check if already deactivated before locking
        if !isAudioActivated {
            return
        }
        
        audioSession.lockForConfiguration()
        defer {
            audioSession.unlockForConfiguration()
        }
        
        // Double-check after acquiring lock
        if !isAudioActivated {
            return
        }
        
        isAudioActivated = false
        audioSession.audioSessionDidDeactivate(session)
        audioSession.isAudioEnabled = false
        
        logger.log(level: .info, message: "Successfully deactivated audio session")
    }
#endif
    
#if os(macOS)
    public func startRingtone() async {
        if let url = Bundle.main.url(forResource: "ringtone", withExtension: "mp3") {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.volume = 0.5
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
            } catch {
                logger.log(level: .error, message: "Error initializing player: \(error.localizedDescription)")
            }
        }
    }
    
    public func stopRingtone() async {
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
        }
    }
#endif
}

#if os(iOS)
extension RTCAudioSession: @retroactive @unchecked Sendable {}
extension RTCSession: RTCAudioDelegate {}

/// Audio-session control hooks used by the SDK on iOS.
///
/// This delegate exists to isolate platform audio-session management from the rest of the
/// call/session state machine. The SDK’s default implementation is provided by `RTCSession`.
///
/// - Important: This protocol is compiled only on iOS.
public protocol RTCAudioDelegate: AnyObject, Sendable {
    /// Configures the underlying `AVAudioSession` for VoIP usage.
    func configureAudioSession() throws

    /// Enables or disables manual audio routing/mode management.
    func setManualAudio(_ enabled: Bool)

    /// Enables or disables audio capture/playout.
    func setAudio(_ enabled: Bool)

    /// Switches the SDK into a mode where the host app manages the `AVAudioSession`.
    func setExternalAudioSession() throws

    /// Updates the `AVAudioSession` mode (for example, `.voiceChat`).
    func setAudioMode(mode: AVAudioSession.Mode) throws

    /// Activates the given `AVAudioSession`.
    func activateAudioSession(session: AVAudioSession) throws

    /// Deactivates the given `AVAudioSession`.
    func deactivateAudioSession(session: AVAudioSession) throws
}
#endif

