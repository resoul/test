import AppShell
import Foundation
import LayoutCore
import NetworkCore
import NetworkFoundation
import Nodes
import NodesRender
import StateCore

/// `BACKGROUND_PROBE=1`: background transfers across the app's endings. The transfers object is made
/// when the app starts, before any screen, as the system needs: it may have results for the app the
/// moment it runs again. `BACKGROUND_URL` with `BACKGROUND_SCHEDULE=1` schedules a download of that
/// address; `BACKGROUND_RESET=1` first forgets everything an earlier run left. The screen says how
/// many transfers are running and what the last outcome was, and a button acknowledges it, so a test
/// can end the app between the steps and see what is left for the next launch.
@MainActor
enum BackgroundProbe {
    static let identifier = "demo.background-probe"

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent(
            "background-probe",
            isDirectory: true
        )
    }

    private static var transfers: URLSessionBackgroundTransfers?
    /// What launching has to finish before the screen listens: forgetting what an earlier run left,
    /// and scheduling.
    private static var setup: Task<Void, Never>?

    /// Makes the transfers object, and schedules the download the environment asks for.
    static func start(_ environment: [String: String]) {
        guard environment["BACKGROUND_PROBE"] != nil else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transfers = URLSessionBackgroundTransfers(identifier: identifier, directory: directory)
        self.transfers = transfers
        let reset = environment["BACKGROUND_RESET"] != nil
        let url =
            environment["BACKGROUND_SCHEDULE"] != nil
            ? environment["BACKGROUND_URL"].flatMap(URL.init(string:)) : nil
        setup = Task {
            if reset {
                // A transfer an earlier run left is still the system's, and would keep its name from
                // being scheduled again, so it is cancelled; the outcomes that cancelling leaves are
                // written before they are swept away with the rest.
                for transfer in await transfers.transfers() { await transfers.cancel(transfer.id) }
                while !(await transfers.transfers().isEmpty) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                try? await Task.sleep(for: .seconds(1))
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            guard let url else { return }

            _ = try? await transfers.download(
                HTTPRequest(.get, url),
                to: "probe.bin",
                id: "relaunch-probe"
            )
        }
    }

    /// Passes the system's completion to the transfers, as an app delegate's call would.
    static func install(on shell: Shell) {
        guard let transfers else { return }

        shell.backgroundSessionHandler = { identifier, completion in
            if identifier == transfers.identifier {
                transfers.finishingEvents(completion)
            } else {
                completion()
            }
        }
    }

    static func content() -> any SceneContent {
        NodeScreen(Page(), title: "Background")
    }

    private final class Page: Node {
        private let running = State("running: ?")
        private let outcome = State("outcome: none")
        private let runningText = Text("", style: TextStyle(size: 17))
        private let outcomeText = Text("", style: TextStyle(size: 17))
        private let acknowledge = Button("Acknowledge") {}
        private var lastID: BackgroundTransferID?
        private var tasks: [Task<Void, Never>] = []

        override init() {
            super.init()
            guard let transfers = BackgroundProbe.transfers else { return }

            acknowledge.onTap = { [weak self] in
                guard let id = self?.lastID else { return }

                Task { await transfers.acknowledge(id) }
                self?.outcome.value = "outcome: acknowledged"
            }
            tasks = [
                Task { [weak self] in
                    await BackgroundProbe.setup?.value
                    for await next in transfers.outcomes() {
                        let size =
                            (try? next.file.map {
                                try FileManager.default.attributesOfItem(atPath: $0.path)[.size]
                                    as? Int ?? -1
                            }) ?? nil
                        self?.lastID = next.id
                        self?.outcome.value =
                            "outcome: \(next.id) status=\(next.status ?? 0) bytes=\(size ?? -1) "
                            + "failure=\(next.failure?.kind.rawValue ?? "none")"
                    }
                },
                Task { [weak self] in
                    await BackgroundProbe.setup?.value
                    while !Task.isCancelled {
                        let count = await transfers.transfers().count
                        self?.running.value = "running: \(count)"
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                },
            ]
        }

        deinit {
            for task in tasks { task.cancel() }
        }

        override func update() {
            runningText.text = running.value
            outcomeText.text = outcome.value
        }

        override func layoutSpec() -> LayoutSpec? {
            FlexContainer(.column) {
                runningText
                outcomeText
                acknowledge
            }
            .gap(12)
            .padding(24)
            .alignItems(.start)
        }
    }
}
