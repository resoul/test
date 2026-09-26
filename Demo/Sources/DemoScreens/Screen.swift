#if canImport(CoreText)
    import Foundation
    import ImageIO
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore

    private let ink = Color(red: 0.11, green: 0.12, blue: 0.14)
    private let muted = Color(red: 0.45, green: 0.47, blue: 0.52)
    private let accent = Color(red: 0.16, green: 0.42, blue: 0.95)

    /// What one card shows.
    @MainActor
    final class Profile {
        let name: State<String>
        let bio: String
        let color: Color
        let isFollowing = State(false)

        init(name: String, bio: String, color: Color) {
            self.name = State(name)
            self.bio = bio
            self.color = color
        }
    }

    /// A colored circle. Its size is set where it is placed (`.size(56)`): in a column,
    /// an item without a width is stretched across it, as in CSS.
    @MainActor
    final class Avatar: Node {
        init(color: Color) {
            super.init()
            appearance.background = color
            appearance.cornerRadius = 28
        }

        override var layoutContent: LeafContent? { .size(width: 56, height: 56) }
    }

    /// "Follow" or "Following", by the profile's state.
    @MainActor
    final class FollowBadge: Node {
        let label = Text("", style: TextStyle(size: 13, weight: .semibold))
        let profile: Profile

        init(profile: Profile) {
            self.profile = profile
            super.init()
            appearance.cornerRadius = 8
            onTap = { [profile] in
                withAnimation(.spring(response: 0.35, dampingRatio: 0.8)) {
                    profile.isFollowing.value.toggle()
                }
            }
        }

        override func pressChanged(_ isPressed: Bool) {
            appearance.opacity = isPressed ? 0.6 : 1
        }

        override func focusChanged(_ isFocused: Bool) {
            guard (host?.focusLook ?? .lift) == .lift else { return }

            appearance.scale = isFocused ? 1.25 : 1
            appearance.shadow = isFocused ? Shadow(opacity: 0.45, radius: 14, y: 10) : nil
        }

        override func update() {
            let following = profile.isFollowing.value
            label.text = following ? "Following" : "Follow"
            label.style.color = following ? ink : .white
            appearance.background = following ? Color(red: 0.9, green: 0.91, blue: 0.93) : accent
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer { label }
                .padding(8)
        }
    }

    /// A profile: a row when there is room, a column when there is not. Following adds a
    /// note under the bio.
    @MainActor
    final class ProfileCard: Node {
        let avatar: Avatar
        let name = Text("", style: TextStyle(size: 20, weight: .semibold, color: ink))
        let handle = Text("", style: TextStyle(size: 13, color: muted))
        let bio: Text
        let note = Text("", style: TextStyle(size: 13, weight: .medium, color: accent))
        let badge: FollowBadge
        let profile: Profile

        init(profile: Profile) {
            self.profile = profile
            avatar = Avatar(color: profile.color)
            bio = Text(profile.bio, style: TextStyle(size: 15, color: ink))
            badge = FollowBadge(profile: profile)
            super.init()
            appearance.background = .white
            appearance.cornerRadius = 12
            appearance.borderWidth = 1
            appearance.borderColor = Color(red: 0.88, green: 0.89, blue: 0.91)
            // On Apple TV, moving toward any part of the card focuses its badge.
            isFocusSection = true
        }

        override func update() {
            name.text = profile.name.value
            handle.text =
                "@" + profile.name.value.lowercased().replacingOccurrences(of: " ", with: "")
            note.text = "You follow \(profile.name.value)"
        }

        override func layoutSpec() -> LayoutSpec? {
            let following = profile.isFollowing.value
            return FlexContainer(.column) {
                Breakpoint(from: 460) {
                    FlexContainer(.row) {
                        avatar.size(56)
                        FlexContainer(.column) {
                            name; handle; bio
                            if following { note }
                        }
                        .gap(4)
                        .flex(grow: 1, shrink: 1)
                        badge
                    }
                    .alignItems(.start)
                    .gap(16)
                } otherwise: {
                    FlexContainer(.column) {
                        avatar.size(56)
                        name
                        handle
                        bio
                        if following { note }
                        badge.alignSelf(.start)
                    }
                    .gap(8)
                }
            }
            .padding(16)
        }
    }

    /// A row of actions across the screen. On Apple TV, moving toward any part of it focuses
    /// its button, even though the button is not under the badges above.
    @MainActor
    final class Actions: Node {
        let rename: Button

        init(rename: Button) {
            self.rename = rename
            super.init()
            isFocusSection = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) { rename }
        }
    }

    /// A colored tile with its number, for the row that scrolls sideways.
    @MainActor
    final class Tile: Node {
        let label: Text

        init(number: Int, color: Color) {
            label = Text("\(number)", style: TextStyle(size: 22, weight: .bold, color: .white))
            super.init()
            appearance.background = color
            appearance.cornerRadius = 12
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { label }
                .size(width: 96, height: 72)
                .justifyContent(.center)
                .alignItems(.center)
        }
    }

    /// Twelve tiles in a row, wider than any screen.
    @MainActor
    final class Tiles: Node {
        let tiles = (1...12).map { number in
            Tile(
                number: number,
                color: Color(
                    red: 0.2 + 0.06 * Double(number % 6),
                    green: 0.4,
                    blue: 0.9 - 0.05 * Double(number % 8)
                )
            )
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                for tile in tiles { tile }
            }
            .gap(12)
            .padding(top: 0, leading: 24, bottom: 0, trailing: 24)
        }
    }

    /// A generated landscape — sky, a sun at the top right, ground — encoded as an app would
    /// receive it. Nothing in it is symmetric, so a wrong rotation or mirror shows at once.
    enum Landscape {
        /// Upright pixels, `width` × `height`, as PNG.
        static func png(width: Int, height: Int) -> Data {
            encode(width: width, height: height, type: "public.png", orientation: 1) { _ in }
        }

        /// The same picture as a JPEG whose pixels are stored turned a quarter to the left,
        /// with EXIF orientation 6 saying to turn them back: it must show upright.
        static func rotatedJPEG(width: Int, height: Int) -> Data {
            encode(width: height, height: width, type: "public.jpeg", orientation: 6) { context in
                context.translateBy(x: CGFloat(height), y: 0)
                context.rotate(by: .pi / 2)
            }
        }

        private static func encode(
            width: Int,
            height: Int,
            type: String,
            orientation: Int,
            turn: (CGContext) -> Void
        ) -> Data {
            guard
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else { return Data() }

            turn(context)
            let w = CGFloat(orientation == 6 ? height : width)
            let h = CGFloat(orientation == 6 ? width : height)
            // Core Graphics counts y upward: the sky is the upper part.
            context.setFillColor(CGColor(red: 0.45, green: 0.7, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: h * 0.35, width: w, height: h * 0.65))
            context.setFillColor(CGColor(red: 0.35, green: 0.62, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.35))
            context.setFillColor(CGColor(red: 1, green: 0.82, blue: 0.25, alpha: 1))
            context.fillEllipse(
                in: CGRect(x: w * 0.72, y: h * 0.6, width: h * 0.28, height: h * 0.28)
            )
            context.setFillColor(CGColor(red: 0.55, green: 0.38, blue: 0.25, alpha: 1))
            context.fill(CGRect(x: w * 0.12, y: h * 0.35, width: w * 0.05, height: h * 0.25))

            guard let image = context.makeImage() else { return Data() }

            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output,
                    type as CFString,
                    1,
                    nil
                )
            else { return Data() }

            let properties: [String: Any] = [kCGImagePropertyOrientation as String: orientation]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            CGImageDestinationFinalize(destination)
            return output as Data
        }
    }

    /// An image in a fixed box with a caption saying how it is placed.
    @MainActor
    final class Framed: Node {
        let image: Image
        let caption: Text

        init(_ image: Image, caption: String) {
            self.image = image
            self.caption = Text(caption, style: TextStyle(size: 12, color: muted))
            super.init()
            image.appearance.background = Color(red: 0.88, green: 0.89, blue: 0.91)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                image.size(width: 96, height: 72)
                caption
            }
            .gap(6)
        }
    }

    /// One picture, twice as wide as tall, placed each way an image can be; the same picture
    /// stored turned with an EXIF orientation; and a placeholder with nothing to load.
    @MainActor
    final class Gallery: Node {
        let items: [Framed]

        override init() {
            let picture = Landscape.png(width: 400, height: 200)
            let rotated = Image(source: .data(Landscape.rotatedJPEG(width: 400, height: 200)))
            rotated.accessibility.label = "Landscape stored rotated, shown upright"
            let waiting = Image(
                placeholder: ImagePlaceholder(color: Color(red: 0.8, green: 0.84, blue: 0.9))
            )
            items = [
                Framed(Image(source: .data(picture), contentMode: .fit), caption: "fit"),
                Framed(Image(source: .data(picture), contentMode: .fill), caption: "fill"),
                Framed(Image(source: .data(picture), contentMode: .stretch), caption: "stretch"),
                Framed(rotated, caption: "EXIF 6, upright"),
                Framed(waiting, caption: "placeholder"),
            ]
            super.init()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                for item in items { item }
            }
            .gap(12)
            .wrap()
        }
    }

    /// A section title on the screen's gray, so what scrolls under it does not show through.
    @MainActor
    final class SectionTitle: Node {
        let label: Text

        init(_ title: String) {
            label = Text(title, style: TextStyle(size: 17, weight: .semibold, color: ink))
            super.init()
            appearance.background = Color(red: 0.96, green: 0.96, blue: 0.97)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer { label }
                .padding(top: 8, leading: 24, bottom: 8, trailing: 24)
        }
    }

    /// A line of the long list: its number, and for every third a sentence long enough to
    /// wrap, so the lines are not all as long as the list assumes.
    @MainActor
    final class Line: Node {
        struct Item: Identifiable {
            let id: Int
        }

        let label = Text("", style: TextStyle(size: 15, color: ink))

        func showing(_ item: Item) -> Line {
            label.text =
                item.id % 3 == 0
                ? "Line \(item.id): only the lines near the screen are laid out, however "
                    + "long the list is; the rest keep their space."
                : "Line \(item.id)"
            return self
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer { label }
                .padding(vertical: 4)
        }
    }

    /// A numbered square of the grid, as wide as its share of the line.
    @MainActor
    final class Swatch: Node {
        struct Item: Identifiable {
            let id: Int
        }

        let label = Text("", style: TextStyle(size: 15, weight: .semibold, color: .white))

        override init() {
            super.init()
            appearance.cornerRadius = 10
        }

        func showing(_ item: Item) -> Swatch {
            label.text = "\(item.id)"
            appearance.background = Color(
                red: 0.25 + 0.05 * Double(item.id % 10),
                green: 0.45 + 0.04 * Double(item.id % 7),
                blue: 0.85 - 0.06 * Double(item.id % 5)
            )
            return self
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) { label }
                .aspectRatio(1)
                .justifyContent(.center)
                .alignItems(.center)
        }
    }

    /// What scrolls: the row of tiles, a title that sticks to the top, the cards, the
    /// actions, the images, a grid and ten thousand lines — those two laid out as they come
    /// near.
    @MainActor
    final class Feed: Node {
        let tiles = Scroll(.horizontal, content: Tiles())
        let people = SectionTitle("People")
        let images = SectionTitle("Images")
        let gallery = Gallery()
        let cards: [ProfileCard]
        let actions: Actions
        let gridTitle = SectionTitle("600 squares, four in a line")
        private let swatches = NodeCache<Int, Swatch> { _ in Swatch() }
        private(set) lazy var grid = LazyStack(
            items: (1...600).map(Swatch.Item.init),
            lanes: 4,
            estimatedLength: 80,
            spacing: 8
        ) { [swatches] item in
            swatches[item.id].showing(item)
        }
        let linesTitle = SectionTitle("10,000 lines")
        private let lineNodes = NodeCache<Int, Line> { _ in Line() }
        private(set) lazy var lines = LazyStack(
            items: (1...10_000).map(Line.Item.init),
            estimatedLength: 26,
            spacing: 4
        ) { [lineNodes] item in
            lineNodes[item.id].showing(item)
        }

        init(cards: [ProfileCard], actions: Actions) {
            self.cards = cards
            self.actions = actions
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                tiles.margin(top: 0, leading: -24, bottom: 0, trailing: -24)
                people
                    .margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                    .sticky(top: 0)
                for card in cards { card }
                actions
                // After the button: on Apple TV a block with nothing to focus above a focus
                // section keeps the remote from reaching it while it is off the screen.
                images.margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                gallery
                gridTitle
                    .margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                    .sticky(top: 0)
                grid
                linesTitle
                    .margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                    .sticky(top: 0)
                lines
            }
            .gap(16)
            .padding(top: 0, leading: 24, bottom: 24, trailing: 24)
        }
    }

    /// The whole screen: a title over a list that scrolls — a row of tiles that scrolls
    /// sideways, the cards and a row of actions.
    @MainActor
    final class Screen: Node {
        let title = Text(
            "Nodes, text, state and a breakpoint",
            style: TextStyle(size: 26, weight: .bold, color: ink)
        )
        let hint = Text(
            "Resize the window: under 460 points a card turns into a column. "
                + "Tap a Follow badge, or rename Ada: the changes animate. "
                + "The list scrolls, and so does the row of tiles; images, a grid and ten "
                + "thousand lines are at its end.",
            style: TextStyle(size: 14, color: muted)
        )
        let cards: [ProfileCard]
        let feed: Scroll

        init(profiles: [Profile], rename: @escaping @MainActor () -> Void) {
            cards = profiles.map { ProfileCard(profile: $0) }
            let actions = Actions(rename: Button("Rename Ada", action: rename))
            feed = Scroll(.vertical, content: Feed(cards: cards, actions: actions))
            super.init()
            appearance.background = Color(red: 0.96, green: 0.96, blue: 0.97)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                FlexContainer(.column) {
                    title
                    hint
                }
                .gap(16)
                .padding(24)
                feed
            }
        }
    }

    /// The demo: two profiles and the screen showing them. Mac and iOS apps only host
    /// `screen` in a node view.
    ///
    /// Ownership: the caller owns the model; the model owns the screen. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    @MainActor
    public final class DemoModel {
        private let profiles = [
            Profile(
                name: "Ada Lovelace",
                bio: "Wrote the first program for a machine that did not exist yet.",
                color: Color(red: 0.93, green: 0.45, blue: 0.35)
            ),
            Profile(
                name: "Grace Hopper",
                bio: "Built the first compiler, and found the first actual bug.",
                color: Color(red: 0.36, green: 0.66, blue: 0.47)
            ),
            Profile(
                name: "Alan Turing",
                bio: "Asked what a machine can compute, and answered it.",
                color: Color(red: 0.55, green: 0.42, blue: 0.85)
            ),
            Profile(
                name: "Katherine Johnson",
                bio: "Computed the paths that took astronauts to orbit and back.",
                color: Color(red: 0.95, green: 0.68, blue: 0.25)
            ),
            Profile(
                name: "Edsger Dijkstra",
                bio: "Found the shortest path, and argued against the goto.",
                color: Color(red: 0.27, green: 0.6, blue: 0.75)
            ),
            Profile(
                name: "Barbara Liskov",
                bio: "Said what it means for one type to stand in for another.",
                color: Color(red: 0.85, green: 0.35, blue: 0.55)
            ),
            Profile(
                name: "Donald Knuth",
                bio: "Wrote the book on algorithms, and the program to typeset it.",
                color: Color(red: 0.45, green: 0.62, blue: 0.3)
            ),
            Profile(
                name: "Margaret Hamilton",
                bio: "Led the software that landed Apollo 11 on the Moon.",
                color: Color(red: 0.62, green: 0.5, blue: 0.4)
            ),
        ]
        private let names = ["Ada Lovelace", "Augusta Ada King", "Countess of Lovelace"]
        private var nameIndex = 0

        /// The root node to show.
        ///
        /// Ownership: owned by the model. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public var screen: Node { screenNode }

        /// Ada's Follow badge — for a focus request.
        ///
        /// Ownership: owned by the screen. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public var firstBadge: Node { screenNode.cards[0].badge }

        private lazy var screenNode = Screen(profiles: profiles) { [weak self] in
            self?.renameAda()
        }

        /// Ownership: the caller owns the model. Isolation: MainActor. Errors: none.
        /// Cancellation: not applicable.
        public init() {}

        private func renameAda() {
            nameIndex = (nameIndex + 1) % names.count
            withAnimation {
                profiles[0].name.value = names[nameIndex]
            }
        }
    }
#endif
