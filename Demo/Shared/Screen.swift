#if canImport(CoreText)
    import AppShell
    import Foundation
    import ImageIO
    import LayoutCore
    import Nodes
    import NodesRender
    import StateCore
    import ThemeCore


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
            let theme = self.theme
            label.style.color = theme.color(following ? .primaryText : .onAccent)
            appearance.background =
                following
                ? theme.color(.surface).mixed(with: theme.color(.primaryText), amount: 0.1)
                : theme.color(.accent)
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
        let name = Text("", style: TextStyle(size: 20, weight: .semibold))
        let handle = Text("", style: TextStyle(size: 13, colorRole: .secondaryText))
        let bio: Text
        let note = Text("", style: TextStyle(size: 13, weight: .medium, colorRole: .accent))
        let badge: FollowBadge
        let profile: Profile

        init(profile: Profile) {
            self.profile = profile
            avatar = Avatar(color: profile.color)
            bio = Text(profile.bio, style: TextStyle(size: 15))
            badge = FollowBadge(profile: profile)
            super.init()
            appearance.cornerRadius = 12
            appearance.borderWidth = 1
            // On Apple TV, moving toward any part of the card focuses its badge.
            isFocusSection = true
        }

        override func update() {
            appearance.background = theme.color(.surface)
            appearance.borderColor = theme.color(.separator)
            name.text = profile.name.value
            handle.text =
                "@" + profile.name.value.lowercased().replacingOccurrences(of: " ", with: "")
            note.text = "You follow \(profile.name.value)"
        }

        override func layoutSpec() -> LayoutSpec? {
            let following = profile.isFollowing.value
            return FlexContainer(.column) {
                Breakpoint([
                    // Wide: the badge on the right, with the note under it.
                    .from(760) {
                        FlexContainer(.row) {
                            avatar.size(56)
                            FlexContainer(.column) {
                                name; handle; bio
                            }
                            .gap(6)
                            .flex(grow: 1, shrink: 1)
                            FlexContainer(.column) {
                                badge
                                if following { note }
                            }
                            .alignItems(.end)
                            .gap(8)
                        }
                        .alignItems(.center)
                        .gap(24)
                    },
                    .from(460) {
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
                    },
                ]) {
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
    /// its first button, even though the button is not under the badges above.
    @MainActor
    final class Actions: Node {
        let rename: Button
        /// Jump with an animation to the last of the ten thousand lines and to the one in the
        /// middle: the lines on the way are laid out as it passes them.
        let toEnd: Button
        let toMiddle: Button

        init(rename: Button, toEnd: Button, toMiddle: Button) {
            self.rename = rename
            self.toEnd = toEnd
            self.toMiddle = toMiddle
            super.init()
            isFocusSection = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                rename
                toEnd
                toMiddle
            }
            .gap(12)
            .wrap()
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
            self.caption = Text(caption, style: TextStyle(size: 12, colorRole: .secondaryText))
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

    /// A message of the inbox.
    struct Mail: Identifiable {
        let id: Int
        let sender: String
        let subject: String
        var isUnread = true
        var isFlagged = false
    }

    /// A message's row: a dot while it is unread, the sender and the subject, and a flag.
    @MainActor
    final class MailRow: Node {
        let dot = Node()
        let sender = Text("", style: TextStyle(size: 15, weight: .semibold))
        let subject = Text("", style: TextStyle(size: 14, colorRole: .secondaryText))
        let flag = Node()

        override init() {
            super.init()
            dot.appearance.cornerRadius = 4
            flag.appearance.background = Color(red: 0.98, green: 0.62, blue: 0.10)
            flag.appearance.cornerRadius = 3
        }

        override func update() {
            dot.appearance.background = theme.color(.accent)
        }

        func showing(_ mail: Mail) -> MailRow {
            sender.text = mail.sender
            subject.text = mail.subject
            dot.appearance.opacity = mail.isUnread ? 1 : 0
            flag.appearance.opacity = mail.isFlagged ? 1 : 0
            return self
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                dot.size(width: 8, height: 8)
                FlexContainer(.column) {
                    sender
                    subject
                }
                .gap(2)
                .flex(grow: 1, shrink: 1)
                flag.size(width: 6, height: 20)
            }
            .alignItems(.center)
            .gap(12)
            .padding(top: 10, leading: 16, bottom: 10, trailing: 16)
        }
    }

    /// An inbox of a dozen messages, in the scroll of the screen: tap one to open it, swipe
    /// one aside for its actions — delete it, flag it, mark it read. Edit it to drag messages
    /// by their handles to other places, or select some and delete them.
    @MainActor
    final class Inbox: Node {
        private let rows = NodeCache<Int, MailRow> { _ in MailRow() }
        private var mails: [Mail] = [
            ("Ada Lovelace", "Notes on the Analytical Engine"),
            ("Grace Hopper", "The first actual bug, taped in"),
            ("Alan Turing", "On computable numbers"),
            ("Katherine Johnson", "Trajectories for Friendship 7"),
            ("Edsger Dijkstra", "Go to statement considered harmful"),
            ("Barbara Liskov", "Data abstraction and hierarchy"),
            ("Donald Knuth", "Volume 4B is out"),
            ("Margaret Hamilton", "Priority displays, and why"),
            ("Claude Shannon", "A mathematical theory of communication"),
            ("Frances Allen", "Program optimization"),
            ("John Backus", "Can programming be liberated?"),
            ("Radia Perlman", "Algorhyme"),
        ].enumerated().map { index, mail in
            Mail(id: index, sender: mail.0, subject: mail.1, isUnread: index % 3 != 2)
        }
        private(set) lazy var table = Table<Mail>(scrolls: false, estimatedRowHeight: 60) {
            [rows] mail in rows[mail.id].showing(mail)
        }

        private(set) lazy var edit = Button("Edit") { [weak self] in self?.toggleEditing() }
        private(set) lazy var deleteSelected = Button("Delete") { [weak self] in
            self?.deleteSelection()
        }

        override init() {
            super.init()
            table.appearance.cornerRadius = 12
            table.appearance.clipsContent = true
            table.allowsMultipleSelectionDuringEditing = true
            table.onSelectionChange = { [weak self] _ in self?.relabel() }
            table.onSelect = { [weak self] mail in
                self?.change(mail.id) { $0.isUnread = false }
                self?.onOpen?(mail)
            }
            // Only from inside the inbox: its menu item is enabled once a message is pressed
            // or focused.
            handle(.editInbox) { [weak self] in self?.toggleEditing() }
            table.onMove = { [weak self] move in
                guard let self, let from = mails.firstIndex(where: { $0.id == move.item }) else {
                    return
                }

                mails.insert(mails.remove(at: from), at: move.to.index)
            }
            table.trailingActions = { [weak self] mail in
                [
                    SwipeAction("Delete", role: .destructive) { self?.delete(mail.id) },
                    SwipeAction(
                        mail.isFlagged ? "Unflag" : "Flag",
                        color: Color(red: 0.98, green: 0.62, blue: 0.10)
                    ) { self?.change(mail.id) { $0.isFlagged.toggle() } },
                ]
            }
            table.leadingActions = { [weak self] mail in
                [
                    SwipeAction(
                        mail.isUnread ? "Read" : "Unread",
                        color: self?.theme.color(.accent)
                    ) {
                        self?.change(mail.id) { $0.isUnread.toggle() }
                    }
                ]
            }
            show()
        }

        /// What opening a message does.
        var onOpen: (@MainActor (Mail) -> Void)?

        /// The message `id`, while the inbox has it.
        func mail(_ id: Int) -> Mail? {
            mails.first { $0.id == id }
        }

        private func show() {
            table.sections = [TableSection(id: "inbox", items: mails)]
        }

        private func toggleEditing() {
            withAnimation(.easeInOut(duration: 0.25)) {
                table.selection = []
                table.isEditing.toggle()
                relabel()
            }
        }

        private func relabel() {
            edit.title = table.isEditing ? "Done" : "Edit"
            deleteSelected.title = "Delete \(table.selection.count)"
            setNeedsLayout()
        }

        private func deleteSelection() {
            let selected = table.selection
            withAnimation(.easeInOut(duration: 0.3)) {
                mails.removeAll { selected.contains($0.id) }
                show()
                relabel()
            }
        }

        private func delete(_ id: Int) {
            withAnimation(.easeInOut(duration: 0.3)) {
                mails.removeAll { $0.id == id }
                show()
            }
        }

        /// Flags the message `id`, or takes its flag away.
        func toggleFlag(_ id: Int) {
            change(id) { $0.isFlagged.toggle() }
        }

        private func change(_ id: Int, _ edit: (inout Mail) -> Void) {
            guard let index = mails.firstIndex(where: { $0.id == id }) else { return }

            edit(&mails[index])
            show()
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                FlexContainer(.row) {
                    edit
                    if table.isEditing && !table.selection.isEmpty { deleteSelected }
                }
                .gap(12)
                table
            }
            .gap(12)
        }
    }

    /// A window onto a card that zooms up to four times: pinch it — on a Mac, pinch the
    /// trackpad or double tap it with two fingers — or use the button.
    @MainActor
    final class Zoom: Node {
        let scroll = Scroll(.vertical)
        private(set) lazy var toggle = Button("Zoom in") { [weak self] in
            guard let self else { return }

            withAnimation(.spring(response: 0.4, dampingRatio: 1)) {
                scroll.zoom(to: scroll.zoomScale > 1 ? 1 : 2.5)
            }
        }

        override init() {
            super.init()
            scroll.content = Card()
            scroll.zoomRange = 1...4
            scroll.onScroll = { [weak self] _ in self?.relabel() }
            scroll.appearance.cornerRadius = 12
        }

        override func update() {
            scroll.appearance.background = theme.color(.surface)
        }

        private func relabel() {
            toggle.title = scroll.zoomScale > 1 ? "Zoom out" : "Zoom in"
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                scroll.size(width: 300, height: 180)
                FlexContainer(.row) { toggle }
            }
            .gap(12)
        }

        final class Card: Node {
            let text = Text(
                "Small print, sharp at any zoom: the text is drawn again for the pixels it "
                    + "takes. Pinch to zoom in, and move around the card.",
                style: TextStyle(size: 11)
            )
            let dots = [
                Color(red: 0.93, green: 0.45, blue: 0.35),
                Color(red: 0.36, green: 0.62, blue: 0.95),
                Color(red: 0.40, green: 0.75, blue: 0.50),
            ].map { color in
                let dot = Node()
                dot.appearance.background = color
                dot.appearance.cornerRadius = 8
                return dot
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) {
                    text
                    FlexContainer(.row) {
                        for dot in dots { dot.size(width: 16, height: 16) }
                    }
                    .gap(6)
                }
                .gap(10)
                .padding(16)
            }
        }
    }

    /// Four pages in a window of their width: a swipe turns one page, as a pager does.
    @MainActor
    final class Pages: Node {
        private static let colors = [
            Color(red: 0.93, green: 0.45, blue: 0.35),
            Color(red: 0.36, green: 0.62, blue: 0.95),
            Color(red: 0.40, green: 0.75, blue: 0.50),
            Color(red: 0.55, green: 0.36, blue: 0.85),
        ]

        let scroll = Scroll(.horizontal)

        override init() {
            super.init()
            scroll.content = Row()
            scroll.isPaging = true
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.row) {
                scroll.size(width: 300, height: 140)
            }
        }

        final class Row: Node {
            let pages = Pages.colors.enumerated().map { index, color in
                Page(number: index + 1, color: color)
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.row) {
                    for page in pages { page }
                }
            }
        }

        final class Page: Node {
            let label: Text

            init(number: Int, color: Color) {
                label = Text(
                    "Page \(number) of 4",
                    style: TextStyle(size: 20, weight: .bold, color: .white)
                )
                super.init()
                appearance.background = color
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) { label }
                    .justifyContent(.center)
                    .alignItems(.center)
                    .size(width: 300, height: 140)
            }
        }
    }

    /// A button for each kind of transition: it takes the card out that way, or brings it
    /// back.
    @MainActor
    final class Transitions: Node {
        private static let kinds: [(name: String, transition: Transition)] = [
            ("Fade", .opacity),
            ("Scale", .scale),
            ("Slide", .slide),
            ("Move up", .move(edge: .bottom)),
            ("Push", .push(from: .trailing)),
            ("Turn", .rotation(degrees: 90)),
            ("Flip", .flip()),
            ("Pop", .pop),
            ("Shrink and fade", .scale(0.5, anchor: .topLeading).combined(with: .opacity)),
        ]

        let card = Card()
        let showsCard = State(true)
        private(set) var buttons: [Button] = []

        override init() {
            super.init()
            buttons = Transitions.kinds.map { kind in
                Button(kind.name) { [weak self] in
                    guard let self else { return }

                    card.transition = kind.transition
                    withAnimation(.easeInOut(duration: 0.5)) {
                        showsCard.value.toggle()
                    }
                }
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                FlexContainer(.row) {
                    for button in buttons { button }
                }
                .gap(8)
                .wrap()
                FlexContainer(.row) {
                    if showsCard.value { card }
                }
                .height(.points(96))
            }
            .gap(16)
        }

        /// The card the transitions take out and bring back.
        @MainActor
        final class Card: Node {
            let label = Text(
                "Tap a transition",
                style: TextStyle(size: 17, weight: .semibold, color: .white)
            )

            override init() {
                super.init()
                appearance.background = Color(red: 0.55, green: 0.36, blue: 0.85)
                appearance.cornerRadius = 16
            }

            override func layoutSpec() -> LayoutSpec? {
                FlexContainer(.column) { label }
                    .justifyContent(.center)
                    .alignItems(.center)
                    .size(width: 220, height: 96)
            }
        }
    }

    /// A section title on the screen's gray, so what scrolls under it does not show through.
    @MainActor
    final class SectionTitle: Node {
        let label: Text

        init(_ title: String) {
            label = Text(title, style: TextStyle(size: 17, weight: .semibold))
            super.init()
        }

        override func update() {
            appearance.background = theme.color(.background)
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

        let label = Text("", style: TextStyle(size: 15))

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
    /// near — and a button that jumps back to the top.
    @MainActor
    final class Feed: Node {
        let tiles = Scroll(.horizontal, content: Tiles())
        let people = SectionTitle("People")
        let images = SectionTitle("Images")
        let gallery = Gallery()
        let cards: [ProfileCard]
        let actions: Actions
        let inboxTitle = SectionTitle("Inbox")
        let inbox = Inbox()
        let zoomTitle = SectionTitle("Zoom")
        let zoom = Zoom()
        let pagesTitle = SectionTitle("Pages")
        let pages = Pages()
        let transitionsTitle = SectionTitle("Transitions")
        let transitions = Transitions()
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

        /// Jumps back from the last line with an animation.
        let toTop: Button

        init(cards: [ProfileCard], actions: Actions, toTop: Button) {
            self.cards = cards
            self.actions = actions
            self.toTop = toTop
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                tiles.margin(top: 0, leading: -24, bottom: 0, trailing: -24)
                people
                    .margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                    .sticky(top: 0)
                for card in cards { card }
                // Between the cards and the button: on Apple TV the remote goes past a block
                // with nothing to focus to the focus section under it.
                images.margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                gallery
                zoomTitle.margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                zoom
                pagesTitle.margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                pages
                transitionsTitle.margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                transitions
                actions
                inboxTitle.margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                inbox
                gridTitle
                    .margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                    .sticky(top: 0)
                grid
                linesTitle
                    .margin(top: 0, leading: -24, bottom: -8, trailing: -24)
                    .sticky(top: 0)
                lines
                FlexContainer(.row) { toTop }
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
            style: TextStyle(size: 26, weight: .bold)
        )
        let hint = Text(
            "Resize the window: under 460 points a card turns into a column, and from 760 "
                + "it spreads out. "
                + "Tap a Follow badge, or rename Ada: the changes animate. Pull the list down "
                + "to refresh. Swipe a message of the inbox aside for its actions, or edit "
                + "the inbox to move messages and delete several. "
                + "The list scrolls, and so does the row of tiles; images, a grid and ten "
                + "thousand lines are at its end.",
            style: TextStyle(size: 14, colorRole: .secondaryText)
        )
        let cards: [ProfileCard]
        let feed: Scroll

        /// The inbox in the feed.
        var inbox: Inbox? { (feed.content as? Feed)?.inbox }

        init(profiles: [Profile], rename: @escaping @MainActor () -> Void) {
            cards = profiles.map { ProfileCard(profile: $0) }
            let feed = Scroll(.vertical)
            // Pulled down past its top, it refreshes for a second and a half.
            feed.refreshIndicator = RefreshSpinner()
            feed.onRefresh = { try? await Task.sleep(for: .seconds(1.5)) }
            let toEnd = Button("To the last line") { [weak feed] in
                guard let feed else { return }

                withAnimation(.easeInOut(duration: 0.8)) {
                    feed.contentOffset = feed.offsetRange.highest
                }
            }
            let toTop = Button("Back to the top") { [weak feed] in
                withAnimation(.easeInOut(duration: 0.8)) {
                    feed?.contentOffset = .zero
                }
            }
            let toMiddle = Button("To line 5000") { [weak feed] in
                withAnimation(.easeInOut(duration: 0.8)) {
                    _ = (feed?.content as? Feed)?.lines.scroll(to: 5000)
                }
            }
            let actions = Actions(
                rename: Button("Rename Ada", action: rename),
                toEnd: toEnd,
                toMiddle: toMiddle
            )
            feed.content = Feed(cards: cards, actions: actions, toTop: toTop)
            self.feed = feed
            super.init()
            handle(.renameAda, perform: rename)
            handle(.backToTop, isEnabled: { [weak feed] in (feed?.contentOffset.y ?? 0) > 0 }) {
                [weak feed] in
                withAnimation(.easeInOut(duration: 0.8)) {
                    feed?.contentOffset = .zero
                }
            }
        }

        override func update() {
            appearance.background = theme.color(.background)
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

    extension Command {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let renameAda = Command(
            "renameAda",
            title: "Rename Ada",
            shortcut: Shortcut("r", [.command])
        )
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let backToTop = Command(
            "backToTop",
            title: "Back to the Top",
            shortcut: Shortcut(.up, [.command])
        )
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let editInbox = Command(
            "editInbox",
            title: "Edit Inbox",
            shortcut: Shortcut("e", [.command])
        )
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let newMessage = Command(
            "newMessage",
            title: "New Message",
            shortcut: Shortcut("n", [.command])
        )
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let messageInfo = Command(
            "messageInfo",
            title: "Message Info",
            shortcut: Shortcut("i", [.command])
        )
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let flagMessage = Command(
            "flagMessage",
            title: "Flag Message",
            shortcut: Shortcut("l", [.command, .shift])
        )
    }

    /// Where the demo's navigation goes: the screen, and a message of its inbox.
    ///
    /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum DemoRoute: Hashable, Sendable {
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case home
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        case message(Int)
    }

    /// A message opened from the inbox: who wrote it, its subject, a few lines and a reply.
    @MainActor
    final class MessageNode: Node {
        let sender: Text
        let subject: Text
        let body = Text(
            "The lines of a message are not in this demo: the screen is here to show a stack of "
                + "screens. Go back with the back button, a swipe from the edge, Menu on the "
                + "remote or Command-[.",
            style: TextStyle(size: 15, colorRole: .secondaryText)
        )
        /// "Flagged" while the message is.
        let flag = Text("", style: TextStyle(size: 15, weight: .semibold))
        private(set) lazy var reply: Button = Button("Reply") { [weak self] in
            self?.reply.title = "Replied"
            self?.setNeedsLayout()
        }

        init(_ mail: Mail?) {
            sender = Text(mail?.sender ?? "", style: TextStyle(size: 22, weight: .bold))
            subject = Text(mail?.subject ?? "The message is gone", style: TextStyle(size: 17))
            super.init()
            showFlag(mail?.isFlagged ?? false)
        }

        func showFlag(_ isFlagged: Bool) {
            flag.text = isFlagged ? "Flagged" : "Not flagged"
            setNeedsLayout()
        }

        override func update() {
            appearance.background = theme.color(.background)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                sender
                subject
                flag
                body
                FlexContainer(.row) { reply }
            }
            .gap(12)
            .padding(24)
        }
    }

    /// A new message, in a sheet over the inbox: Send and Cancel close it, as Escape, Menu on
    /// the remote and a swipe down do.
    @MainActor
    final class ComposeNode: Node {
        let heading = Text("New Message", style: TextStyle(size: 22, weight: .bold))
        let body = Text(
            "A sheet over the screen: its commands go to the window, not to the inbox under it.",
            style: TextStyle(size: 15, colorRole: .secondaryText)
        )
        private(set) lazy var cancel: Button = Button("Cancel") { [weak self] in self?.onClose?() }
        private(set) lazy var send: Button = Button("Send") { [weak self] in self?.onClose?() }
        /// What Send and Cancel do.
        var onClose: (@MainActor () -> Void)?

        override func update() {
            appearance.background = theme.color(.background)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                heading
                body
                FlexContainer(.row) {
                    cancel
                    send
                }
                .gap(12)
            }
            .gap(12)
            .padding(24)
        }
    }

    /// Who sent a message and when, in a sheet that opens halfway and is drawn up to full.
    @MainActor
    final class MessageInfoNode: Node {
        let heading = Text("Message Info", style: TextStyle(size: 22, weight: .bold))
        let details: Text
        let hint = Text(
            "Drag the sheet up by its grabber, or down to close it.",
            style: TextStyle(size: 15, colorRole: .secondaryText)
        )

        init(_ mail: Mail?) {
            details = Text(
                "From \(mail?.sender ?? "nobody"): \(mail?.subject ?? "")",
                style: TextStyle(size: 17)
            )
        }

        override func update() {
            appearance.background = theme.color(.background)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                heading
                details
                hint
            }
            .gap(12)
            .padding(24)
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

        /// The demo's menu, for a Mac's menu bar and iPad's: its commands work from the
        /// keyboard too.
        ///
        /// Ownership: value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public static let menu = Menu("Screen") {
            Command.newMessage
            Divider()
            Command.renameAda
            Command.backToTop
            Divider()
            Command.editInbox
            Command.messageInfo
            Command.flagMessage
        }

        /// The demo's navigation: the screen at its root, and a message on top of it when one
        /// is opened in the inbox. The inbox's toolbar edits it — enabled once a message is
        /// pressed or focused; a message's flags it, with a checkmark in the menu while it is
        /// flagged.
        ///
        /// Ownership: owned by the model. Isolation: MainActor. Errors: none. Cancellation:
        /// not applicable.
        public private(set) lazy var stack: Stack<DemoRoute> = {
            let home = screenNode
            let inbox = home.inbox
            let stack = Stack(root: DemoRoute.home) { [weak self] route in
                switch route {
                case .home:
                    let screen = NodeScreen(home, title: "Layout demo")
                    self?.homeScreen = screen
                    screen.toolbar = [.newMessage, .editInbox]
                    screen.handle(.newMessage) { [weak screen] in
                        screen.map(DemoModel.compose(over:))
                    }
                    return screen
                case .message(let id):
                    let message = MessageNode(inbox?.mail(id))
                    let screen = NodeScreen(message, title: inbox?.mail(id)?.sender ?? "")
                    screen.toolbar = [.messageInfo, .flagMessage]
                    screen.handle(.messageInfo) { [weak screen] in
                        let info = Presentation(
                            NodeScreen(MessageInfoNode(inbox?.mail(id)), title: "Message Info"),
                            style: .sheet(heights: [.medium, .large])
                        )
                        screen?.present(info)
                    }
                    screen.handle(
                        .flagMessage,
                        isEnabled: { inbox?.mail(id) != nil },
                        isOn: { inbox?.mail(id)?.isFlagged ?? false }
                    ) { [weak message] in
                        inbox?.toggleFlag(id)
                        message?.showFlag(inbox?.mail(id)?.isFlagged ?? false)
                    }
                    return screen
                }
            }
            inbox?.onOpen = { [weak stack] mail in
                stack?.push(.message(mail.id))
            }
            return stack
        }()

        /// The demo's links: `/` is the screen, `/messages/:id` a message over it.
        ///
        /// Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
        public static let routes = RouteTable<DemoRoute> {
            RoutePattern("/", .home)
            RoutePattern(
                "/messages/:id",
                route: { .message(try $0.value("id")) },
                values: { route in
                    guard case .message(let id) = route else { return nil }
                    return ["id": String(id)]
                }
            )
        }

        /// Opens the screens of a link into the demo (`routes`); `false` when it has none.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func open(_ url: URL) -> Bool {
            guard let path = try? DemoModel.routes.path(for: url) else { return false }

            return stack.setPath(path) != .rejected(.screenInUse)
        }

        /// Opens the messages `ids`, one over the other, as a link into the app would — the
        /// UI tests start there. Launch arguments: `OPEN_MESSAGES=0,1` in the environment.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func openMessages(from environment: [String: String]) {
            guard let ids = environment["OPEN_MESSAGES"] else { return }

            let messages = ids.split(separator: ",").compactMap { Int($0) }.map(DemoRoute.message)
            stack.setPath([.home] + messages)
        }

        /// Shows a new message in a sheet over `screen`.
        private static func compose(over screen: AppShell.Screen) {
            let compose = ComposeNode()
            let sheet = Presentation(NodeScreen(compose, title: "New Message"))
            compose.onClose = { [weak sheet] in sheet?.dismiss() }
            screen.present(sheet)
        }

        /// Opens a new message over the screen at launch, as ⌘N would — the UI tests start
        /// there. Launch arguments: `OPEN_COMPOSE=1` in the environment.
        ///
        /// Ownership: none. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func openCompose(from environment: [String: String]) {
            guard environment["OPEN_COMPOSE"] != nil else { return }

            homeScreen?.perform(.newMessage)
        }

        /// The screen at the stack's root.
        private weak var homeScreen: AppShell.Screen?

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
