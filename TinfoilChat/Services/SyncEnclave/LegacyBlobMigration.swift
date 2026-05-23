//
//  LegacyBlobMigration.swift
//  TinfoilChat
//
//  Drives the enclave's `/v1/blobs/migrate-all` endpoint to re-seal
//  every legacy (v0/v1) row under the current primary CEK. Mirrors
//  the webapp's `services/cloud/legacy-blob-migration.ts`.
//
//  Without this loop, dropping `alternative` decryption keys would
//  strand any row that still needs an old key to unseal.
//
//  Pagination lives entirely inside the enclave. The client makes
//  one call; if the enclave hits its wall-clock budget before
//  draining every scope it sets `partial: true` and we re-invoke
//  once to pick up where it left off.
//

import Foundation

struct ScopeMigrationResult {
    let scope: SyncScope
    var migrated: Int
    var remaining: Int
    var blocked: [String]
}

struct MigrationReport {
    var scopes: [ScopeMigrationResult]
    var totalMigrated: Int
    var totalRemaining: Int
    var totalBlocked: Int
    /// True when every observed scope reports `remaining === 0` and
    /// the enclave is no longer reporting partial work. Callers use
    /// this flag to decide whether it is safe to drop alternative
    /// decryption keys.
    var fullyMigrated: Bool

    static let empty = MigrationReport(
        scopes: [],
        totalMigrated: 0,
        totalRemaining: 0,
        totalBlocked: 0,
        fullyMigrated: false
    )
}

enum LegacyBlobMigration {
    private static let maxPasses = 2

    /// Run the enclave-driven migration. Re-invokes the migrate-all
    /// endpoint until it reports `partial: false` or the pass budget
    /// is exhausted.
    static func run() async -> MigrationReport {
        let targetKeyB64: String
        do {
            targetKeyB64 = try CEKEncoding.requirePrimaryKeyB64()
        } catch {
            return .empty
        }
        let keys = CEKEncoding.migrationKeys()

        var accumulator: [SyncScope: ScopeMigrationResult] = [:]
        var lastResponse: EnclaveMigrateAllResponse? = nil

        for _ in 0..<maxPasses {
            do {
                let resp = try await SyncEnclaveAPI.migrateAll(
                    EnclaveMigrateAllRequest(
                        keys: keys,
                        target: EnclaveMigrateRequestTarget(key: targetKeyB64)
                    )
                )
                lastResponse = resp
                merge(scopes: resp.scopes, into: &accumulator)
                if !resp.partial { break }
            } catch {
                #if DEBUG
                print("[LegacyBlobMigration] migrate-all failed: \(error)")
                #endif
                break
            }
        }

        var report = toReport(accumulator)
        if lastResponse?.partial == true {
            report.fullyMigrated = false
        }
        if accumulator.isEmpty {
            if let last = lastResponse, !last.partial {
                report.fullyMigrated = true
            }
        }
        return report
    }

    /// Drop the local alternative-keys list once the migration
    /// report confirms every observed row has been re-sealed.
    @discardableResult
    static func finalizeAlternativesIfMigrated(_ report: MigrationReport) -> Bool {
        guard report.fullyMigrated else { return false }
        EncryptionService.shared.clearFallbackKeys()
        return true
    }

    static func runAndFinalize() async -> MigrationReport {
        let report = await run()
        _ = finalizeAlternativesIfMigrated(report)
        return report
    }

    // MARK: - Private

    private static func merge(
        scopes: [EnclaveMigrateAllScopeReport],
        into acc: inout [SyncScope: ScopeMigrationResult]
    ) {
        for s in scopes {
            var prev = acc[s.scope] ?? ScopeMigrationResult(
                scope: s.scope,
                migrated: 0,
                remaining: 0,
                blocked: []
            )
            prev.migrated += s.migrated
            prev.remaining = s.retryableRemaining
            if let blocked = s.blocked {
                prev.blocked.append(contentsOf: blocked)
            }
            acc[s.scope] = prev
        }
    }

    private static func toReport(_ scopes: [SyncScope: ScopeMigrationResult]) -> MigrationReport {
        let list = Array(scopes.values)
        let totalMigrated = list.reduce(0) { $0 + $1.migrated }
        let totalRemaining = list.reduce(0) { $0 + $1.remaining }
        let totalBlocked = list.reduce(0) { $0 + $1.blocked.count }
        return MigrationReport(
            scopes: list,
            totalMigrated: totalMigrated,
            totalRemaining: totalRemaining,
            totalBlocked: totalBlocked,
            fullyMigrated: totalRemaining == 0 && totalBlocked == 0
        )
    }
}
