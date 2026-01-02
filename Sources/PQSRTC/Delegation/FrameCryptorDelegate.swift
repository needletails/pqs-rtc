//
//  FrameCryptorDelegate.swift
//  pqs-rtc
//
//  Created by Cole M on 11/30/25.
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

#if canImport(WebRTC)
import WebRTC
import NeedleTailLogger

final class FrameCryptorDelegate: NSObject, RTCFrameCryptorDelegate {
    private let logger: NeedleTailLogger
    
    init(logger: NeedleTailLogger = NeedleTailLogger("[FrameCryptor]")) {
        self.logger = logger
        super.init()
    }
    var lastOkLogTime: [String: Date] = [:]
    func frameCryptor(_ frameCryptor: RTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with stateChanged: RTCFrameCryptorState) {
        
        let stateDescription: String
        switch stateChanged {
        case .new:
            stateDescription = "new"
        case .ok:
            stateDescription = "ok"
        case .missingKey:
            stateDescription = "missingKey"
        case .keyRatcheted:
            stateDescription = "keyRatcheted"
        case .internalError:
            stateDescription = "internalError"
        case .encryptionFailed:
            stateDescription = "encryptionFailed"
        case .decryptionFailed:
            stateDescription = "decryptionFailed"
        @unknown default:
            stateDescription = "unknown(\(stateChanged.rawValue))"
        }

        logger.log(level: .info, message: "🔐 FrameCryptor state changed for participant '\(participantId)': \(stateDescription)")
        
        // Handle error states
        if stateChanged == .missingKey {
            logger.log(level: .error, message: "⚠️ FrameCryptor missing key for participant '\(participantId)' - encryption/decryption may fail")
        } else if stateChanged == .internalError {
            logger.log(level: .error, message: "FrameCryptor internal error for participant '\(participantId)'")
        } else if stateChanged == .encryptionFailed {
            logger.log(level: .error, message: "FrameCryptor encryption failed for participant '\(participantId)'")
        } else if stateChanged == .decryptionFailed {
            logger.log(level: .error, message: "FrameCryptor decryption failed for participant '\(participantId)'")
        } else if stateChanged == .ok {
            logger.log(level: .info, message: " - FrameCryptor is working correctly for participant '\(participantId)' - ")
        } else if stateChanged == .keyRatcheted {
            logger.log(level: .info, message: "🔄 FrameCryptor key ratcheted for participant '\(participantId)' - new key in use")
        }
        
        // Add periodic logging for state changes to track frame processing
        if stateChanged == .ok {
            // Log once per second max to avoid spam
            let now = Date()
            if let lastTime = lastOkLogTime[participantId], now.timeIntervalSince(lastTime) < 1.0 {
                // Skip logging if we logged recently
            } else {
                lastOkLogTime[participantId] = now
                logger.log(level: .debug, message: "✅ FrameCryptor OK state confirmed for participant '\(participantId)' - ready to process frames")
            }
        }
    }
}
#endif

