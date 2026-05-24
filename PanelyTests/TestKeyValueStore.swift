import Foundation
@testable import Panely

final class InMemoryKeyValueStore: KeyValueStoring, @unchecked Sendable {
    private var storage: [String: Any]

    init(_ storage: [String: Any] = [:]) {
        self.storage = storage
    }

    func data(forKey key: String) -> Data? {
        storage[key] as? Data
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        storage[key] as? [String: Any]
    }

    func dictionaryRepresentation() -> [String: Any] {
        storage
    }

    func set(_ value: Any?, forKey key: String) {
        storage[key] = value
    }

    func removeObject(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}
