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

extension UserDefaults: KeyValueStoring {
    /// JSON-decode a value previously written via `saveCodable(_:forKey:)`.
    /// Returns `nil` when nothing is stored or the stored bytes can't be
    /// decoded as `T` (forward-compat: a model field rename leaves the
    /// caller with an empty default instead of crashing).
    func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// JSON-encode `value` and persist under `key`. Silently no-ops on
    /// encoding failure — every `Codable` we ship currently round-trips, so a
    /// failure means a real bug (caller can't recover from `Encodable` throwing
    /// anyway), and the alternative would be every store handling that error
    /// the same way.
    func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}
