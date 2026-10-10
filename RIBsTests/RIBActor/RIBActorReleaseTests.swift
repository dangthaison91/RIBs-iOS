@testable import RIBs
import XCTest

/// The thread of the last release. The RIBActor check does not run in `deinit`, so a detached RIB can be
/// released on any thread.
final class RIBActorReleaseTests: RIBActorTestCase {

    private var root: Router<Interactor>!

    override func setUp() {
        super.setUp()
        let tree = self.tree
        root = onTree {
            let root = Router<Interactor>(interactor: InteractorMock())
            root.ribActorQueue = tree
            root.interactable.activate()
            root.load()
            return root
        }
    }

    override func tearDown() {
        let root = self.root
        self.root = nil
        onTree { root?.children.forEach { root?.detachChild($0) } }
        super.tearDown()
    }

    func test_detachedRouter_releasedOnMain_reportsNoFailure() {
        var deinitWasOnMain: Bool?
        var router: DeinitTrackingRouter? = makeDetachedRouter(childCount: 0)
        router?.onDeinit = { deinitWasOnMain = Thread.isMainThread }

        router = nil

        XCTAssertEqual(deinitWasOnMain, true)
        XCTAssertEqual(failures.messages, [])
    }

    func test_detachedRouterWithChildren_releasedOnMain_reportsNoFailure() {
        var deinitWasOnMain: Bool?
        var router: DeinitTrackingRouter? = makeDetachedRouter(childCount: 3)
        router?.onDeinit = { deinitWasOnMain = Thread.isMainThread }

        router = nil

        XCTAssertEqual(deinitWasOnMain, true)
        XCTAssertEqual(failures.messages, [])
    }

    func test_inactiveInteractor_releasedOnMain_reportsNoFailure() {
        var interactor: InteractorMock? = makeDetachedInteractor()
        weak let weakInteractor = interactor

        interactor = nil

        XCTAssertNil(weakInteractor)
        XCTAssertEqual(failures.messages, [])
    }

    /// No check in `deinit`: an Interactor that is still active resigns on the thread of its last release.
    func test_activeInteractor_releasedOnMain_resignsWithNoFailure() {
        let tree = self.tree
        var resignedOnMain: Bool?
        var interactor: InteractorMock? = onTree {
            let interactor = InteractorMock()
            interactor.ribActorQueue = tree
            interactor.activate()
            return interactor
        }
        interactor?.willResignActiveHandler = { resignedOnMain = Thread.isMainThread }
        drainTree()

        interactor = nil

        XCTAssertEqual(resignedOnMain, true)
        XCTAssertEqual(failures.messages, [])
    }

    /// The check stays on for the children of a Router that is released while it is active: the child Interactor
    /// is still active and resigns on the wrong thread.
    func test_activeRouterWithActiveChild_releasedOnMain_reportsFailure() {
        let tree = self.tree
        var routers: [Router<Interactor>] = [onTree {
            let router = Router<Interactor>(interactor: InteractorMock())
            router.ribActorQueue = tree
            router.interactable.activate()
            router.load()
            router.attachChild(Router<Interactor>(interactor: InteractorMock()))
            return router
        }]
        drainTree()
        XCTAssertEqual(failures.messages, [])

        routers.removeAll()

        XCTAssertEqual(failures.messages.first?.contains("deactivate"), true, "\(failures.messages)")
    }

    // MARK: - Private

    private func makeDetachedRouter(childCount: Int) -> DeinitTrackingRouter {
        let root = self.root!
        let router: DeinitTrackingRouter = onTree {
            let router = DeinitTrackingRouter(interactor: InteractorMock())
            root.attachChild(router)
            for _ in 0 ..< childCount {
                router.attachChild(Router<Interactor>(interactor: InteractorMock()))
            }
            root.detachChild(router)
            return router
        }
        drainTree()
        return router
    }

    private func makeDetachedInteractor() -> InteractorMock {
        let root = self.root!
        let interactor: InteractorMock = onTree {
            let interactor = InteractorMock()
            let router = Router<Interactor>(interactor: interactor)
            root.attachChild(router)
            root.detachChild(router)
            return interactor
        }
        drainTree()
        return interactor
    }
}
