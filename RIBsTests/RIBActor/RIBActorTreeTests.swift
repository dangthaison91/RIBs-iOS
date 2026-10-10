@testable import RIBs
import RxSwift
import UIKit
import XCTest

// A RIB tree that runs on one serial RIBActor queue. Main keeps its run loop running, creates the view controllers
// and calls them; it never calls a Router or an Interactor. The real `LeakDetector` is on with its assertion
// armed, so a false leak report stops the test process.

private protocol TreePresentable: AnyObject {
    func show(_ text: String)
}

private final class TreeViewController: UIViewController, ViewControllable, TreePresentable {
    private let label = UILabel()
    private(set) var showWasOffMain = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(label)
    }

    func show(_ text: String) {
        if !Thread.isMainThread { showWasOffMain = true }
        label.text = text
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
}

private final class TreeWorker: Worker {
    private let scheduler: SerialDispatchQueueScheduler
    private let log: QueueLog
    var ticks = 0
    var onFirstTick: (() -> Void)?

    init(tree: DispatchQueue, log: QueueLog) {
        self.log = log
        scheduler = SerialDispatchQueueScheduler(queue: tree, internalSerialQueueName: "ribs.tests.tree.rx")
    }

    override func didStart(_ interactorScope: InteractorScope) {
        log.note("worker.didStart")
        Observable<Int>.interval(.milliseconds(1), scheduler: scheduler)
            .subscribe(onNext: { [weak self] _ in
                guard let self else { return }
                self.log.note("worker.tick")
                self.ticks += 1
                if self.ticks == 1 { self.onFirstTick?() }
            })
            .disposeOnStop(self)
    }

    override func didStop() {
        log.note("worker.didStop")
    }
}

private final class TreeInteractor: Interactor {
    private let log: QueueLog
    var events: [String] = []
    var worker: TreeWorker?

    init(log: QueueLog) {
        self.log = log
    }

    override func didBecomeActive() {
        super.didBecomeActive()
        events.append("active")
        log.note("didBecomeActive")
        worker?.start(self)
    }

    override func willResignActive() {
        super.willResignActive()
        events.append("resign")
        log.note("willResignActive")
    }
}

private final class TreeViewfulInteractor: PresentableInteractor<TreePresentable> {
    private let log: QueueLog
    var events: [String] = []

    init(presenter: TreePresentable, log: QueueLog) {
        self.log = log
        super.init(presenter: presenter)
    }

    override func didBecomeActive() {
        super.didBecomeActive()
        events.append("active")
        log.note("didBecomeActive")
        let presenter = self.presenter
        DispatchQueue.main.async { presenter.show("active") }
    }

    override func willResignActive() {
        super.willResignActive()
        events.append("resign")
        log.note("willResignActive")
    }
}

private final class TreeComponent: Component<EmptyDependency> {
    var service: NSObject { shared { NSObject() } }
}

private typealias TreeRouter = Router<TreeInteractor>
private typealias TreeViewableRouter = ViewableRouter<TreeViewfulInteractor, TreeViewController>

/// Fields are read and written on the RIBActor queue only.
private final class TreeState {
    var root: TreeRouter?
    var parent: TreeRouter?
    var child: TreeRouter?
    var worker: TreeWorker?
    var problems: [String] = []

    func check(_ condition: Bool, _ message: String) {
        if !condition { problems.append(message) }
    }
}

final class RIBActorTreeTests: RIBActorTestCase {

    static let iterations = 300

    private let state = TreeState()
    private let log = QueueLog()
    private var liveViewControllers: [Int: TreeViewController] = [:]
    private var anyShowWasOffMain = false
    private var heartbeat: Timer?
    private var heartbeatCount = 0
    private let heartbeatHost = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    private let heartbeatLabel = UILabel()

    override func setUp() {
        super.setUp()
        LeakDetector.disableLeakDetectorOverride = false
        LeakDetector.setInstance(LeakDetector())
        startMainHeartbeat()
        let state = self.state, tree = self.tree, log = self.log
        onTree {
            let root = TreeRouter(interactor: TreeInteractor(log: log))
            root.ribActorQueue = tree
            root.interactable.activate()
            root.load()
            state.root = root
        }
    }

    // MARK: - Tests

    /// The view controller, the Interactor and the Router are built on main and attached on the RIBActor queue.
    func test_viewfulChild_builtOnMain_attachedOnRIBActorQueue() {
        let state = self.state, tree = self.tree, log = self.log
        iterate { index, done in
            let viewController = TreeViewController()
            viewController.loadViewIfNeeded()
            liveViewControllers[index] = viewController
            let interactor = TreeViewfulInteractor(presenter: viewController, log: log)
            let router = TreeViewableRouter(interactor: interactor, viewController: viewController)
            tree.async {
                let root = state.root!
                root.attachChild(router)
                state.check(router.interactor.isActive, "inactive after attach")
                state.check(router.interactor.events == ["active"], "events \(router.interactor.events)")
                state.check(root.children.count == 1, "children \(root.children.count)")
                DispatchQueue.main.async {
                    self.liveViewControllers[index]?.show("attached \(index)")
                    tree.async {
                        let root = state.root!
                        root.detachChild(root.children[0])
                        state.check(root.children.isEmpty, "child left")
                        DispatchQueue.main.async {
                            self.releaseViewController(index)
                            done.fulfill()
                        }
                    }
                }
            }
        }
        finish(expectedActivations: Self.iterations + 1)
    }

    /// The view controller is built on main first; the Component, the Interactor and the Router are built and
    /// attached on the RIBActor queue.
    func test_viewfulChild_viewOnMain_logicBuiltOnRIBActorQueue() {
        let state = self.state, tree = self.tree, log = self.log
        iterate { index, done in
            let viewController = TreeViewController()
            viewController.loadViewIfNeeded()
            viewController.show("placeholder")
            liveViewControllers[index] = viewController
            tree.async {
                let component = TreeComponent(dependency: EmptyComponent())
                _ = component.service
                let interactor = TreeViewfulInteractor(presenter: viewController, log: log)
                let router = TreeViewableRouter(interactor: interactor, viewController: viewController)
                let root = state.root!
                root.attachChild(router)
                state.check(interactor.isActive, "inactive after attach")
                state.check(interactor.events == ["active"], "events \(interactor.events)")
                DispatchQueue.main.async {
                    self.liveViewControllers[index]?.show("attached \(index)")
                    tree.async {
                        let root = state.root!
                        root.detachChild(root.children[0])
                        state.check(root.children.isEmpty, "child left")
                        DispatchQueue.main.async {
                            self.releaseViewController(index)
                            done.fulfill()
                        }
                    }
                }
            }
        }
        finish(expectedActivations: Self.iterations + 1)
    }

    /// Main queues the detach job while the attach job still runs.
    func test_detach_queuedWhileTheAttachJobRuns() {
        let state = self.state, tree = self.tree, log = self.log
        iterate { _, done in
            let queued = DispatchSemaphore(value: 0)
            tree.async {
                DispatchQueue.main.async {
                    tree.async {
                        let root = state.root!
                        let children = root.children.compactMap { $0 as? TreeRouter }
                        state.check(children.count == 8, "children before detach \(children.count)")
                        for child in children { root.detachChild(child) }
                        state.check(root.children.isEmpty, "child left")
                        for child in children {
                            state.check(child.interactor.events == ["active", "resign"], "events \(child.interactor.events)")
                            state.check(!child.interactor.isActive, "active after detach")
                        }
                        DispatchQueue.main.async { done.fulfill() }
                    }
                    queued.signal()
                }
                state.check(queued.wait(timeout: .now() + 5) == .success, "detach job not queued in time")
                let root = state.root!
                for _ in 0 ..< 8 {
                    root.attachChild(TreeRouter(interactor: TreeInteractor(log: log)))
                }
            }
        }
        finish(expectedActivations: Self.iterations * 8 + 1)
    }

    /// root -> parent -> child. The parent is detached while a grandchild attach is queued behind it. The tree
    /// queue orders the two jobs; it does not cancel the queued one, so the grandchild becomes active under an
    /// inactive child. A queued route change needs its own "is my Interactor still active" guard.
    func test_threeLevels_parentDetached_queuedGrandchildAttachStillRuns() {
        let state = self.state, tree = self.tree, log = self.log
        iterate { _, done in
            let queued = DispatchSemaphore(value: 0)
            tree.async {
                let root = state.root!
                let parent = TreeRouter(interactor: TreeInteractor(log: log))
                root.attachChild(parent)
                let child = TreeRouter(interactor: TreeInteractor(log: log))
                parent.attachChild(child)
                state.parent = parent
                state.child = child
                DispatchQueue.main.async {
                    tree.async {
                        let child = state.child!
                        let grandchild = TreeRouter(interactor: TreeInteractor(log: log))
                        child.attachChild(grandchild)
                        state.check(!child.interactor.isActive, "child active when the queued attach ran")
                        state.check(grandchild.interactor.isActive, "grandchild not active")
                        state.check(child.children.count == 1, "grandchild lost")
                        state.parent = nil
                        state.child = nil
                        DispatchQueue.main.async { done.fulfill() }
                    }
                    queued.signal()
                }
                state.check(queued.wait(timeout: .now() + 5) == .success, "grandchild attach not queued in time")
                root.detachChild(parent)
                state.check(!parent.interactor.isActive && !child.interactor.isActive, "subtree still active")
                state.check(child.interactor.events == ["active", "resign"], "child events \(child.interactor.events)")
            }
        }
        finish(expectedActivations: Self.iterations * 3 + 1)
    }

    /// A Worker started in `didBecomeActive`, with an Rx interval on a scheduler whose queue targets the tree
    /// queue. `attachChild` from the Rx closure passes the check.
    func test_worker_startedInDidBecomeActive_runsOnRIBActorQueue() {
        let state = self.state, tree = self.tree, log = self.log
        iterate { _, done in
            tree.async {
                let root = state.root!
                let interactor = TreeInteractor(log: log)
                let worker = TreeWorker(tree: tree, log: log)
                interactor.worker = worker
                let child = TreeRouter(interactor: interactor)
                worker.onFirstTick = { [weak child] in
                    child?.attachChild(TreeRouter(interactor: TreeInteractor(log: log)))
                }
                root.attachChild(child)
                state.check(worker.isStarted, "worker not started")
                state.child = child
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(4)) {
                    tree.async {
                        let child = state.child!
                        let worker = child.interactor.worker!
                        state.root!.detachChild(child)
                        let ticksAtStop = worker.ticks
                        state.child = nil
                        state.worker = worker
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(3)) {
                            tree.async {
                                state.check(state.worker!.ticks == ticksAtStop, "tick after stop")
                                state.worker = nil
                                DispatchQueue.main.async { done.fulfill() }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(log.queues(of: "worker.didStart"), [Self.treeLabel: Self.iterations])
        XCTAssertEqual(log.queues(of: "worker.didStop"), [Self.treeLabel: Self.iterations])
        XCTAssertEqual(Array(log.queues(of: "worker.tick").keys), ["ribs.tests.tree.rx"])
        finish(expectedActivations: nil)
    }

    /// The Router holds the last reference to the view controller and is released on the RIBActor queue.
    func test_viewfulChild_routerHoldsTheLastViewControllerReference() {
        let state = self.state, tree = self.tree, log = self.log
        iterate { _, done in
            let viewController = TreeViewController()
            viewController.loadViewIfNeeded()
            tree.async {
                let interactor = TreeViewfulInteractor(presenter: viewController, log: log)
                let router = TreeViewableRouter(interactor: interactor, viewController: viewController)
                state.root!.attachChild(router)
                DispatchQueue.main.async {
                    tree.async {
                        let root = state.root!
                        root.detachChild(root.children[0])
                        DispatchQueue.main.async { done.fulfill() }
                    }
                }
            }
        }
        finish(expectedActivations: Self.iterations + 1)
    }

    // MARK: - Private

    private func startMainHeartbeat() {
        heartbeatHost.addSubview(heartbeatLabel)
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.heartbeatCount += 1
            self.heartbeatLabel.text = "\(self.heartbeatCount)"
            self.heartbeatHost.setNeedsLayout()
            self.heartbeatHost.layoutIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func iterate(_ body: (Int, XCTestExpectation) -> Void) {
        for index in 0 ..< Self.iterations {
            let done = expectation(description: "iteration \(index)")
            body(index, done)
            wait(for: [done], timeout: 20)
        }
    }

    private func releaseViewController(_ index: Int) {
        if liveViewControllers[index]?.showWasOffMain == true { anyShowWasOffMain = true }
        liveViewControllers[index] = nil
    }

    /// Releases the tree on the RIBActor queue, waits for every pending leak check, then asserts.
    private func finish(expectedActivations: Int?) {
        let state = self.state
        let problems: [String] = onTree {
            state.parent = nil
            state.child = nil
            state.worker = nil
            state.root = nil
            return state.problems
        }
        waitForLeakChecks()
        heartbeat?.invalidate()

        XCTAssertEqual(problems, [])
        XCTAssertEqual(failures.messages, [])
        XCTAssertFalse(anyShowWasOffMain)
        XCTAssertGreaterThan(heartbeatCount, 0)
        let activations = log.queues(of: "didBecomeActive")
        XCTAssertEqual(Array(activations.keys.filter { !$0.hasPrefix(Self.treeLabel) }), [])
        if let expectedActivations {
            XCTAssertEqual(activations[Self.treeLabel], expectedActivations)
        }
        let resigns = log.queues(of: "willResignActive")
        XCTAssertEqual(Array(resigns.keys.filter { !$0.hasPrefix(Self.treeLabel) }), [])
    }

    /// A false leak report asserts in the detector, so reaching the end of this wait means 0 leak reports.
    private func waitForLeakChecks() {
        let completed = expectation(description: "leak checks")
        completed.assertForOverFulfill = false
        let disposable = LeakDetector.instance.status
            .filter { $0 == .DidComplete }
            .subscribe(onNext: { _ in completed.fulfill() })
        wait(for: [completed], timeout: 60)
        disposable.dispose()
    }
}
