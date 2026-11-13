import Foundation

/// Follows a short map link (maps.app.goo.gl) to the full link it leads to and reads the place there. Every
/// address it passes through is tried, since the last one can be a consent or app page.
enum MapResolver {
    static func place(for url: URL) async -> MapPlace? {
        if let place = MapLink.parse(url), !MapLink.isShort(url) { return place }
        guard MapLink.isShort(url) else { return nil }
        let recorder = RedirectRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        let final = try? await session.data(for: request).1.url
        let visited = recorder.visited + [final].compactMap { $0 }
        // The fullest answer wins: a name and a point, then a point, then a name.
        let places = visited.compactMap(MapLink.parse)
        return places.first { $0.hasCoordinate && !$0.name.isEmpty }
            ?? places.first { $0.hasCoordinate } ?? places.first
    }
}

private final class RedirectRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var visited: [URL] { lock.lock(); defer { lock.unlock() }; return urls }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        if let url = request.url { lock.lock(); urls.append(url); lock.unlock() }
        return request
    }
}
