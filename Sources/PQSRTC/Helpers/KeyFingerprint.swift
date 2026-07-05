//
//  KeyFingerprint.swift
//  pqs-rtc
//
//  Copyright (c) 2026 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//
//  Diagnostic fingerprints for signaling identity key material.
//
//  Only PUBLIC key bytes are hashed and only a short digest prefix is emitted,
//  so log lines can prove whether two sides hold the same identity without
//  leaking any key material.
//

import Foundation
import Crypto
import DoubleRatchetKit

enum KeyFingerprint {

    /// Crypto-wiring diagnostics are opt-in: set `SFU_DEBUG_CRYPTO_WIRING` in the process
    /// environment to enable the fingerprint log lines. Off by default so production logs
    /// carry no identity-correlation material.
    static let isEnabled: Bool = {
        guard let value = ProcessInfo.processInfo.environment["SFU_DEBUG_CRYPTO_WIRING"] else {
            return false
        }
        return !["", "0", "false", "no"].contains(value.lowercased())
    }()

    /// Stable, non-sensitive fingerprint of an identity's public key bundle.
    ///
    /// Hashes long-term, signing, one-time, and ML-KEM *public* keys plus their key ids and
    /// returns the first 8 bytes of the SHA-256 digest as hex. Never touches private keys.
    static func props(_ props: SessionIdentity.UnwrappedProps?) -> String {
        guard let props else { return "<nil>" }
        var input = Data()
        input.append(props.longTermPublicKey)
        input.append(props.signingPublicKey)
        if let oneTime = props.oneTimePublicKey {
            input.append(contentsOf: Array(oneTime.id.uuidString.utf8))
            input.append(oneTime.rawRepresentation)
        }
        input.append(contentsOf: Array(props.mlKEMPublicKey.id.uuidString.utf8))
        input.append(props.mlKEMPublicKey.rawRepresentation)
        let digest = SHA256.hash(data: input)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of the public bundle advertised by a local identity.
    ///
    /// Uses the identity's own stored props (public halves), so it is directly comparable
    /// with the fingerprint a peer logs for the props it received from us.
    static func localIdentity(_ identity: ConnectionLocalIdentity) async -> String {
        let props = await identity.sessionIdentity.props(symmetricKey: identity.symmetricKey)
        return self.props(props)
    }
}
