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
/// Holds the MediaProjection consent result code outside actor isolation so Skip’s JNI `Task`
/// hop does not need to send non-`Sendable` references across the actor boundary.
///
/// Only the `Int` result code lives here. The consent `Intent` is an arbitrary Java object that
/// SkipBridge cannot bridge into Swift; it stays on the Kotlin side in
/// `AndroidMediaProjectionResultHolder` and is consumed directly by the screen capturer.
final class AndroidMediaProjectionPermissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResultCode: Int?

    func store(resultCode: Int) {
        lock.lock()
        storedResultCode = resultCode
        lock.unlock()
    }

    func readResultCode() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedResultCode
    }

    func clear() {
        lock.lock()
        storedResultCode = nil
        lock.unlock()
    }
}
#else
private enum AndroidMediaProjectionIntentFileNoOp {}
#endif
