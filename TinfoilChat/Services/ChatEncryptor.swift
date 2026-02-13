//
//  ChatEncryptor.swift
//  TinfoilChat
//
//  Protocol for encrypting/decrypting raw data.
//  Implemented by DeviceEncryptionService (local chats) and EncryptionService (cloud chats).
//

import Foundation

protocol ChatEncryptor: Sendable {
    /// Encrypt raw data bytes, returning an EncryptedData envelope.
    func encryptData(_ data: Data) async throws -> EncryptedData

    /// Decrypt an EncryptedData envelope, returning the original raw data bytes.
    func decryptData(_ encrypted: EncryptedData) async throws -> Data
}
