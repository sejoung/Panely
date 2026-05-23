import Foundation

extension UserDefaults {
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
