//
//  AndroidMediaProjectionIntent.swift
//  pqs-rtc
//
//  Copyright (c) 2025 NeedleTails Organization.
//
//  This project is licensed under the MIT License.
//
//  See the LICENSE file for more information.
//

import Foundation

#if os(Android)
/// Holds MediaProjection permission state outside actor isolation so Skip’s JNI `Task` hop does
/// not need to send non-`Sendable` references across the actor boundary.
final class AndroidMediaProjectionPermissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResultCode: Int?
    private var storedIntent: Any?

    func store(resultCode: Int, intent: Any) {
        lock.lock()
        storedResultCode = resultCode
        storedIntent = intent
        lock.unlock()
    }

    func readSnapshot() -> (resultCode: Int, intent: Any)? {
        lock.lock()
        defer { lock.unlock() }
        guard let rc = storedResultCode, let intent = storedIntent else { return nil }
        return (rc, intent)
    }
}
#else
private enum AndroidMediaProjectionIntentFileNoOp {}
#endif
