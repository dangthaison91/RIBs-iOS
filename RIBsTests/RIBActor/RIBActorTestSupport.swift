@testable import RIBs
import RxSwift
import UIKit
import XCTest

func currentQueueLabel() -> String {
    String(cString: __dispatch_queue_get_label(nil))
}

/// Records the messages of the RIBActor check. Thread-safe.
final class RIBActorFailureRecorder {
    private let lock = NSLock()
    private var recorded: [String] = []

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(message)
    }
}

/// Counts events by the queue they ran on. Thread-safe.
final class QueueLog {
    private let lock = NSLock()
    private var counts: [String: [String: Int]] = [:]

    func note(_ event: String) {
        let label = currentQueueLabel()
        lock.lock(); defer { lock.unlock() }
        counts[event, default: [:]][label, default: 0] += 1
    }

    /// Queue label to count, for one event.
    func queues(of event: String) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts[event] ?? [:]
    }
}

/// A test case with one serial RIBActor queue. The RIBActor check records its failures in `failures` and does not
/// stop the process, so a test can assert on a wrong-thread call.
class RIBActorTestCase: XCTestCase {
    static let treeLabel = "ribs.tests.tree"
    let tree = DispatchQueue(label: RIBActorTestCase.treeLabel)
    let failures = RIBActorFailureRecorder()
    private(set) var defaultFailureHandler: ((String) -> Void)!

    override func setUp() {
        super.setUp()
        defaultFailureHandler = RIBActorCheck.failureHandler
        let failures = self.failures
        RIBActorCheck.failureHandler = { failures.record($0) }
    }

    override func tearDown() {
        RIBActorCheck.failureHandler = defaultFailureHandler
        super.tearDown()
    }

    /// Runs `work` as a RIBActor queue job and returns its result. Main runs its run loop while it waits.
    @discardableResult
    func onTree<T>(_ work: @escaping () -> T) -> T {
        let done = expectation(description: "tree job")
        var result: T?
        tree.async {
            let value = work()
            DispatchQueue.main.async {
                result = value
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        return result!
    }

    /// Waits until the RIBActor queue has finished the jobs queued before this call.
    func drainTree() {
        onTree {}
    }
}

final class DeinitTrackingRouter: Router<Interactor> {
    var onDeinit: (() -> Void)?
    deinit { onDeinit?() }
}
