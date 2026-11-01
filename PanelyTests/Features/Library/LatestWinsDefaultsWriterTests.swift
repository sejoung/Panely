import Foundation
import Testing
@testable import Panely

struct LatestWinsDefaultsWriterTests {
    /// A slow background encode finishing after the flush at app termination
    /// mustn't put older data back.
    @Test func anOlderGenerationNeverOverwritesANewerOne() {
        let defaults = InMemoryKeyValueStore()
        let writer = LatestWinsDefaultsWriter(defaults: defaults)

        writer.commit(generation: 2) { ["k": Data([2])] }
        writer.commit(generation: 1) { ["k": Data([1])] }

        #expect(defaults.data(forKey: "k") == Data([2]))
        #expect(writer.hasCommitted(1))
        #expect(writer.hasCommitted(2))
        #expect(!writer.hasCommitted(3))
    }

    /// The same race with the older encode already under way: it's only
    /// rejected at commit time, after it has done its work.
    @Test func aCommitOvertakenDuringEncodingIsDropped() {
        let defaults = InMemoryKeyValueStore()
        let writer = LatestWinsDefaultsWriter(defaults: defaults)

        writer.commit(generation: 1) {
            writer.commit(generation: 2) { ["k": Data([2])] }
            return ["k": Data([1])]
        }

        #expect(defaults.data(forKey: "k") == Data([2]))
    }

    /// A failed encode leaves the generation uncommitted, so a flush retries.
    @Test func aFailedEncodeDoesNotCountAsCommitted() {
        let writer = LatestWinsDefaultsWriter(defaults: InMemoryKeyValueStore())

        writer.commit(generation: 1) { nil }

        #expect(!writer.hasCommitted(1))
    }

    @Test func backgroundCommitsReachTheDefaults() async throws {
        let defaults = InMemoryKeyValueStore()
        let writer = LatestWinsDefaultsWriter(defaults: defaults)

        writer.commitInBackground(generation: 1) { ["k": Data([1])] }

        try await waitUntil { writer.hasCommitted(1) }
        #expect(defaults.data(forKey: "k") == Data([1]))
    }
}
