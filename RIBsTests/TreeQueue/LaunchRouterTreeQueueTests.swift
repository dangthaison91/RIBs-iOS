@testable import RIBs
import XCTest

final class LaunchRouterTreeQueueTests: TreeQueueTestCase {

    private var interactor: InteractorMock!
    private var viewController: ViewControllableMock!
    private var launchRouter: LaunchRouter<Interactor, ViewControllable>!
    private var window: WindowMock!

    override func setUp() {
        super.setUp()
        interactor = InteractorMock()
        viewController = ViewControllableMock()
        launchRouter = LaunchRouter(interactor: interactor, viewController: viewController)
        window = WindowMock(frame: .zero)
    }

    override func tearDown() {
        let launchRouter = self.launchRouter
        self.launchRouter = nil
        onTree { launchRouter?.interactable.deactivate() }
        // The leak detector expects these to be released soon after the router.
        interactor = nil
        viewController = nil
        window = nil
        super.tearDown()
    }

    func test_launchFromWindow_withTreeQueue_setsTheWindowRootOnMain_activatesOnTheTreeQueue() {
        launchRouter.treeQueue = tree
        let activated = expectation(description: "activated")
        var activationQueue: String?
        interactor.didBecomeActiveHandler = {
            let label = currentQueueLabel()
            DispatchQueue.main.async {
                activationQueue = label
                activated.fulfill()
            }
        }

        launchRouter.launch(from: window)

        XCTAssert(window.rootViewController === viewController.uiviewController)
        XCTAssert(window.isKeyWindow)
        wait(for: [activated], timeout: 20)
        XCTAssertEqual(activationQueue, Self.treeLabel)
        XCTAssertEqual(failures.messages, [])
    }

    func test_showRootViewController_setsTheWindowRoot_doesNotActivate() {
        launchRouter.treeQueue = tree

        launchRouter.showRootViewController(in: window)

        XCTAssert(window.rootViewController === viewController.uiviewController)
        XCTAssert(window.isKeyWindow)
        XCTAssertEqual(interactor.didBecomeActiveCallCount, 0)
        XCTAssertEqual(failures.messages, [])
    }

    func test_activateAndLoad_onTheTreeQueue_activatesAndLoads() {
        launchRouter.treeQueue = tree
        let launchRouter = self.launchRouter!

        onTree { launchRouter.activateAndLoad() }

        XCTAssertEqual(interactor.didBecomeActiveCallCount, 1)
        XCTAssertNil(window.rootViewController)
        XCTAssertEqual(failures.messages, [])
    }

    func test_launchFromWindow_withNoTreeQueue_activatesBeforeItReturns() {
        launchRouter.launch(from: window)

        XCTAssert(window.rootViewController === viewController.uiviewController)
        XCTAssert(window.isKeyWindow)
        XCTAssertEqual(interactor.didBecomeActiveCallCount, 1)
        XCTAssertEqual(failures.messages, [])
    }
}
