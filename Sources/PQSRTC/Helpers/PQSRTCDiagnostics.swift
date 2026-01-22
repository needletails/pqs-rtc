//
//  PQSRTCDiagnostics.swift
//  pqs-rtc
//
//  Created by GPT-5.2 on 1/22/26.
//
//  This project is licensed under the MIT License.
//

import Foundation

/// Global diagnostics toggles for PQSRTC.
///
/// This is intentionally a simple, thread-safe switch that the host app can flip at runtime.
/// Use it to enable expensive debug telemetry only when investigating critical issues.
public enum PQSRTCDiagnostics {
    private static let lock = NSLock()
    private static var _criticalBugLoggingEnabled: Bool = {
        // Optional env-based default (useful for CI / TestFlight repros).
        // Set `PQSRTC_CRITICAL_BUG_LOGGING=1` to enable by default.
        let env = ProcessInfo.processInfo.environment["PQSRTC_CRITICAL_BUG_LOGGING"] ?? "0"
        return env == "1" || env.lowercased() == "true"
    }()
    
    /// When true, PQSRTC may run additional background telemetry loops and emit high-volume logs.
    ///
    /// Default: false.
    public static var criticalBugLoggingEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _criticalBugLoggingEnabled
        }
        set {
            lock.lock()
            _criticalBugLoggingEnabled = newValue
            lock.unlock()
        }
    }
}

