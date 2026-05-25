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
//  Pagination and rate-limiting live entirely inside the enclave.
//  The client kicks one detached job, then polls migrate-status
//  every few seconds until the coordinator reports a terminal
//  state. Each poll tick returns the running totals so the loop
//  takes a snapshot of the latest response rather than accumulating
//  deltas — the enclave already owns the global counter.
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

    /// Run the enclave-driven migration. Kicks off the detached
    /// migration job, then polls migrate-status until the
    /// coordinator reaches a terminal state (`partial:false` or
    /// `status == "completed" | "failed"`) or the local poll
    /// deadline elapses. Cancelling the app mid-poll only stops the
    /// local loop — the enclave job keeps draining and the next
    /// launch resumes polling against the same coordinator entry.
    static func run() async -> MigrationReport {
        let targetKeyB64: String
        do {
            targetKeyB64 = try CEKEncoding.requirePrimaryKeyB64()
        } catch {
            return .empty
        }
        let keys = CEKEncoding.migrationKeys()
        let startedAt = Date()
        let pollInterval = Constants.Sync.migrationPollIntervalSeconds
        let pollTimeout = Constants.Sync.migrationPollTimeoutSeconds

        var lastResponse: EnclaveMigrateAllResponse?
        do {
            lastResponse = try await SyncEnclaveAPI.migrateAll(
                EnclaveMigrateAllRequest(
                    keys: keys,
                    target: EnclaveMigrateRequestTarget(key: targetKeyB64)
                )
            )
        } catch {
            #if DEBUG
            print("[LegacyBlobMigration] migrate-all kickoff failed: \(error)")
            #endif
            return .empty
        }

        while shouldKeepPolling(lastResponse) {
            if Date().timeIntervalSince(startedAt) > pollTimeout {
                #if DEBUG
                print("[LegacyBlobMigration] poll timeout — bailing")
                #endif
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            do {
                lastResponse = try await SyncEnclaveAPI.migrateStatus()
            } catch {
                #if DEBUG
                print("[LegacyBlobMigration] migrate-status poll failed: \(error)")
                #endif
                break
            }
        }

        let snapshot = lastResponse.map { snapshotScopes($0.scopes) } ?? [:]
        var report = toReport(snapshot)
        if lastResponse?.partial != false {
            report.fullyMigrated = false
        }
        // Freshly-keyed user with nothing to migrate — Layer C must
        // still be allowed to clear the alternative-keys list even
        // though no scopes were touched.
        if snapshot.isEmpty {
            if let last = lastResponse, !last.partial {
                return MigrationReport(
                    scopes: [],
                    totalMigrated: 0,
                    totalRemaining: 0,
                    totalBlocked: 0,
                    fullyMigrated: true
                )
            }
            return .empty
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

    private static func shouldKeepPolling(_ resp: EnclaveMigrateAllResponse?) -> Bool {
        guard let resp = resp else { return false }
        if !resp.partial { return false }
        // Older enclave builds that pre-date the async coordinator
        // omit the status field; treat absence as "still running"
        // so the loop respects the partial flag.
        let status = resp.status ?? "running"
        return status == "running"
    }

    /// Convert the latest response's scopes into per-scope results.
    /// The async coordinator already aggregates totals server-side,
    /// so each tick supersedes the previous one — the client
    /// snapshots rather than accumulates.
    private static func snapshotScopes(
        _ scopes: [EnclaveMigrateAllScopeReport]
    ) -> [SyncScope: ScopeMigrationResult] {
        var out: [SyncScope: ScopeMigrationResult] = [:]
        for s in scopes {
            out[s.scope] = ScopeMigrationResult(
                scope: s.scope,
                migrated: s.migrated,
                remaining: s.retryableRemaining,
                blocked: s.blocked ?? []
            )
        }
        return out
    }

    private static func toReport(_ scopes: [SyncScope: ScopeMigrationResult]) -> MigrationReport {
        let list = Array(scopes.values)
        let totalMigrated = list.reduce(0) { $0 + $1.migrated }
        let totalRemaining = list.reduce(0) { $0 + $1.remaining }
        let totalBlocked = list.reduce(0) { $0 + $1.blocked.count }
        // Default to false for an empty report so a pass that bailed
        // before recording any scopes (e.g. every migrate-all call
        // threw) is never treated as a clean drain. `run()` flips
        // this to true only when the enclave actually returned a
        // non-partial response with nothing left to migrate.
        return MigrationReport(
            scopes: list,
            totalMigrated: totalMigrated,
            totalRemaining: totalRemaining,
            totalBlocked: totalBlocked,
            fullyMigrated: !list.isEmpty && totalRemaining == 0 && totalBlocked == 0
        )
    }
}
