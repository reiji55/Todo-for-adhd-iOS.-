import Foundation

public struct NotebookRepository {
    public let url: URL
    public var previousURL: URL { url.appendingPathExtension("previous") }
    public init(url: URL) { self.url = url }
    public func load() throws -> Notebook {
        guard FileManager.default.fileExists(atPath: url.path) else { return Notebook() }
        return try NotebookCodec.decode(Data(contentsOf: url))
    }
    public func save(_ notebook: Notebook) throws {
        let data = try NotebookCodec.encode(notebook)
        // Validate before touching either copy.
        _ = try NotebookCodec.decode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Data(contentsOf: url)
            _ = try NotebookCodec.decode(old)
            try old.write(to: previousURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
    public func recoverPrevious() throws -> Notebook {
        let data = try Data(contentsOf: previousURL)
        let notebook = try NotebookCodec.decode(data)
        // Keep a damaged file for manual recovery instead of discarding it.
        if FileManager.default.fileExists(atPath: url.path) {
            let damaged = url.appendingPathExtension("unreadable-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: url, to: damaged)
        }
        try data.write(to: url, options: .atomic)
        return notebook
    }
}
