//
//  Copyright (c) 2017. Uber Technologies
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import RxSwift
import XCTest
@testable import RIBs

final class ObservableConcurrencyTests: XCTestCase {

    func test_singleFromAsync_emitsSuccess() async {
        let success = expectation(description: "Single emitted success")

        _ = Single<Int>.fromAsync {
            return 1
        }
        .subscribe(
            onSuccess: { value in
                XCTAssertEqual(value, 1)
                success.fulfill()
            },
            onFailure: { error in
                XCTFail("Unexpected error: \(error)")
            }
        )

        await fulfillment(of: [success], timeout: 1)
    }

    func test_singleFromAsync_emitsFailure() async {
        let failure = expectation(description: "Single emitted failure")

        _ = Single<Int>.fromAsync {
            throw ObservableConcurrencyTestError.error
        }
        .subscribe(
            onSuccess: { value in
                XCTFail("Unexpected value: \(value)")
            },
            onFailure: { error in
                guard case ObservableConcurrencyTestError.error = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
                failure.fulfill()
            }
        )

        await fulfillment(of: [failure], timeout: 1)
    }

    func test_singleFromAsync_cancelsTaskWhenDisposed() async {
        let taskStarted = expectation(description: "Task started")
        let taskCancelled = expectation(description: "Task cancelled")
        let disposable = Single<Int>.fromAsync {
            taskStarted.fulfill()
            while !Task.isCancelled {
                await Task.yield()
            }
            taskCancelled.fulfill()
            throw CancellationError()
        }
        .subscribe()

        await fulfillment(of: [taskStarted], timeout: 1)
        disposable.dispose()
        await fulfillment(of: [taskCancelled], timeout: 1)
    }

    func test_observableFromAsync_emitsValueAndCompletes() async {
        let completed = expectation(description: "Observable completed")
        var receivedValues: [Int] = []

        _ = Observable<Int>.fromAsync {
            return 1
        }
        .subscribe(
            onNext: { value in
                receivedValues.append(value)
            },
            onError: { error in
                XCTFail("Unexpected error: \(error)")
            },
            onCompleted: {
                completed.fulfill()
            }
        )

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(receivedValues, [1])
    }

    @MainActor
    func test_singleFromAsync_doesNotRunWorkWhenDisposedBeforeTaskStarts() async {
        let workRan = expectation(description: "Work ran after dispose")
        workRan.isInverted = true

        withSaturatedCooperativePool {
            Single<Int>.fromAsync {
                workRan.fulfill()
                return 1
            }
            .subscribe()
            .dispose()
        }

        await fulfillment(of: [workRan], timeout: 1)
    }

    @MainActor
    func test_observableFromAsync_doesNotRunWorkWhenDisposedBeforeTaskStarts() async {
        let workRan = expectation(description: "Work ran after dispose")
        workRan.isInverted = true

        withSaturatedCooperativePool {
            Observable<Int>.fromAsync {
                workRan.fulfill()
                return 1
            }
            .subscribe()
            .dispose()
        }

        await fulfillment(of: [workRan], timeout: 1)
    }

    func test_singleFromAsync_doesNotEmitWhenDisposedWhileWorkIsRunning() async {
        let workStarted = expectation(description: "Work started")
        let workMayFinish = DispatchSemaphore(value: 0)
        let emitted = expectation(description: "Emitted after dispose")
        emitted.isInverted = true

        let disposable = Single<Int>.fromAsync {
            workStarted.fulfill()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    workMayFinish.wait()
                    continuation.resume()
                }
            }
            return 1
        }
        .subscribe(onSuccess: { _ in emitted.fulfill() }, onFailure: { _ in emitted.fulfill() })

        await fulfillment(of: [workStarted], timeout: 2)
        disposable.dispose()
        workMayFinish.signal()
        await fulfillment(of: [emitted], timeout: 1)
    }

    /// Runs `body` while every cooperative-pool thread is blocked, so a `Task` created inside `body` cannot start
    /// before `body` returns. This makes "dispose before the task starts" deterministic. It blocks the main thread
    /// with plain semaphores and never awaits: XCTest's own awaits would need a pool thread and deadlock.
    @MainActor
    private func withSaturatedCooperativePool(_ body: () -> Void) {
        let workerCount = ProcessInfo.processInfo.activeProcessorCount
        let release = DispatchSemaphore(value: 0)
        let blockersRunning = DispatchGroup()

        for _ in 0 ..< workerCount {
            blockersRunning.enter()
            Task.detached {
                blockersRunning.leave()
                release.wait()
            }
        }
        defer {
            for _ in 0 ..< workerCount {
                release.signal()
            }
        }
        guard blockersRunning.wait(timeout: .now() + 2) == .success else {
            XCTFail("Could not saturate the cooperative pool")
            return
        }

        body()
    }
}

private enum ObservableConcurrencyTestError: Error {
    case error
}
