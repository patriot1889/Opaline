import XCTest
@testable import OpalineTV

final class StorageTests: XCTestCase {
    func testCacheEvictionRemovesOldestFilesAndToleratesMissingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old")
        let recent = directory.appendingPathComponent("recent")
        try Data(repeating: 1, count: 100).write(to: old)
        try Data(repeating: 2, count: 100).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        CacheStorage.trim(directory, maximumBytes: 150)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        CacheStorage.trim(directory.appendingPathComponent("missing"), maximumBytes: 0)
    }

    func testImageCacheRecreatesEvictedDirectory() throws {
        let cache = ImageDiskCache()
        let url = URL(string: "https://fixture.invalid/thumbnail.jpg")!
        let data = Data([1, 2, 3])
        cache.store(data: data, for: url)
        let location = try XCTUnwrap(cache.fileURL(for: url))
        try FileManager.default.removeItem(at: location.deletingLastPathComponent())
        XCTAssertNil(cache.fileURL(for: url))
        cache.store(data: data, for: url)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cache.fileURL(for: url))), data)
    }

    func testRecentSearchesRemainBoundedAndDeduplicated() {
        let name = "OpalineTVTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = SearchHistoryStore(defaults: defaults)
        for index in 0..<30 { history.add("Query \(index)") }
        history.add("query 29")
        XCTAssertEqual(history.queries.count, 20)
        XCTAssertEqual(history.queries.first, "query 29")
        XCTAssertEqual(SearchHistoryStore(defaults: defaults).queries.count, 20)
    }
}
