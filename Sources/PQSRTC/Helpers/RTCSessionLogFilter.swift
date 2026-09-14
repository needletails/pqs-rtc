//
//  RTCSessionLogFilter.swift
//  pqs-rtc
//
//  Filter for loggers created as stored-property defaults before ``RTCSession``
//  can apply its `logLevel`. Do not change NeedleTailLogger's default.
//

import NeedleTailLogger

enum RTCSessionLogFilter {
    /// Set e.g. `.trace` to force more logging in a local build. Leave `nil` for DEBUG / release.
    static let overrideLevel: Level? = nil

    static var defaultLevel: Level {
#if DEBUG
        .debug
#else
        .info
#endif
    }

    static var constructionLevel: Level {
        resolved(sessionLogLevel: defaultLevel)
    }

    static func resolved(sessionLogLevel: Level) -> Level {
        overrideLevel ?? sessionLogLevel
    }
}
