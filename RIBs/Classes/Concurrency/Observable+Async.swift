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

#if swift(>=5.6) && canImport(_Concurrency)

import RxSwift

public extension PrimitiveSequenceType where Trait == SingleTrait {

    /// Create a cold single that runs the given async work on subscription.
    /// Disposing the subscription cancels the task. If that happens before the task starts, `work` never runs.
    static func fromAsync(_ work: @escaping () async throws -> Element) -> Single<Element> {
        return .create { observer in
            let task = Task {
                // Disposal cancels the task, but a cancelled task still starts. Skip the work and emit nothing:
                // the observer is already disposed, and the work may have side effects.
                guard !Task.isCancelled else { return }
                do {
                    observer(.success(try await work()))
                } catch {
                    observer(.failure(error))
                }
            }

            return Disposables.create {
                task.cancel()
            }
        }
    }
}

public extension ObservableType {

    /// Create a cold observable that runs the given async work on subscription.
    static func fromAsync(_ work: @escaping () async throws -> Element) -> Observable<Element> {
        return Single<Element>.fromAsync(work).asObservable()
    }
}
#endif
