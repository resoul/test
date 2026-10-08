import Foundation
import UIKit
import TrellisCore
import TrellisUIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var instance: ScenarioInstance?
    private var host: TrellisHostView?
    private var currentScenarioIndex = 0

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        self.window = window

        let host = TrellisHostView(frame: windowScene.coordinateSpace.bounds)
        self.host = host

        let vc = PlaygroundViewController(host: host) { [weak self] index in
            self?.switchScenario(to: index)
        }
        window.rootViewController = vc
        window.makeKeyAndVisible()

        // R06 §6.1: `--perf-run` (see `PerfLaunchConfiguration`) skips scenario browsing
        // and runs the native performance harness instead, terminating once it has written
        // its report — every other launch path below is unchanged when the flag is absent.
        if runPerfHarnessIfRequested(host: host, terminate: { exit(0) }) { return }

        switchScenario(to: Scenario.initialIndex)
        vc.selectScenario(Scenario.initialIndex)
        if Scenario.dumpsAccessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AccessibilityDump.print(host: host)
            }
        }
    }

    func switchScenario(to index: Int) {
        let cases = ScenarioName.allCases
        guard index >= 0, index < cases.count else { return }
        currentScenarioIndex = index
        let name = cases[index]

        instance?.teardown()
        host?.detach()

        let newInstance = name.make(mode: Scenario.mode)
        self.instance = newInstance

        if let host {
            host.attach(root: newInstance.root)
            newInstance.onAttach?(host, newInstance.bindings)
        }
    }
}

private final class PlaygroundViewController: UIViewController {
    private let host: TrellisHostView
    private let onScenarioChange: (Int) -> Void
    private let titleLabel = UILabel()
    private var currentIndex = 0

    init(host: TrellisHostView, onScenarioChange: @escaping (Int) -> Void) {
        self.host = host
        self.onScenarioChange = onScenarioChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        host.frame = view.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host)

        let bar = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 16
        bar.clipsToBounds = true
        view.addSubview(bar)

        let prevBtn = UIButton(type: .system)
        prevBtn.setTitle("◀ Prev", for: .normal)
        prevBtn.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)

        let nextBtn = UIButton(type: .system)
        nextBtn.setTitle("Next ▶", for: .normal)
        nextBtn.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        titleLabel.text = ScenarioName.allCases.first?.rawValue ?? ""
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textAlignment = .center

        let overlayBtn = UIButton(type: .system)
        overlayBtn.setTitle("🐞", for: .normal)
        overlayBtn.addTarget(self, action: #selector(overlayTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [prevBtn, titleLabel, overlayBtn, nextBtn])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        bar.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 16
            ),
            bar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -16
            ),
            bar.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -8
            ),
            bar.heightAnchor.constraint(equalToConstant: 44),

            stack.leadingAnchor.constraint(equalTo: bar.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bar.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: bar.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.contentView.bottomAnchor),
        ])
    }

    func selectScenario(_ index: Int) {
        currentIndex = index
        updateTitle()
    }

    @objc private func prevTapped() {
        currentIndex =
            (currentIndex - 1 + ScenarioName.allCases.count) % ScenarioName.allCases.count
        updateTitle()
        onScenarioChange(currentIndex)
    }

    @objc private func nextTapped() {
        currentIndex = (currentIndex + 1) % ScenarioName.allCases.count
        updateTitle()
        onScenarioChange(currentIndex)
    }

    @objc private func overlayTapped() {
        host.isDebugOverlayEnabled.toggle()
        updateTitle()
    }

    private func updateTitle() {
        let name = ScenarioName.allCases[currentIndex].rawValue
        titleLabel.text = host.isDebugOverlayEnabled ? "\(name) 🐞" : name
    }
}
