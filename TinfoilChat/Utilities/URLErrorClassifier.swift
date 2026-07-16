//
//  URLErrorClassifier.swift
//  TinfoilChat
//
//  Single source of truth for classifying NSURLErrorDomain failures
//  as connectivity losses. URLError bridges to NSError under
//  NSURLErrorDomain, so one NSError check covers both forms.
//

import Foundation

enum URLErrorClassifier {
    /// URLError codes that represent a lost or unavailable network
    /// connection. Cancellation, malformed requests, TLS/cert failures,
    /// and request-body stream exhaustion share NSURLErrorDomain but are
    /// not connection losses, so they are excluded here. Retry-oriented
    /// consumers extend this set (see
    /// `EnclaveErrorRecovery.isTransientNetwork`).
    static let connectivityErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorDNSLookupFailed,
        NSURLErrorResourceUnavailable,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
    ]

    static func isConnectivityFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && connectivityErrorCodes.contains(nsError.code)
    }
}
