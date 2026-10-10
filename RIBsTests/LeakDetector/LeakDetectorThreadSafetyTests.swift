@testable import RIBs
import RxSwift
import XCTest

final class LeakDetectorThreadSafetyTests: XCTestCase {

    private var detector: LeakDetector!
    private var statusDisposable: Disposable?

    override func setUp() {
        super.setUp()
        LeakDetector.disableLeakDetectorOverride = false
        detector = LeakDetector()
    }

    override func tearDown() {
        statusDisposable?.dispose()
        detector = nil
        super.tearDown()
    }

    /// Two threads register expectations while main completes them. Every expectation must be counted once
    /// up and once down, so the count returns to exactly 0.
    func test_expectDeallocate_fromTwoThreads_whileMainCompletes_countReturnsToZero() {
        let detector = self.detector!
        let registered = expectation(description: "registered")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                for _ in 0 ..< 2000 {
                    // The pool releases the object at once; a worker thread drains its own pool late.
                    autoreleasepool {
                        _ = detector.expectDeallocate(object: NSObject(), inTime: 0.05)
                    }
                }
            }
            DispatchQueue.main.async { registered.fulfill() }
        }
        wait(for: [registered], timeout: 60)

        waitForStatus(.DidComplete)

        // A count below 0 also reads as DidComplete. One more expectation tells 0 from a negative count.
        let object = NSObject()
        detector.expectDeallocate(object: object, inTime: 0.2)
        XCTAssertEqual(currentStatus(), .InProgress)
    }

    /// The allocator reuses the address of a released object. A check of the released object must not find
    /// the next object that lives at the same address.
    func test_expectDeallocate_whenTheAddressIsReused_reportsNoLeak() {
        let detector = self.detector!
        var reusedAddressCount = 0
        var survivors: [NSObject] = []

        for _ in 0 ..< 200 {
            // `NSMapTable` autoreleases tracked objects when it grows. The pools keep that from extending a
            // lifetime: the release of `first` is final before `second` is allocated.
            autoreleasepool {
                let firstAddress: ObjectIdentifier = autoreleasepool {
                    let first = NSObject()
                    detector.expectDeallocate(object: first, inTime: 0.05)
                    return ObjectIdentifier(first)
                }

                // Lives past the check of `first`, then is released in time for its own check.
                let second = NSObject()
                if ObjectIdentifier(second) == firstAddress {
                    reusedAddressCount += 1
                }
                detector.expectDeallocate(object: second, inTime: 1)
                survivors.append(second)
            }
        }
        XCTAssertGreaterThan(reusedAddressCount, 0, "The allocator did not reuse an address; the case did not run.")

        let firstChecksDone = expectation(description: "first checks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { firstChecksDone.fulfill() }
        wait(for: [firstChecksDone], timeout: 20)
        survivors.removeAll()

        // With the leak assertion on, a false leak report stops the test process before this line.
        waitForStatus(.DidComplete)
    }

    // MARK: - Private

    private func currentStatus() -> LeakDetectionStatus? {
        var status: LeakDetectionStatus?
        detector.status.take(1).subscribe(onNext: { status = $0 }).dispose()
        return status
    }

    private func waitForStatus(_ expected: LeakDetectionStatus) {
        let reached = expectation(description: "status \(expected)")
        reached.assertForOverFulfill = false
        statusDisposable?.dispose()
        statusDisposable = detector.status
            .filter { $0 == expected }
            .subscribe(onNext: { _ in reached.fulfill() })
        wait(for: [reached], timeout: 30)
    }
}
