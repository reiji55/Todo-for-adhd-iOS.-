import Foundation

/// A place read from a map link: its name and where it is, when the link says.
public struct MapPlace: Equatable {
    public var name: String
    public var latitude: Double?
    public var longitude: Double?

    public init(name: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.name = name; self.latitude = latitude; self.longitude = longitude
    }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }
}

/// Reads Google Maps and Apple Maps links. Short links (maps.app.goo.gl) say nothing until followed; the share
/// extension follows them and reads the full link they lead to.
public enum MapLink {
    /// Hosts whose links are places on a map.
    public static func isMap(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("maps.apple") || host.hasPrefix("maps.google") || host == "maps.app.goo.gl"
            || (host.hasSuffix("google.com") && url.path.hasPrefix("/maps"))
            || (host.hasSuffix("google.co.jp") && url.path.hasPrefix("/maps"))
            || (host == "goo.gl" && url.path.hasPrefix("/maps"))
    }

    /// A short link that has to be followed before it says anything.
    public static func isShort(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "maps.app.goo.gl" || (host == "goo.gl" && url.path.hasPrefix("/maps"))
    }

    /// The place a full map link names, or nil when it names neither a place nor a point.
    public static func parse(_ url: URL) -> MapPlace? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // A Google consent page carries the real link in `continue`.
        if let next = value("continue"), let inner = URL(string: next), inner != url, isMap(inner) {
            return parse(inner)
        }

        var name = ""
        var point: (Double, Double)?

        // Google: /maps/place/<name>/@lat,lng,zoom/data=...!3d<lat>!4d<lng>
        let path = url.path
        if let range = path.range(of: "/place/") {
            let rest = path[range.upperBound...]
            let segment = rest.split(separator: "/").first.map(String.init) ?? ""
            name = decoded(segment)
        }
        let whole = url.absoluteString
        if let exact = firstPair(in: whole, pattern: "!3d(-?[0-9]+(?:\\.[0-9]+)?)!4d(-?[0-9]+(?:\\.[0-9]+)?)") {
            point = exact
        } else if let center = firstPair(in: whole, pattern: "@(-?[0-9]+(?:\\.[0-9]+)?),(-?[0-9]+(?:\\.[0-9]+)?)") {
            point = center
        }

        // Search links and Apple Maps: q / query / name / address, ll / coordinate / sll.
        for key in ["q", "query", "name", "address", "daddr"] {
            guard let text = value(key) else { continue }
            if let pair = pair(text) {
                point = point ?? pair
            } else if name.isEmpty {
                name = decoded(text)
            }
        }
        for key in ["ll", "coordinate", "sll"] {
            if point == nil, let text = value(key), let pair = pair(text) { point = pair }
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || point != nil else { return nil }
        return MapPlace(name: name, latitude: point?.0, longitude: point?.1)
    }

    /// "35.68,139.76" as a point on Earth.
    static func pair(_ text: String) -> (Double, Double)? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]),
              abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        return (lat, lng)
    }

    private static func firstPair(in text: String, pattern: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
              let lat = Double(text[a]), let lng = Double(text[b]), abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        return (lat, lng)
    }

    private static func decoded(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return (spaced.removingPercentEncoding ?? spaced).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
