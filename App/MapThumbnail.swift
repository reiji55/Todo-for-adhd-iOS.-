import MapKit
import SwiftUI
import UIKit

/// A small picture of the map around a place, drawn on the device from its point. Nothing is stored with the
/// data: the picture is kept in the app's cache, so the list and its sync stay as light as before.
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()
    private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]
    private lazy var folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("MapSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    func image(latitude: Double, longitude: Double, size: CGSize, dark: Bool) async -> UIImage? {
        let key = String(format: "%.5f_%.5f_%.0fx%.0f_%@", latitude, longitude, size.width, size.height, dark ? "d" : "l")
        if let image = memory.object(forKey: key as NSString) { return image }
        let file = folder?.appendingPathComponent(key + ".jpg")
        if let file, let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        if let task = running[key] { return await task.value }
        let task = Task<UIImage?, Never> {
            await Self.draw(latitude: latitude, longitude: longitude, size: size, dark: dark)
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString)
            // A small JPEG: a few kilobytes per place.
            if let file, let data = image.jpegData(compressionQuality: 0.7) { try? data.write(to: file, options: .atomic) }
        }
        return image
    }

    private static func draw(latitude: Double, longitude: Double, size: CGSize, dark: Bool) async -> UIImage? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: 600, longitudinalMeters: 600)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        options.pointOfInterestFilter = .excludingAll
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        // The place itself, as a pin in Horme's green.
        let renderer = UIGraphicsImageRenderer(size: size, format: snapshot.image.imageRendererFormat)
        return renderer.image { _ in
            snapshot.image.draw(at: .zero)
            let point = snapshot.point(for: center)
            let radius: CGFloat = min(size.width, size.height) > 100 ? 9 : 6
            let dot = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            UIColor.white.setFill(); dot.fill()
            let inner = UIBezierPath(ovalIn: CGRect(x: point.x - radius + 2.5, y: point.y - radius + 2.5,
                                                   width: (radius - 2.5) * 2, height: (radius - 2.5) * 2))
            UIColor(red: 0.2, green: 0.37, blue: 0.34, alpha: 1).setFill(); inner.fill()
        }
    }
}

/// The map around a place, at the size it is shown.
struct MapThumbnail: View {
    let latitude: Double
    let longitude: Double
    var width: CGFloat = 64
    var height: CGFloat = 64
    var cornerRadius: CGFloat = 10
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(Color.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "map").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(latitude),\(longitude),\(scheme == .dark)") {
            image = await MapSnapshotCache.shared.image(latitude: latitude, longitude: longitude,
                                                        size: CGSize(width: width, height: height), dark: scheme == .dark)
        }
        .accessibilityLabel("地図")
    }
}
