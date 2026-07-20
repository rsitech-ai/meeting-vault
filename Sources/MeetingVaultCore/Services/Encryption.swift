import CryptoKit
import Darwin
import Foundation
import Security

public enum EncryptionError: Error, Equatable {
    case invalidKeyLength(Int)
    case unsupportedAlgorithm(String)
    case sealedBoxCreationFailed
    case keychainReadFailed(Int32)
    case keychainWriteFailed(Int32)
}

public struct EncryptedBlob: Codable, Equatable, Sendable {
    public var algorithm: String
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data

    public init(
        algorithm: String = AESGCMDataVault.algorithm,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.algorithm = algorithm
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public protocol SymmetricKeyProvider: Sendable {
    func loadKey() throws -> SymmetricKey
}

public struct InMemorySymmetricKeyProvider: SymmetricKeyProvider {
    private let keyData: Data

    public init(keyData: Data) {
        self.keyData = keyData
    }

    public func loadKey() throws -> SymmetricKey {
        guard keyData.count == 32 else {
            throw EncryptionError.invalidKeyLength(keyData.count)
        }
        return SymmetricKey(data: keyData)
    }
}

public struct FileBackedSymmetricKeyProvider: SymmetricKeyProvider {
    private let keyFileURL: URL

    public init(keyFileURL: URL) {
        self.keyFileURL = keyFileURL
    }

    public func loadKey() throws -> SymmetricKey {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: keyFileURL.path) {
            return try readExistingKey(retryIfIncomplete: true)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let parentURL = keyFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parentURL.path
        )
        let descriptor = Darwin.open(keyFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if descriptor == -1, errno == EEXIST {
            return try readExistingKey(retryIfIncomplete: true)
        }
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try keyData.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, baseAddress.advanced(by: written), bytes.count - written)
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    written += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
            guard Darwin.close(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(keyFileURL.path)
            throw error
        }
        return key
    }

    private func readExistingKey(retryIfIncomplete: Bool = false) throws -> SymmetricKey {
        let attempts = retryIfIncomplete ? 100 : 1
        for attempt in 0..<attempts {
            if let existing = try? Data(contentsOf: keyFileURL), existing.count == 32 {
                return SymmetricKey(data: existing)
            }
            if attempt + 1 < attempts {
                usleep(10_000)
            }
        }
        let existing = try Data(contentsOf: keyFileURL)
        throw EncryptionError.invalidKeyLength(existing.count)
    }
}

public protocol KeychainStoring: AnyObject, Sendable {
    func load(service: String, account: String) throws -> Data?
    func save(_ data: Data, service: String, account: String) throws
}

public final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public var savedItemCount: Int {
        lock.withLock { items.count }
    }

    public func load(service: String, account: String) throws -> Data? {
        lock.withLock { items[key(service: service, account: account)] }
    }

    public func save(_ data: Data, service: String, account: String) throws {
        lock.withLock {
            items[key(service: service, account: account)] = data
        }
    }

    private func key(service: String, account: String) -> String {
        "\(service):\(account)"
    }
}

public final class SystemKeychainStore: KeychainStoring, @unchecked Sendable {
    public init(readTimeoutSeconds: TimeInterval = 1.5) {
        _ = readTimeoutSeconds
    }

    public func load(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw EncryptionError.keychainReadFailed(status)
        }
        return rawResult as? Data
    }

    public func save(_ data: Data, service: String, account: String) throws {
        let query = Self.nonInteractiveQuery(service: service, account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw EncryptionError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EncryptionError.keychainWriteFailed(addStatus)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        Self.nonInteractiveQuery(service: service, account: account)
    }

    static func nonInteractiveQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
    }
}

public struct KeychainSymmetricKeyProvider: SymmetricKeyProvider {
    private let service: String
    private let account: String
    private let keychain: KeychainStoring

    public init(
        service: String = "com.andrzej.MeetingVault",
        account: String = "install-master-key",
        keychain: KeychainStoring = SystemKeychainStore()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func loadKey() throws -> SymmetricKey {
        if let existing = try keychain.load(service: service, account: account) {
            guard existing.count == 32 else {
                throw EncryptionError.invalidKeyLength(existing.count)
            }
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keychain.save(keyData, service: service, account: account)
        return key
    }
}

public struct AESGCMDataVault: Sendable {
    public static let algorithm = "AES.GCM.256.v1"

    private let keyProvider: SymmetricKeyProvider

    public init(keyProvider: SymmetricKeyProvider) {
        self.keyProvider = keyProvider
    }

    public func seal(_ data: Data, purpose: String) throws -> EncryptedBlob {
        let key = try keyProvider.loadKey()
        let sealedBox = try AES.GCM.seal(
            data,
            using: key,
            authenticating: authenticationData(for: purpose)
        )

        return EncryptedBlob(
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0) },
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    public func open(_ blob: EncryptedBlob, purpose: String) throws -> Data {
        guard blob.algorithm == Self.algorithm else {
            throw EncryptionError.unsupportedAlgorithm(blob.algorithm)
        }

        guard let nonce = try? AES.GCM.Nonce(data: blob.nonce) else {
            throw EncryptionError.sealedBoxCreationFailed
        }

        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: blob.ciphertext,
            tag: blob.tag
        )

        return try AES.GCM.open(
            sealedBox,
            using: keyProvider.loadKey(),
            authenticating: authenticationData(for: purpose)
        )
    }

    private func authenticationData(for purpose: String) -> Data {
        Data("MeetingVault:\(purpose)".utf8)
    }
}
