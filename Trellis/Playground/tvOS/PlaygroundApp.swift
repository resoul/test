import Foundation
import UIKit
import TrellisCore
import TrellisUIKit

// tvOS defect (found live, 2026-09-18, same class as defect #73's iOS fix): this target had no
// `UISceneConfiguration`/`UIWindowSceneDelegate` and relied on observing
// `UIScene.didActivateNotification` to build its window after the fact — with
// `INFOPLIST_KEY_UIApplicationSceneManifest_Generation` now set (`project.pbxproj`), tvOS 16+
// requires a real scene delegate and refuses to launch at all without one
// (`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`), matching #73 exactly.
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

        let vc = TVPlaygroundViewController(host: host) { [weak self] index in
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

    func sceneWillDisconnect(_ scene: UIScene) {
        instance?.teardown()
        instance = nil
        window = nil
    }
}

private final class TVPlaygroundViewController: UIViewController {
    private let host: TrellisHostView
    private let onScenarioChange: (Int) -> Void
    private let banner = UILabel()
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

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        banner.textColor = .white
        banner.font = .boldSystemFont(ofSize: 28)
        banner.textAlignment = .center
        banner.layer.cornerRadius = 14
        banner.clipsToBounds = true
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -30
            ),
            banner.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            banner.heightAnchor.constraint(equalToConstant: 60),
        ])

        updateBanner()
    }

    /// Since A11 the arrows and Select belong to the Trellis host (focus engine + Siri Remote
    /// activation, D44): only Play/Pause switches scenes here, and Menu keeps its system
    /// meaning. The host is the first responder; what it does not consume arrives here.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .playPause {
            currentIndex = (currentIndex + 1) % ScenarioName.allCases.count
            updateBanner()
            onScenarioChange(currentIndex)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    func selectScenario(_ index: Int) {
        currentIndex = index
        updateBanner()
    }

    private func updateBanner() {
        let name = ScenarioName.allCases[currentIndex].rawValue
        banner.text = "\(name) · ▶︎❚❚ next"
    }
}
