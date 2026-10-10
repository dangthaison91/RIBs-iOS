import CwlPreconditionTesting
@testable import RIBs
import XCTest

final class RIBActorCheckTests: RIBActorTestCase {

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

    // MARK: - A wrong-thread call is reported

    func test_attachChild_offRIBActorQueue_reportsFailure() {
        root.attachChild(Router<Interactor>(interactor: InteractorMock()))

        XCTAssertEqual(failures.messages.first?.contains("attachChild"), true, "\(failures.messages)")
        XCTAssertEqual(failures.messages.first?.contains(Self.treeLabel), true, "\(failures.messages)")
    }

    func test_detachChild_offRIBActorQueue_reportsFailure() {
        let child = Router<Interactor>(interactor: InteractorMock())
        let root = self.root!
        onTree { root.attachChild(child) }
        XCTAssertEqual(failures.messages, [])

        root.detachChild(child)

        XCTAssertEqual(failures.messages.first?.contains("detachChild"), true, "\(failures.messages)")
    }

    func test_load_offRIBActorQueue_reportsFailure() {
        let router = Router<Interactor>(interactor: InteractorMock())
        router.ribActorQueue = tree

        router.load()

        XCTAssertEqual(failures.messages.count, 1)
        XCTAssertEqual(failures.messages.first?.contains("load"), true, "\(failures.messages)")
    }

    func test_activate_offRIBActorQueue_reportsFailure() {
        let interactor = InteractorMock()
        let router = Router<Interactor>(interactor: interactor)
        router.ribActorQueue = tree

        interactor.activate()

        XCTAssertEqual(failures.messages.count, 1)
        XCTAssertEqual(failures.messages.first?.contains("activate"), true, "\(failures.messages)")
        _ = router
    }

    func test_deactivate_offRIBActorQueue_reportsFailure_onlyWhenActive() {
        let interactor = InteractorMock()
        let router = Router<Interactor>(interactor: interactor)
        router.ribActorQueue = tree
        onTree { interactor.activate() }
        XCTAssertEqual(failures.messages, [])

        interactor.deactivate()

        XCTAssertEqual(failures.messages.count, 1)
        XCTAssertEqual(failures.messages.first?.contains("deactivate"), true, "\(failures.messages)")

        // A deactivate of an inactive Interactor does nothing, so it is not checked. A release path needs that.
        interactor.deactivate()
        XCTAssertEqual(failures.messages.count, 1)
        _ = router
    }

    func test_defaultFailureHandler_stopsTheProcess() {
        let handler = defaultFailureHandler!
        let exception = catchBadInstruction {
            handler("RIBActor check")
        }
        XCTAssertNotNil(exception)
    }

    // MARK: - A right-thread call is not reported

    func test_treeCalls_onRIBActorQueue_reportNoFailure() {
        let root = self.root!
        onTree {
            let child = Router<Interactor>(interactor: InteractorMock())
            root.attachChild(child)
            root.detachChild(child)
        }

        XCTAssertEqual(failures.messages, [])
    }

    func test_treeCalls_onQueueThatTargetsTheRIBActorQueue_reportNoFailure() {
        let root = self.root!
        let inner = DispatchQueue(label: "ribs.tests.tree.inner", target: tree)
        let done = expectation(description: "inner job")
        inner.async {
            let child = Router<Interactor>(interactor: InteractorMock())
            root.attachChild(child)
            root.detachChild(child)
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 20)

        XCTAssertEqual(failures.messages, [])
    }

    func test_treeCalls_withNoRIBActorQueue_reportNoFailure_onAnyThread() {
        let done = expectation(description: "background job")
        var childQueue: DispatchQueue? = tree
        DispatchQueue.global().async {
            let parent = Router<Interactor>(interactor: InteractorMock())
            let child = Router<Interactor>(interactor: InteractorMock())
            parent.interactable.activate()
            parent.load()
            parent.attachChild(child)
            let queue = child.ribActorQueue
            parent.detachChild(child)
            parent.interactable.deactivate()
            DispatchQueue.main.async {
                childQueue = queue
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)

        XCTAssertNil(childQueue)
        XCTAssertEqual(failures.messages, [])
    }

    // MARK: - The RIBActor queue reference is inherited

    func test_attachChild_passesTheRIBActorQueueToTheSubtree() {
        let root = self.root!
        let childInteractor = InteractorMock()
        let child = Router<Interactor>(interactor: childInteractor)
        let grandchild = Router<Interactor>(interactor: InteractorMock())
        onTree {
            root.attachChild(child)
            child.attachChild(grandchild)
        }

        XCTAssert(child.ribActorQueue === tree)
        XCTAssert(childInteractor.ribActorQueue === tree)
        XCTAssert(grandchild.ribActorQueue === tree)
        XCTAssertEqual(failures.messages, [])
    }
}
