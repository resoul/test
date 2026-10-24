import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Nodes
import NodesRender
import ThemeCore
import UIKit

struct FeedPost: Identifiable, Sendable {
    let id: Int
    let revision: Int
    let title: String
    let body: String
    let place: String
    let date: String
    let imageURL: URL
    let likes: Int

    var accessibilityTitle: String { "Запись \(id + 1). \(title)" }
}

enum FeedData {
    static let titles = [
        "Там, где начинается утро", "Маршрут без спешки", "Озеро за следующим поворотом",
        "Маленькие находки большой дороги", "Один день вдали от города", "Остаться ещё на час",
        "Дорога между соснами", "Свет, который хочется запомнить",
    ]
    static let places = [
        "Казбеги, Грузия", "Доломиты, Италия", "Озеро Блед, Словения", "Сванетия, Грузия",
        "Тоскана, Италия", "Алтай, Россия",
    ]
    static let paragraphs = [
        "Мы вышли до рассвета, когда город ещё спал. На тропе пахло сосной, а за поворотом открылась долина — тихая, просторная и совсем не похожая на фотографии.",
        "Самое интересное обычно случается между точками на карте. Небольшое кафе, разговор с незнакомцем, лишний километр пешком. В этот раз мы просто позволили дороге выбирать за нас.",
        "На берегу мы устроили короткую остановку: горячий чай, хлеб из местной пекарни и ни одного уведомления. Иногда для хорошего дня действительно нужно совсем немного.",
        "Для тех, кто соберётся повторить маршрут: возьмите воду и лёгкую куртку. Последний подъём круче, чем кажется, зато наверху хочется забыть о времени и остаться до вечера.",
    ]

    static func posts(count: Int, revision: Int) -> [FeedPost] {
        (0..<count).map { index in
            let name = "landscape-\(index % 24)"
            guard
                let url = Bundle.main.url(forResource: name, withExtension: "jpg")
                    ?? Bundle.main.url(
                        forResource: name,
                        withExtension: "jpg",
                        subdirectory: "Artwork"
                    )
            else { preconditionFailure("Missing bundled artwork: \(name)") }
            let body = (0..<(1 + index % 3)).map { paragraphs[(index + $0) % paragraphs.count] }
                .joined(separator: "\n\n")
            return FeedPost(
                id: index,
                revision: revision,
                title: titles[index % titles.count],
                body: body,
                place: places[index % places.count],
                date: index == 0 ? "Сегодня, 08:41" : "\(1 + index % 28) октября",
                imageURL: url,
                likes: 128 + (index * 37) % 900
            )
        }
    }
}

@MainActor
final class ComparisonSession {
    private(set) var count: Int
    private(set) var revision = 0
    private(set) var posts: [FeedPost]
    private(set) var saved: Set<Int> = []
    var observers: [@MainActor () -> Void] = []

    init() {
        let requested = Int(ProcessInfo.processInfo.environment["COMPARISON_ROWS"] ?? "500") ?? 500
        count = [100, 500, 2000].contains(requested) ? requested : 500
        posts = FeedData.posts(count: count, revision: 0)
    }

    func reload(count: Int? = nil) {
        self.count = count ?? self.count
        revision += 1
        posts = FeedData.posts(count: self.count, revision: revision)
        for observer in observers { observer() }
    }

    func toggleSaved(_ id: Int) {
        if !saved.insert(id).inserted { saved.remove(id) }
        for observer in observers { observer() }
    }
}

enum FeedStyle {
    static let background = Color(red: 0.955, green: 0.952, blue: 0.935)
    static let ink = Color(red: 0.12, green: 0.19, blue: 0.17)
    static let muted = Color(red: 0.43, green: 0.47, blue: 0.44)
    static let accent = Color(red: 0.20, green: 0.38, blue: 0.30)
    static let line = Color(red: 0.88, green: 0.89, blue: 0.86)
    static let bodySize = 15.0
    static let photoRatio = 1.6

    @MainActor static func ui(_ color: Color) -> UIColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
    @MainActor static func font(_ size: Double, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: size, weight: weight)
        )
    }
    static func text(_ size: Double, weight: FontWeight = .regular, color: Color = ink) -> TextStyle
    {
        TextStyle(size: size, weight: weight, color: color)
    }
}

struct FeedPlan: Sendable {
    let post: FeedPost
    let estimatedHeight: Double

    static func prepare(_ post: FeedPost, context: ItemPreparationContext, pipeline: ImagePipeline)
        async throws -> PreparedItem<FeedPlan>
    {
        try Task.checkCancellation()
        try await pipeline.preload(.url(post.imageURL))
        let width = max(1, context.crossAxisLength - 64)
        let scale = context.theme.conditions.textScale
        let font = CTFontCreateUIFontForLanguage(.system, FeedStyle.bodySize * scale, nil)!
        let text = NSAttributedString(
            string: post.body,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let body = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        let height = 170 * scale + Double(body.height) + (width + 32) / FeedStyle.photoRatio
        try Task.checkCancellation()
        return PreparedItem(FeedPlan(post: post, estimatedHeight: height), length: height)
    }
}

// Native cells decode on an actor and retain a bounded image cache. UIKit still owns
// reuse, Auto Layout, text measurement, and table scrolling on its normal path.
actor NativeImageLoader {
    private struct Key: Hashable { let url: URL; let pixels: Int }
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private let limit = 64 * 1024 * 1024

    func image(_ url: URL, pixels: Int) throws -> CGImage {
        try Task.checkCancellation()
        let key = Key(url: url, pixels: max(1, pixels))
        if let image = cache[key] { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: key.pixels,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        let cost = image.bytesPerRow * image.height
        while bytes + cost > limit, !order.isEmpty {
            if let removed = cache.removeValue(forKey: order.removeFirst()) {
                bytes -= removed.bytesPerRow * removed.height
            }
        }
        if cost <= limit { cache[key] = image; order.append(key); bytes += cost }
        return image
    }
}
