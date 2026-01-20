//
//  KeyManager.swift
//  pqs-rtc
//
//  Created by Cole M on 12/2/25.
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
import DoubleRatchetKit
import NeedleTailLogger

/// In-memory cache for identities and one-time keys used by `RTCSession`.
///
/// This actor intentionally does not persist keys to disk. All cached material is cleared when
/// the process exits or when ``clearAll()`` is called.
public actor KeyManager: SessionIdentityDelegate {
    
    /// Cached local identity bundle for the active call/session.
    private var connectionLocalIdentity: ConnectionLocalIdentity?
    
    private var connectionIdentities: [String: ConnectionSessionIdentity] = [:]
    
    /// Temporary storage for ciphertext received before a recipient identity exists.
    private var pendingCiphertext: [String: Data] = [:]

    private var oneTimeKeys: [UUID: CurvePrivateKey] = [:]
    
    private let dbsk = SymmetricKey(size: .bits256)
    
    /// Logger for key store operations.
    private let logger: NeedleTailLogger
    
    private let crypto = NeedleTailCrypto()
    
    public init(logger: NeedleTailLogger = NeedleTailLogger("[CallKeyStore]")) {
        self.logger = logger
    }
    
    // MARK: - SessionIdentityDelegate
    
    public func updateSessionIdentity(_ identity: DoubleRatchetKit.SessionIdentity) async throws {
        guard var connectionIdentity = connectionIdentities[identity.id.uuidString] else {
            logger.log(level: .error, message: "Missing connection identity for updated session identity in CallKeyStore")
            return
        }
        connectionIdentity.sessionIdentity = identity
        connectionIdentities[identity.id.uuidString] = connectionIdentity
        logger.log(level: .debug, message: "Updated session identity: \(identity.id)")
    }
    
    public func fetchOneTimePrivateKey(_ id: UUID?) async throws -> DoubleRatchetKit.CurvePrivateKey? {
        guard let id else {
            return nil
        }
        return oneTimeKeys[id]
    }
    
    public func updateOneTimeKey(remove id: UUID) async {
        oneTimeKeys.removeValue(forKey: id)
    }
    
    // MARK: - Additional Convenience Methods
    
    /// Stores a one-time private key.
    /// - Parameters:
    ///   - key: The one-time private key
    ///   - id: The key ID
    public func storeOneTimeKey(_ key: CurvePrivateKey, id: UUID) {
        oneTimeKeys[id] = key
    }
    
    /// Retrieves a session identity by id.
    /// - Parameter id: The session identity ID
    /// - Returns: The session identity if found, nil otherwise
    public func fetchSessionIdentity(_ id: UUID) -> SessionIdentity? {
        guard let connectionIdentity = connectionIdentities[id.uuidString] else {
            logger.log(level: .error, message: "Missing connection identity for fetch session identity in CallKeyStore")
            return nil
        }
        return connectionIdentity.sessionIdentity
    }
    
    /// Removes a session identity.
    /// - Parameter id: The session identity ID
    public func removeSessionIdentity(_ id: UUID) {
        connectionIdentities.removeValue(forKey: id.uuidString)
        logger.log(level: .debug, message: "Removed session identity: \(id)")
    }
    
    /// Removes a connection identity and any pending ciphertext for a given `connectionId`.
    /// - Parameter connectionId: The connection ID associated with the identity
    public func removeConnectionIdentity(connectionId: String) {
        connectionIdentities.removeValue(forKey: connectionId)
        pendingCiphertext.removeValue(forKey: connectionId)
        logger.log(level: .debug, message: "Removed connection identity and pending ciphertext for connectionId: \(connectionId)")
    }
    
    /// Removes all cached data.
    public func clearAll() {
        connectionLocalIdentity = nil
        connectionIdentities.removeAll()
        pendingCiphertext.removeAll()
        oneTimeKeys.removeAll()
        logger.log(level: .info, message: "Cleared all cached data: \(String(describing: sessionIdentityCount)) session identities")
    }
    
    /// Returns the number of cached session identities.
    public func sessionIdentityCount() -> Int {
        return connectionIdentities.count
    }
    
    /// Returns the number of cached one-time keys.
    public func oneTimeKeyCount() -> Int {
        oneTimeKeys.count
    }
    
    // MARK: - CallKeyBundleStore
    public func fetchCallKeyBundle() async throws -> ConnectionLocalIdentity? {
        return connectionLocalIdentity
    }
    
    public func removeCallKeyBundle() async {
        connectionLocalIdentity = nil
    }
    
    public func fetchConnectionIdentity(_ id: UUID) -> ConnectionSessionIdentity? {
        guard let connectionIdentity = connectionIdentities[id.uuidString] else {
            logger.log(level: .error, message: "Missing connection identity for fetch session identity in CallKeyStore")
            return nil
        }
        return connectionIdentity
    }
    
    /// Fetches a connection identity by its string `connectionId`.
    /// - Parameter connectionId: The connection ID as a String
    /// - Returns: The connection identity if found, nil otherwise
    public func fetchConnectionIdentityByConnectionId(_ connectionId: String) -> ConnectionSessionIdentity? {
        return connectionIdentities[connectionId]
    }
    
    /// Stores ciphertext for a connection identity.
    ///
    /// If the identity has not been created yet, the ciphertext is stored in a pending cache and
    /// will be attached when ``createRecipientIdentity(connectionId:props:)`` is called.
    /// - Parameters:
    ///   - connectionId: The connection ID
    ///   - ciphertext: The ciphertext to store
    public func storeCiphertext(connectionId: String, ciphertext: Data) {
        if var identity = connectionIdentities[connectionId] {
            identity.ciphertext = ciphertext
            connectionIdentities[connectionId] = identity
            logger.log(level: .debug, message: "Stored ciphertext for connection: \(connectionId)")
        } else {
            // Store temporarily until identity is created
            pendingCiphertext[connectionId] = ciphertext
            logger.log(level: .info, message: "Stored ciphertext temporarily for connection: \(connectionId) (identity not yet created)")
        }
    }
    
    /// Retrieves ciphertext for a connection identity.
    /// - Parameter connectionId: The connection ID
    /// - Returns: The stored ciphertext, if any (checks both identity and pending storage)
    public func fetchCiphertext(connectionId: String) -> Data? {
        // First check if identity exists and has ciphertext
        if let identity = connectionIdentities[connectionId], let ciphertext = identity.ciphertext {
            return ciphertext
        }
        // Otherwise check pending storage
        return pendingCiphertext[connectionId]
    }
    
    // MARK: - CallKeyBundleProvider
    /// Generates and caches a new local sender identity bundle.
    ///
    /// This creates long-term, one-time, signing, and ML-KEM keys needed to bootstrap
    /// pairwise PQXDH + Double Ratchet sessions.
    public func generateSenderIdentity(
        connectionId: String,
        secretName: String
    ) async throws -> ConnectionLocalIdentity {
        
        let ltpk = crypto.generateCurve25519PrivateKey()
        let otpk = crypto.generateCurve25519PrivateKey()
        let spk = crypto.generateCurve25519SigningPrivateKey()
        let kem = try crypto.generateMLKem1024PrivateKey()
        
        let ltpkId = UUID()
        let otpkId = UUID()
        let kemId = UUID()
        
        // Store one-time key
        let oneTimeKey = try CurvePrivateKey(id: otpkId, otpk.rawRepresentation)
        
        let localKeys = LocalKeys(
            longTerm: try CurvePrivateKey(id: ltpkId, ltpk.rawRepresentation),
            oneTime: oneTimeKey,
            mlKEM: try MLKEMPrivateKey(id: kemId, kem.encode()))
        
        // Create session identity
        // If recipient public keys are provided, use them; otherwise create a placeholder
        let sessionId = UUID(uuidString: connectionId) ?? UUID()
        let sessionIdentity: SessionIdentity
        
            // Create a placeholder SessionIdentity (will be updated when recipient keys are received)
            // For now, use self's public keys as placeholder
        let props = try SessionIdentity.UnwrappedProps(
            secretName: secretName,
            deviceId: UUID(),
            sessionContextId: 0,
            longTermPublicKey: ltpk.publicKey.rawRepresentation,
            signingPublicKey: spk.publicKey.rawRepresentation,
            // Important: preserve key IDs so the receiver can fetch the matching private one-time keys
            // when a header indicates `oneTimeKeyId` / `mlKEMOneTimeKeyId`.
            mlKEMPublicKey: MLKEMPublicKey(id: kemId, kem.publicKey.rawRepresentation),
            oneTimePublicKey: CurvePublicKey(id: otpkId, otpk.publicKey.rawRepresentation),
            deviceName: "\(secretName)-rtc",
            isMasterDevice: true)
        
            sessionIdentity = try SessionIdentity(
                id: sessionId,
                props: props,
                symmetricKey: dbsk)
        
        let identity = ConnectionLocalIdentity(
            connectionId: connectionId,
            localKeys: localKeys,
            symmetricKey: dbsk,
            sessionIdentity: sessionIdentity)
        
        // Store the bundle
        connectionLocalIdentity = identity
        
        return identity
    }
    
    /// Creates and stores a recipient identity for a peer.
    ///
    /// If ciphertext arrived before the identity existed, it will be attached to the newly
    /// created identity.
    public func createRecipientIdentity(
        connectionId: String,
        props: SessionIdentity.UnwrappedProps
    ) async throws -> ConnectionSessionIdentity {
        let sessionId = UUID(uuidString: connectionId) ?? UUID()
        var identity = ConnectionSessionIdentity(
            connectionId: connectionId,
            symmetricKey: dbsk,
            sessionIdentity: try SessionIdentity(
                id: sessionId,
                props: props,
                symmetricKey: dbsk))
        
        // Check if there's pending ciphertext for this connection
        if let pendingCipher = pendingCiphertext[connectionId] {
            identity.ciphertext = pendingCipher
            pendingCiphertext.removeValue(forKey: connectionId)
            logger.log(level: .info, message: "Attached pending ciphertext to newly created identity for connection: \(connectionId)")
        }
        
        connectionIdentities[connectionId] = identity
        logger.log(level: .info, message: "Created new recipient identity \(identity) on connection identity \(connectionId)")
        return identity
    }
}
