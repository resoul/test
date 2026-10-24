#if canImport(UIKit)
    import UIKit

    @MainActor
    final class NativeFeedController: FeedController, UITableViewDataSource,
        UITableViewDataSourcePrefetching
    {
        private let table = UITableView(frame: .zero, style: .plain)
        private let loader = NativeImageLoader()
        private lazy var header = NativeProfileHeader(posts: session.posts, loader: loader)
        private var prefetches: [IndexPath: Task<Void, Never>] = [:]
        private var displayedRevision = -1
        private var headerWidth = 0.0

        override func viewDidLoad() {
            super.viewDidLoad()
            table.translatesAutoresizingMaskIntoConstraints = false
            table.backgroundColor = FeedStyle.ui(FeedStyle.background)
            table.separatorStyle = .none
            table.rowHeight = UITableView.automaticDimension
            table.estimatedRowHeight = 560
            table.dataSource = self
            table.prefetchDataSource = self
            table.accessibilityIdentifier = "native-feed"
            table.register(NativePostCell.self, forCellReuseIdentifier: "post")
            view.addSubview(table)
            NSLayoutConstraint.activate([
                table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                table.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            ])
            contentChanged()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateHeader()
        }

        override func contentChanged() {
            super.contentChanged()
            guard isViewLoaded else { return }
            let changed = displayedRevision != session.revision
            displayedRevision = session.revision
            if changed {
                for task in prefetches.values { task.cancel() }
                prefetches = [:]
                table.setContentOffset(.zero, animated: false)
            }
            header.countLabel.text = "Лента · \(session.count) записей"
            if changed {
                table.reloadData()
                headerWidth = 0
                updateHeader()
            } else {
                for path in table.indexPathsForVisibleRows ?? [] {
                    (table.cellForRow(at: path) as? NativePostCell)?.updateSaved(
                        session.saved.contains(session.posts[path.row].id)
                    )
                }
            }
        }

        private func updateHeader() {
            let width = table.bounds.width
            guard width > 0, headerWidth != width else { return }
            headerWidth = width
            header.frame.size.width = width
            let height = header.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            header.frame = CGRect(x: 0, y: 0, width: width, height: height)
            table.tableHeaderView = header
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            session.posts.count
        }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
            -> UITableViewCell
        {
            let cell =
                tableView.dequeueReusableCell(withIdentifier: "post", for: indexPath)
                as! NativePostCell
            let post = session.posts[indexPath.row]
            let pixels = Int(
                max(320, tableView.bounds.width - 32) * (view.window?.screen.scale ?? 2)
            )
            cell.show(post, saved: session.saved.contains(post.id), pixels: pixels, loader: loader)
            { [weak self] in
                self?.session.toggleSaved(post.id)
            }
            return cell
        }

        func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
            let pixels = Int(
                max(320, tableView.bounds.width - 32) * (view.window?.screen.scale ?? 2)
            )
            for path in indexPaths
            where session.posts.indices.contains(path.row) && prefetches[path] == nil {
                let url = session.posts[path.row].imageURL
                let loader = loader
                prefetches[path] = Task { _ = try? await loader.image(url, pixels: pixels) }
            }
        }
        func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath])
        {
            for path in indexPaths { prefetches.removeValue(forKey: path)?.cancel() }
        }
    }

    @MainActor
    private func label(
        _ text: String = "",
        size: Double,
        weight: UIFont.Weight = .regular,
        muted: Bool = false
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = FeedStyle.font(size, weight: weight)
        label.textColor = FeedStyle.ui(muted ? FeedStyle.muted : FeedStyle.ink)
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    @MainActor
    private final class NativePostCell: UITableViewCell {
        private let author = label("Анна Лесная", size: 13, weight: .semibold)
        private let date = label(size: 11, muted: true)
        private let titleLabel = label(size: 21, weight: .semibold)
        private let body = label(size: FeedStyle.bodySize)
        private let place = label(size: 12, muted: true)
        private let photo = UIImageView()
        private let likes = label(size: 13, muted: true)
        private let save = UIButton(type: .system)
        private var task: Task<Void, Never>?
        private var itemID: Int?
        private var action: (@MainActor () -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            backgroundColor = .clear
            selectionStyle = .none
            let card = UIView()
            card.backgroundColor = .white
            card.layer.cornerRadius = 20
            card.clipsToBounds = true
            card.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(card)
            let authorStack = UIStackView(arrangedSubviews: [author, date])
            authorStack.axis = .vertical
            authorStack.spacing = 3
            let avatar = label("АЛ", size: 12, weight: .semibold)
            avatar.textAlignment = .center
            avatar.backgroundColor = FeedStyle.ui(FeedStyle.background)
            avatar.layer.cornerRadius = 17
            avatar.clipsToBounds = true
            let authorRow = UIStackView(arrangedSubviews: [avatar, authorStack, UIView()])
            authorRow.spacing = 10
            authorRow.alignment = .center
            avatar.widthAnchor.constraint(equalToConstant: 34).isActive = true
            avatar.heightAnchor.constraint(equalToConstant: 34).isActive = true
            let copy = UIStackView(arrangedSubviews: [authorRow, titleLabel, body, place])
            copy.axis = .vertical
            copy.spacing = 12
            photo.contentMode = .scaleAspectFill
            photo.clipsToBounds = true
            photo.backgroundColor = FeedStyle.ui(FeedStyle.background)
            photo.isAccessibilityElement = true
            photo.accessibilityLabel = "Иллюстрация маршрута"
            let footer = UIStackView(arrangedSubviews: [likes, UIView(), save])
            footer.alignment = .center
            save.tintColor = FeedStyle.ui(FeedStyle.accent)
            save.titleLabel?.font = FeedStyle.font(13, weight: .medium)
            save.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
            for subview in [copy, photo, footer] {
                subview.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(subview)
            }
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
                card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
                card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                copy.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
                copy.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                copy.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                photo.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 14),
                photo.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                photo.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                photo.heightAnchor.constraint(
                    equalTo: photo.widthAnchor,
                    multiplier: 1 / FeedStyle.photoRatio
                ),
                footer.topAnchor.constraint(equalTo: photo.bottomAnchor, constant: 12),
                footer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                footer.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                footer.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                save.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ])
        }
        required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }
        override func prepareForReuse() {
            super.prepareForReuse()
            task?.cancel()
            photo.image = nil
            itemID = nil
        }
        func show(
            _ post: FeedPost,
            saved: Bool,
            pixels: Int,
            loader: NativeImageLoader,
            action: @escaping @MainActor () -> Void
        ) {
            task?.cancel()
            itemID = post.id
            self.action = action
            titleLabel.text = post.title
            titleLabel.accessibilityLabel = post.accessibilityTitle
            date.text = post.date
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            body.attributedText = NSAttributedString(
                string: post.body,
                attributes: [
                    .font: FeedStyle.font(FeedStyle.bodySize), .paragraphStyle: paragraph,
                    .foregroundColor: FeedStyle.ui(FeedStyle.ink),
                ]
            )
            place.text = "↗ " + post.place
            likes.text = "♡ \(post.likes)     ◌ \(12 + post.id % 38)"
            updateSaved(saved)
            save.accessibilityIdentifier = "save-\(post.id)"
            photo.image = nil
            task = Task { [weak self] in
                do {
                    let bitmap = try await loader.image(post.imageURL, pixels: pixels)
                    guard !Task.isCancelled, let self, self.itemID == post.id else { return }
                    self.photo.image = UIImage(cgImage: bitmap)
                } catch {}
            }
        }
        func updateSaved(_ saved: Bool) {
            save.setTitle(saved ? "Сохранено ✓" : "Сохранить", for: .normal)
        }
        @objc private func saveTapped() { action?() }
    }

    @MainActor
    private final class NativeProfileHeader: UIView, UICollectionViewDataSource {
        let countLabel = label(size: 17, weight: .semibold)
        private let posts: [FeedPost]
        private let loader: NativeImageLoader
        private let albums: UICollectionView

        init(posts: [FeedPost], loader: NativeImageLoader) {
            self.posts = Array(posts.prefix(6))
            self.loader = loader
            let layout = UICollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            layout.itemSize = CGSize(width: 154, height: 126)
            layout.minimumLineSpacing = 12
            layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            albums = UICollectionView(frame: .zero, collectionViewLayout: layout)
            super.init(frame: .zero)
            let avatar = label("АЛ", size: 22, weight: .semibold)
            avatar.textAlignment = .center
            avatar.backgroundColor = FeedStyle.ui(FeedStyle.accent)
            avatar.textColor = .white
            avatar.layer.cornerRadius = 30
            avatar.clipsToBounds = true
            NSLayoutConstraint.activate([
                avatar.widthAnchor.constraint(equalToConstant: 60),
                avatar.heightAnchor.constraint(equalToConstant: 60),
            ])
            let name = UIStackView(arrangedSubviews: [
                label("Анна Лесная", size: 24, weight: .bold),
                label("Тбилиси, Грузия · @anna.outside", size: 12, muted: true),
            ])
            name.axis = .vertical
            name.spacing = 5
            let profile = UIStackView(arrangedSubviews: [avatar, name, UIView()])
            profile.spacing = 14
            profile.alignment = .center
            let stats = label(
                "48 поездок     126 мест     8,4 тыс. друзей",
                size: 13,
                weight: .medium
            )
            let bio = label(
                "Собираю места, в которые хочется вернуться.\nМаршруты, свет и немного тишины.",
                size: 14,
                muted: true
            )
            let info = UIStackView(arrangedSubviews: [
                profile, bio, stats, label("Избранные маршруты", size: 17, weight: .semibold),
            ])
            info.axis = .vertical
            info.spacing = 14
            albums.backgroundColor = .clear
            albums.showsHorizontalScrollIndicator = false
            albums.accessibilityIdentifier = "native-albums"
            albums.dataSource = self
            albums.register(NativeAlbumCell.self, forCellWithReuseIdentifier: "album")
            for item in [info, albums, countLabel] {
                item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item)
            }
            NSLayoutConstraint.activate([
                info.topAnchor.constraint(equalTo: topAnchor, constant: 16),
                info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                albums.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 14),
                albums.leadingAnchor.constraint(equalTo: leadingAnchor),
                albums.trailingAnchor.constraint(equalTo: trailingAnchor),
                albums.heightAnchor.constraint(equalToConstant: 126),
                countLabel.topAnchor.constraint(equalTo: albums.bottomAnchor, constant: 22),
                countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
                countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            ])
        }
        required init?(coder: NSCoder) { fatalError("Use init(posts:loader:)") }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
            -> Int
        { posts.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
            -> UICollectionViewCell
        {
            let cell =
                collectionView.dequeueReusableCell(withReuseIdentifier: "album", for: indexPath)
                as! NativeAlbumCell
            cell.show(
                posts[indexPath.item],
                loader: loader,
                scale: Double(window?.screen.scale ?? 2)
            )
            return cell
        }
    }

    @MainActor
    private final class NativeAlbumCell: UICollectionViewCell {
        private let photo = UIImageView()
        private let title = label(size: 12, weight: .medium)
        private var task: Task<Void, Never>?
        override init(frame: CGRect) {
            super.init(frame: frame)
            photo.contentMode = .scaleAspectFill
            photo.layer.cornerRadius = 14
            photo.clipsToBounds = true
            photo.backgroundColor = FeedStyle.ui(FeedStyle.line)
            title.numberOfLines = 1
            for view in [photo, title] {
                view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view)
            }
            NSLayoutConstraint.activate([
                photo.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                photo.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                photo.topAnchor.constraint(equalTo: contentView.topAnchor),
                photo.heightAnchor.constraint(equalToConstant: 96),
                title.topAnchor.constraint(equalTo: photo.bottomAnchor, constant: 8),
                title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
                title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
        override func prepareForReuse() {
            super.prepareForReuse(); task?.cancel(); photo.image = nil
        }
        func show(_ post: FeedPost, loader: NativeImageLoader, scale: Double) {
            task?.cancel()
            title.text = post.place
            task = Task { [weak self] in
                guard let image = try? await loader.image(post.imageURL, pixels: Int(154 * scale)),
                    !Task.isCancelled
                else { return }
                self?.photo.image = UIImage(cgImage: image)
            }
        }
    }
#endif
