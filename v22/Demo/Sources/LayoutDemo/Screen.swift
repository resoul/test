#if canImport(AppKit)
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

    /// A colored circle.
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
        let label = Text("", style: TextStyle(fontName: "Helvetica-Bold", size: 13))
        let profile: Profile

        init(profile: Profile) {
            self.profile = profile
            super.init()
            appearance.cornerRadius = 8
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

    /// A profile: a row when there is room, a column when there is not.
    @MainActor
    final class ProfileCard: Node {
        let avatar: Avatar
        let name = Text("", style: TextStyle(fontName: "Helvetica-Bold", size: 20, color: ink))
        let handle = Text("", style: TextStyle(size: 13, color: muted))
        let bio: Text
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
        }

        override func update() {
            name.text = profile.name.value
            handle.text =
                "@" + profile.name.value.lowercased().replacingOccurrences(of: " ", with: "")
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                Breakpoint(from: 460) {
                    FlexContainer(.row) {
                        avatar
                        FlexContainer(.column) {
                            name; handle; bio
                        }
                        .gap(4)
                        .flex(grow: 1, shrink: 1)
                        badge
                    }
                    .alignItems(.start)
                    .gap(16)
                } otherwise: {
                    FlexContainer(.column) {
                        avatar
                        name
                        handle
                        bio
                        badge.alignSelf(.start)
                    }
                    .gap(8)
                }
            }
            .padding(16)
        }
    }

    /// The whole screen: a title and a column of cards.
    @MainActor
    final class Screen: Node {
        let title = Text(
            "Nodes, text, state and a breakpoint",
            style: TextStyle(fontName: "Helvetica-Bold", size: 26, color: ink)
        )
        let hint = Text(
            "Resize the window: under 460 points a card turns into a column.",
            style: TextStyle(size: 14, color: muted)
        )
        let cards: [ProfileCard]

        init(profiles: [Profile]) {
            cards = profiles.map { ProfileCard(profile: $0) }
            super.init()
            appearance.background = Color(red: 0.96, green: 0.96, blue: 0.97)
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                title
                hint
                for card in cards { card }
            }
            .gap(16)
            .padding(24)
        }
    }
#endif
