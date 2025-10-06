//
//  RTCSession+Audio.swift
//  needle-tail-rtc
//
//  Created by Cole M on 9/11/24.
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is proprietary and confidential.
//
//  All rights reserved. Unauthorized copying, distribution, or use
//  of this software is strictly prohibited.
//
//  This file is part of the NeedleTailRTC SDK, which provides
//  VoIP Capabilities
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
        Self.rtcClient.setAudioEnabled(isEnabled)
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
        let audioTrack = RTCSession.factory.audioTrack(with: audioSource, trackId: "audio_\(connection.id)")
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
        let audioConstraints = Self.rtcClient.createConstraints()
        let audioSource = Self.rtcClient.createAudioSource(audioConstraints)
        let audioTrack = Self.rtcClient.createAudioTrack(id: connection.id, audioSource)
        logger.log(level: .info, message: "Successfully created audio track")
        return audioTrack
    }
#endif
    
#if os(iOS)
    /// Configures the audio session with proper error handling
    /// - Throws: AudioError if configuration fails
    nonisolated func configureAudioSession() throws {
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
    nonisolated func setManualAudio(_ enabled: Bool) {
        audioSession.useManualAudio = enabled
        logger.log(level: .info, message: "Set manual audio mode: \(enabled)")
    }
    
    /// Sets audio enabled state with logging
    /// - Parameter enabled: Whether audio should be enabled
    nonisolated func setAudio(_ enabled: Bool) {
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
    public func setAudioMode(mode: AVAudioSession.Mode) async throws {
        logger.log(level: .info, message: "Setting audio mode: \(mode.rawValue)")
        
        // Validate audio mode
        let validModes: [AVAudioSession.Mode] = [.videoChat, .voiceChat, .default]
        guard validModes.contains(mode) else {
            logger.log(level: .error, message: "Invalid audio mode: \(mode.rawValue)")
            throw AudioError.invalidAudioMode(mode.rawValue)
        }
        
        do {
            audioSession.lockForConfiguration()
            defer {
                audioSession.unlockForConfiguration()
            }
            
            try audioSession.setCategory(.playAndRecord)
            
            // Set output port based on mode
            if mode == .videoChat {
                try audioSession.overrideOutputAudioPort(.speaker)
            } else {
                try audioSession.overrideOutputAudioPort(.none)
            }
            
            try audioSession.setMode(mode)
            
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
        do {
            audioSession.lockForConfiguration()
            defer {
                audioSession.unlockForConfiguration()
            }
            
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
        audioSession.lockForConfiguration()
        defer {
            audioSession.unlockForConfiguration()
        }
        
        audioSession.audioSessionDidDeactivate(session)
        audioSession.isAudioEnabled = false
        
        logger.log(level: .info, message: "Successfully deactivated audio session")
    }
    
    /// Legacy method for backward compatibility - now throws errors
    nonisolated public func activeAudioSession(session: AVAudioSession) {
        do {
            try activateAudioSession(session: session)
        } catch {
            logger.log(level: .error, message: "Legacy activeAudioSession failed: \(error)")
        }
    }
    
    /// Legacy method for backward compatibility - now throws errors
    nonisolated public func deActiveAudioSession(session: AVAudioSession) {
        do {
            try deactivateAudioSession(session: session)
        } catch {
            logger.log(level: .error, message: "Legacy deActiveAudioSession failed: \(error)")
        }
    }
#endif
}

#if os(iOS)
extension RTCAudioSession: @retroactive @unchecked Sendable {}
#endif
