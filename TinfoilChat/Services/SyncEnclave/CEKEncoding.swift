//
//  CEKEncoding.swift
//  TinfoilChat
//
//  CEK encoding helpers shared by every enclave-adapter. The
//  `EncryptionService` stores keys as `key_<base36>` strings; the
//  enclave wire wants raw 32-byte CEKs base64-encoded. Centralizing
//  the conversion here keeps the adapters honest.
//

import Foundation

enum CEKEncoding {

    /// Encode the current primary CEK as base64 for the enclave wire.
    /// Throws when no primary key is loaded in the keychain.
    static func requirePrimaryKeyB64() throws -> String {
        let bytes = try EncryptionService.shared.getKeyBytesOrThrow()
        return bytes.base64EncodedString()
    }

    /// Build the `keys` array for the steady-state read path: only the
    /// caller's current primary CEK. v2 rows are sealed under the
    /// primary and decrypt cleanly here. Anything that doesn't decrypt
    /// is treated as UNKNOWN_KEY by the enclave instead of silently
    /// trying historical keys; migration sweeps are the only path that
    /// needs alternatives. Returns `nil` instead of throwing when no
    /// key is loaded, for callers that opportunistically attempt to
    /// read without a key (sign-out cleanup, optional refreshes).
    static func pullKeysIfAvailable() -> [EnclavePullKey]? {
        guard let primary = try? requirePrimaryKeyB64() else { return nil }
        return [EnclavePullKey(key: primary)]
    }

    /// Keys to probe existing cloud data with when validating the
    /// currently-loaded primary key. When the loaded primary is one of
    /// the device's persisted keys, probe with the full persisted set:
    /// historical alternatives belong to the same user and the
    /// migration sweep can rewrap rows sealed under them. When the
    /// loaded primary is a newly staged key that has not been persisted
    /// yet, probe with the staged set alone — a leftover persisted key
    /// must not vouch for a different key that cannot actually unlock
    /// the data, and a fresh device with no persisted keys must still
    /// get its staged key probed.
    static func keyValidationProbeKeys() -> [EnclavePullKey] {
        let service = EncryptionService.shared
        let active = service.getActiveKeys()
        guard let primary = active.primary,
              let primaryBytes = try? service.getAlternativeKeyBytes(primary) else { return [] }
        let primaryB64 = primaryBytes.base64EncodedString()

        var out = [EnclavePullKey(key: primaryB64)]
        var seen: Set<String> = [primaryB64]
        func add(_ b64: String) {
            guard seen.insert(b64).inserted else { return }
            out.append(EnclavePullKey(key: b64))
        }

        let persisted = migrationKeys()
        if persisted.contains(where: { $0.key == primaryB64 }) {
            for entry in persisted { add(entry.key) }
        }
        for alt in active.alternatives {
            guard let bytes = try? service.getAlternativeKeyBytes(alt) else { continue }
            add(bytes.base64EncodedString())
        }
        return out
    }

    /// Build the `keys` array for the migration path: primary first,
    /// then every alternative (history) key the local service still has
    /// on file, base64-encoded. The enclave tries each in turn when
    /// unsealing legacy v0/v1 blobs and uses `keys[0]` as the rewrap
    /// target. Once the one-shot sweep reports `fullyMigrated`, the
    /// alternatives are cleared from local state and this helper
    /// collapses to the same shape as `pullKeysIfAvailable()`.
    /// Returns an empty array when the primary is missing or
    /// unreadable so callers never see alternatives without the
    /// primary at `keys[0]`.
    static func migrationKeys() -> [EnclavePullKey] {
        let allKeys = EncryptionService.shared.getAllKeys()
        guard let primary = allKeys.primary,
              let primaryBytes = try? EncryptionService.shared.getAlternativeKeyBytes(primary) else {
            return []
        }
        var out = [EnclavePullKey(key: primaryBytes.base64EncodedString())]
        for alt in allKeys.alternatives {
            if alt == primary { continue }
            guard let bytes = try? EncryptionService.shared.getAlternativeKeyBytes(alt) else { continue }
            out.append(EnclavePullKey(key: bytes.base64EncodedString()))
        }
        return out
    }
}
