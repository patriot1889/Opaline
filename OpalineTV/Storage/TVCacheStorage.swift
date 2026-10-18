import Foundation

/// File protection is an iOS concern; TV cache contents are disposable.
enum CacheStorage {
    private struct Entry {
        let url: URL
        let size: Int
        let modified: Date
    }

    static var writeOptions: Data.WritingOptions {
        .atomic
    }

    static func trim(_ directory: URL, maximumBytes: Int) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else {
            return
        }
        let files = urls.compactMap { url -> Entry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                return nil
            }
            return Entry(
                url: url,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modified < $1.modified }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > maximumBytes {
            if (try? manager.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
    }
}
