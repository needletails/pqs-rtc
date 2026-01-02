//
//  ConnectionSessionIdentity.swift
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

/// Cryptographic identity material for a remote party, scoped to a connection.
///
/// This type also optionally carries a pending ciphertext blob that arrived before
/// the full identity record was created (useful when inbound messages race identity setup).
public struct ConnectionSessionIdentity: Sendable {
    /// Application-level connection identifier used for routing.
    public let connectionId: String
    /// Symmetric key associated with this connection (used by the ratchet implementation).
    public let symmetricKey: SymmetricKey
    /// Remote party session identity (ratchet state and public identity props).
    public var sessionIdentity: SessionIdentity
    /// Optional ciphertext buffered until the session identity is ready.
    public var ciphertext: Data?
    
    public init(
        connectionId: String,
        symmetricKey: SymmetricKey,
        sessionIdentity: SessionIdentity,
        ciphertext: Data? = nil
    ) {
        self.connectionId = connectionId
        self.symmetricKey = symmetricKey
        self.sessionIdentity = sessionIdentity
        self.ciphertext = ciphertext
    }
}
