import AppShell
import Foundation
import LayoutCore
import Nodes
import NodesRender
import StateCore
import SyncDemo

/// `SYNC_PROBE=1` for UI tests and for looking at the sync demo: a list that lives in a database and is
/// kept in step with a server in memory — fetched over HTTP, followed live over a socket — with the
/// order of the list kept in the preferences and a file kept with an item. Buttons make the server do
/// what a real one does — change something, drop the connection, go away — and a line says what the
/// screen knows: the connection, the refresh, and the last problem.
@MainActor
enum SyncProbe {
    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Sync")
    }

    private final class Page: Node {
        /// What the page works with, once the database is open.
        private struct Ready {
            let session: DemoSession
            let model: ItemsModel
        }

        private let ready = State<Ready?>(nil)
        private let heading = Text("Opening…", style: TextStyle(size: 15))
        private let problem = Text("", style: TextStyle(size: 15))
        private let rowTexts = (0..<10).map { _ in Text("", style: TextStyle(size: 17)) }
        private let refresh = Button("Refresh") {}
        private let add = Button("Add item") {}
        private let sort = Button("Sort: title") {}
        private let attach = Button("Attach to first") {}
        private let another = Button("Another user adds") {}
        private let drop = Button("Drop connection") {}
        private let offline = Button("Go offline") {}
        private let signOut = Button("Sign out") {}
        private var addedCount = 0
        private var isOffline = false

        override init() {
            super.init()
            wire()
            Task { [weak self] in
                guard let session = try? await DemoSession.make() else { return }

                let model = session.makeModel()
                self?.ready.value = Ready(session: session, model: model)
                model.start()
            }
        }

        private func wire() {
            refresh.onTap = { [weak self] in
                guard let model = self?.ready.value?.model else { return }

                Task { await model.refresh() }
            }
            add.onTap = { [weak self] in
                guard let self, let model = ready.value?.model else { return }

                addedCount += 1
                let title = "New item \(addedCount)"
                Task { await model.add(title: title) }
            }
            sort.onTap = { [weak self] in
                guard let model = self?.ready.value?.model else { return }

                let next: ItemSort = model.sort.value == .title ? .newest : .title
                Task { await model.setSort(next) }
            }
            attach.onTap = { [weak self] in
                guard let model = self?.ready.value?.model, let first = model.rows.value.first else { return }

                Task {
                    await model.attach(name: "note.txt", data: Data("A note kept on this device".utf8), to: first.id)
                }
            }
            another.onTap = { [weak self] in
                guard let server = self?.ready.value?.session.server else { return }

                Task { await server.externalUpsert(title: "From another user") }
            }
            drop.onTap = { [weak self] in
                guard let server = self?.ready.value?.session.server else { return }

                Task { await server.simulateDroppedConnections() }
            }
            offline.onTap = { [weak self] in
                guard let self, let server = ready.value?.session.server else { return }

                isOffline.toggle()
                offline.label.text = isOffline ? "Go online" : "Go offline"
                let offline = isOffline
                Task { await server.setOnline(!offline) }
            }
            signOut.onTap = { [weak self] in
                guard let repository = self?.ready.value?.session.repository else { return }

                Task { try? await repository.signOut() }
            }
        }

        override func update() {
            guard let model = ready.value?.model else { return }

            let rows = model.rows.value
            heading.text =
                "Connection: \(describe(model.connection.value)) · "
                + "Refresh: \(describe(model.phase.value)) · \(rows.count) items · "
                + "Sort: \(model.sort.value.rawValue)"
            problem.text = model.problem.value ?? ""
            sort.label.text = "Sort: \(model.sort.value == .title ? "newest" : "title")"
            for (index, text) in rowTexts.enumerated() {
                guard index < rows.count else {
                    text.text = ""
                    continue
                }

                let row = rows[index]
                let file = row.attachment.map { " · \($0.name) \($0.size) bytes" } ?? ""
                text.text = "\(row.title) (rev \(row.revision))\(file)"
            }
        }

        private func describe(_ status: ConnectionStatus) -> String {
            switch status {
            case .offline: "offline"
            case .connecting: "connecting"
            case .live: "live"
            case .reconnecting: "reconnecting"
            case .failed(let message): "failed — \(message)"
            }
        }

        private func describe(_ phase: LoadPhase) -> String {
            switch phase {
            case .idle: "idle"
            case .loading: "loading"
            case .loaded: "loaded"
            case .failed(let message): "failed — \(message)"
            }
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                heading
                problem
                FlexContainer(.column) {
                    for row in rowTexts { row }
                }
                .gap(4)
                FlexContainer(.row) {
                    refresh
                    add
                    sort
                    attach
                }
                .gap(8)
                FlexContainer(.row) {
                    another
                    drop
                    offline
                    signOut
                }
                .gap(8)
            }
            .gap(12)
            .padding(24)
            .alignItems(.start)
        }
    }
}
