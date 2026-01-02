//
//  ConnectionLocalIdentity.swift
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

import DoubleRatchetKit

/// Cryptographic identity material generated locally for a single connection.
///
/// `RTCSession`/`KeyManager` use this to persist the local party's key material
/// needed to establish and advance pairwise ratchets.
public struct ConnectionLocalIdentity: Sendable {
    /// Application-level connection identifier used for routing.
    public let connectionId: String
    /// The local party's asymmetric key material (ratchet identity keys).
    public let localKeys: LocalKeys
    /// Symmetric key associated with this connection (used by the ratchet implementation).
    public let symmetricKey: SymmetricKey
    /// The local party's session identity bundle.
    public let sessionIdentity: SessionIdentity
    
    public init(
        connectionId: String,
        localKeys: LocalKeys,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity
    ) {
        self.connectionId = connectionId
        self.localKeys = localKeys
        self.symmetricKey = symmetricKey
        self.sessionIdentity = sessionIdentity
    }
}
