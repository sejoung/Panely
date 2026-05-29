import Foundation

nonisolated protocol KeyValueStoring {
    func data(forKey key: String) -> Data?
    func dictionary(forKey key: String) -> [String: Any]?
    func dictionaryRepresentation() -> [String: Any]
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

nonisolated struct LiveKeyValueStore: KeyValueStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    func dictionaryRepresentation() -> [String: Any] {
        defaults.dictionaryRepresentation()
    }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

extension KeyValueStoring {
    func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}

/// `UserDefaults` natively satisfies every `KeyValueStoring` requirement, so
/// the `loadCodable`/`saveCodable` helpers are inherited from the protocol
/// extension above — there's no need to redeclare identical implementations
/// here (they would just shadow the protocol-extension versions).
extension UserDefaults: KeyValueStoring {}
