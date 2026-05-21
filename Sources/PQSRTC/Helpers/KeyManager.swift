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
import Crypto
import DoubleRatchetKit
import NeedleTailLogger

/// In-memory cache for identities and one-time keys used by `RTCSession`.
///
/// This actor intentionally does not persist keys to disk. All cached material is cleared when
/// the process exits or when ``clearAll()`` is called.
public actor KeyManager: SessionIdentityDelegate {

    private var connectionLocalIdentity: ConnectionLocalIdentity?
    
    private var connectionIdentities: [String: ConnectionSessionIdentity] = [:]
    
    /// Temporary storage for ciphertext received before a recipient identity exists.
    private var pendingCiphertext: [String: Data] = [:]

    private var oneTimeKeys: [UUID: CurvePrivateKey] = [:]
    
    private let dbsk = SymmetricKey(size: .bits256)
    
    /// Logger for key store operations.
    private let logger: NeedleTailLogger
    
    private let crypto = NeedleTailCrypto()
let id = UUID()
    public init(logger: NeedleTailLogger = NeedleTailLogger("[CallKeyStore]")) {
        print("INTIALIZED KEY MANAGER id \(id)")
        self.logger = logger
    }
    
    // MARK: - SessionIdentityDelegate
    
    public func updateSessionIdentity(_ identity: DoubleRatchetKit.SessionIdentity) async throws {
        // Find the connection identity by searching through all connection identities
        // since they're keyed by connectionId, not session identity UUID
        for (connectionId, var connIdentity) in connectionIdentities {
            if connIdentity.sessionIdentity.id == identity.id {
                connIdentity.sessionIdentity = identity
                connectionIdentities[connectionId] = connIdentity
                logger.log(level: .info, message: "Updated session identity: \(identity.id) for connectionId: \(connectionId)")
                return
            }
        }
        
        // If not found by session identity ID, try by UUID string (for backward compatibility)
        if let connectionIdentity = connectionIdentities[identity.id.uuidString] {
            var updated = connectionIdentity
            updated.sessionIdentity = identity
            connectionIdentities[identity.id.uuidString] = updated
            logger.log(level: .info, message: "Updated session identity: \(identity.id)")
            return
        }

        // Ratchet can emit a late identity update after `removeConnectionIdentity` / `clearAll` during
        // hangup; persisting it would be meaningless, so treat as expected teardown noise (not an error).
        logger.log(
            level: .info,
            message: "Skipping session identity update (no cached connection): \(identity.id)"
        )
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
    
    /// Removes a session identity.
    /// - Parameter id: The session identity ID
    public func removeSessionIdentity(_ id: UUID) {
        connectionIdentities = connectionIdentities.filter { $0.value.sessionIdentity.id != id }
        logger.log(level: .info, message: "Removed session identity: \(id)")
    }
    
    /// Removes a connection identity and any pending ciphertext for a given `connectionId`.
    /// - Parameter connectionId: The connection ID associated with the identity
    public func removeConnectionIdentity(connectionId: String) {
        for key in identityLookupKeys(for: connectionId) {
            connectionIdentities.removeValue(forKey: key)
            pendingCiphertext.removeValue(forKey: key)
        }
        logger.log(level: .info, message: "Removed connection identity and pending ciphertext for connectionId: \(connectionId)")
    }
    
    /// Removes all cached data.
    public func clearAll() {
        connectionLocalIdentity = nil
        connectionIdentities.removeAll()
        pendingCiphertext.removeAll()
        oneTimeKeys.removeAll()
        logger.log(level: .info, message: "Cleared all cached data: \(sessionIdentityCount()) session identities")
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
    public func fetchCallKeyBundle() throws -> ConnectionLocalIdentity {
        guard let connectionIdentity = connectionLocalIdentity else {
            throw RTCErrors.invalidConfiguration("Missing local connection identity")
        }
        return connectionIdentity
    }
    
    public func removeCallKeyBundle() {
        connectionLocalIdentity = nil
    }
    
    /// Retrieves a session identity by id.
    /// - Parameter id: The session identity ID
    /// - Returns: The session identity if found, nil otherwise
    public func fetchConnectionIdentity(connection id: String) throws -> ConnectionSessionIdentity {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        for key in identityLookupKeys(for: trimmed) {
            if let connectionIdentity = connectionIdentities[key] {
                return connectionIdentity
            }
        }

        throw RTCErrors.invalidConfiguration("Missing connection identity for ID: \(trimmed)")
    }

    public func fetchConnectionIdentity(_ id: UUID) -> ConnectionSessionIdentity? {
        connectionIdentities[id.uuidString] ?? connectionIdentities.first { $0.value.sessionIdentity.id == id }?.value
    }

    public func fetchConnectionIdentityByConnectionId(_ connectionId: String) -> ConnectionSessionIdentity? {
        try? fetchConnectionIdentity(connection: connectionId)
    }

    public func fetchSessionIdentity(_ id: UUID) -> SessionIdentity? {
        fetchConnectionIdentity(id)?.sessionIdentity
    }
    
    /// Stores ciphertext for a connection identity.
    ///
    /// If the identity has not been created yet, the ciphertext is stored in a pending cache and
    /// will be attached when ``createRecipientIdentity(connectionId:props:)`` is called.
    /// - Parameters:
    ///   - connectionId: The connection ID
    ///   - ciphertext: The ciphertext to store
    public func storeCiphertext(connectionId: String, ciphertext: Data) {
        if let identityKey = identityLookupKeys(for: connectionId).first(where: { connectionIdentities[$0] != nil }),
           var identity = connectionIdentities[identityKey] {
            identity.ciphertext = ciphertext
            for key in identityLookupKeys(for: connectionId) where connectionIdentities[key] != nil {
                connectionIdentities[key] = identity
            }
            logger.log(level: .info, message: "Stored ciphertext for connection: \(connectionId)")
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
        for key in identityLookupKeys(for: connectionId) {
            if let identity = connectionIdentities[key], let ciphertext = identity.ciphertext {
                return ciphertext
            }
        }
        // Otherwise check pending storage
        return identityLookupKeys(for: connectionId).compactMap { pendingCiphertext[$0] }.first
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
        
        // Create session identity. UUID room ids keep their exact UUID. Human-friendly room
        // stems derive a stable UUID payload for ratchet compatibility.
        let normalizedConnectionId = normalizedSessionConnectionId(connectionId)
        guard !normalizedConnectionId.isEmpty else {
            throw RTCErrors.invalidConfiguration("Invalid empty connectionId")
        }
        let sessionId = normalizedConnectionId.stableUUIDConnectionId
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
    /// If ciphertext arrived before the identity existed, it is attached to the newly created
    /// identity. If an identity already exists for an equivalent connection-id alias, its stored
    /// ciphertext is preserved while the props are replaced.
    ///
    /// That overwrite behavior is intentional for SFU calls: the first identity can be a
    /// provisional room/SFU bootstrap identity, and a later `call_cipher` carries the concrete
    /// peer frame identity that must become authoritative before media keys are derived.
    public func createRecipientIdentity(
        connectionId: String,
        props: SessionIdentity.UnwrappedProps
    ) async throws -> ConnectionSessionIdentity {
        
        // Match sender identity derivation for all supported wrappers.
        let normalizedConnectionId = normalizedSessionConnectionId(connectionId)
        guard !normalizedConnectionId.isEmpty else {
            throw RTCErrors.invalidConfiguration("Invalid empty connectionId")
        }
        let sessionId = normalizedConnectionId.stableUUIDConnectionId
        let lookupKeys = identityLookupKeys(for: connectionId)
        let existingCiphertext = lookupKeys.compactMap { key -> Data? in
            if let ciphertext = connectionIdentities[key]?.ciphertext {
                return ciphertext
            }
            return pendingCiphertext[key]
        }.first

        var identity = ConnectionSessionIdentity(
            connectionId: connectionId,
            symmetricKey: dbsk,
            sessionIdentity: try SessionIdentity(
                id: sessionId,
                props: props,
                symmetricKey: dbsk))

        if let existingCiphertext {
            identity.ciphertext = existingCiphertext
            for key in lookupKeys {
                pendingCiphertext.removeValue(forKey: key)
            }
            logger.log(level: .info, message: "Attached pending ciphertext to newly created identity for connection: \(connectionId)")
        }
        
        for key in lookupKeys {
            connectionIdentities[key] = identity
        }
        logger.log(level: .info, message: "Created new recipient identity \(identity) on connection identity \(connectionId)")
        return identity
    }

    private func normalizedSessionConnectionId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).normalizedUUIDConnectionId.lowercased()
    }

    private func identityLookupKeys(for id: String) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let noChannelPrefix = trimmed.normalizedConnectionId
        let normalized = normalizedSessionConnectionId(trimmed)
        let sessionId = normalized.stableUUIDConnectionId

        var keys: [String] = []
        func append(_ key: String) {
            guard !key.isEmpty, !keys.contains(key) else { return }
            keys.append(key)
        }

        append(trimmed)
        append(trimmed.lowercased())
        append(noChannelPrefix)
        append(noChannelPrefix.lowercased())
        append("#\(noChannelPrefix)")
        append("#\(noChannelPrefix.lowercased())")
        append(normalized)
        append("#\(normalized)")
        append("conf-\(normalized)")
        append("#conf-\(normalized)")
        append(sessionId.uuidString)
        return keys
    }
}
