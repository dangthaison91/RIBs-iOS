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

    /// `NSMapTable` autoreleases the live objects it holds when it grows. A tracked object must still be
    /// released with its last reference, also on a thread that pops its autorelease pool late.
    func test_expectDeallocate_whenTheTableGrows_doesNotExtendTheLifetimeOfATrackedObject() {
        let detector = self.detector!
        var keptAliveCount = 0

        // One pool around the whole loop, as on a worker thread that stays busy.
        autoreleasepool {
            for _ in 0 ..< 100 {
                weak var tracked: NSObject?
                do {
                    let object = NSObject()
                    tracked = object
                    detector.expectDeallocate(object: object, inTime: 0.05)
                    // A second registration while `object` is alive, as a Router and its Interactor do for
                    // one view controller.
                    detector.expectDeallocate(object: NSObject(), inTime: 0.05)
                }
                if tracked != nil { keptAliveCount += 1 }
            }
        }

        XCTAssertEqual(keptAliveCount, 0)
        waitForStatus(.DidComplete)
    }

    /// `NSMapTable` retains and autoreleases the live objects it holds when it grows. When the owner of such an
    /// object releases it on another thread before the pool drains, the pool holds the last reference, and the
    /// `deinit` runs on the thread that grows the table. A `deinit` that registers an expectation, as a
    /// Router that detaches a child does, must not find the lock held by its own thread.
    func test_expectDeallocate_whenADeinitDuringTableGrowthRegistersAnExpectation_completes() {
        LeakDetector.disableLeakDetectorOverride = true
        let detector = LeakDetector()
        let reentryCount = Counter()
        let growerKey = "LeakDetectorThreadSafetyTests.grower"
        let finished = expectation(description: "every thread finished")

        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 4) { thread in
                if thread == 0 {
                    Thread.current.threadDictionary[growerKey] = true
                    var registered = 0
                    while reentryCount.value == 0, registered < 200_000 {
                        autoreleasepool {
                            _ = detector.expectDeallocate(object: NSObject(), inTime: 0.01)
                        }
                        registered += 1
                    }
                    Thread.current.threadDictionary[growerKey] = nil
                    reentryCount.finish()
                } else {
                    // Owns a few live tracked objects and releases them slowly, without the lock, so that a
                    // release falls inside a growth of the table on the grower thread.
                    while !reentryCount.isFinished {
                        var owned: [RegistersOnDeinit] = []
                        for _ in 0 ..< 32 {
                            let object = RegistersOnDeinit {
                                guard Thread.current.threadDictionary[growerKey] != nil else { return }
                                reentryCount.increment()
                                _ = detector.expectDeallocate(object: NSObject(), inTime: 0.01)
                            }
                            _ = detector.expectDeallocate(object: object, inTime: 0.5)
                            owned.append(object)
                        }
                        while owned.popLast() != nil {
                            var spin = 0
                            for step in 0 ..< 20_000 { spin &+= step }
                            _ = spin
                        }
                    }
                }
            }
            DispatchQueue.main.async { finished.fulfill() }
        }

        // With the pool inside the lock, the grower thread waits for itself. The checks that run on main wait
        // for the same lock, so this wait does not time out: the run stops at the test time allowance.
        executionTimeAllowance = 120
        wait(for: [finished], timeout: 120)
        XCTAssertGreaterThan(reentryCount.value, 0, "No tracked object was released by the pool of a growth; the case did not run.")
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

private final class RegistersOnDeinit {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private final class Counter {
    private let lock = NSLock()
    private var count = 0
    private var finished = false

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
}
