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

import UIKit

/// The root `Router` of an application.
public protocol LaunchRouting: ViewableRouting {

    /// Launches the router tree.
    ///
    /// - parameter window: The application window to launch from.
    func launch(from window: UIWindow)
}

/// The application root router base class, that acts as the root of the router tree.
open class LaunchRouter<InteractorType, ViewControllerType>: ViewableRouter<InteractorType, ViewControllerType>, LaunchRouting {

    /// Initializer.
    ///
    /// - parameter interactor: The corresponding `Interactor` of this `Router`.
    /// - parameter viewController: The corresponding `ViewController` of this `Router`.
    public override init(interactor: InteractorType, viewController: ViewControllerType) {
        super.init(interactor: interactor, viewController: viewController)
    }

    /// Launches the router tree.
    ///
    /// With no tree queue, the tree is active and loaded when this method returns. With a tree queue, this
    /// method sets the window root, then runs `activateAndLoad()` as a block on the tree queue, so the tree
    /// becomes active after this method returns.
    ///
    /// - parameter window: The window to launch the router tree in.
    public final func launch(from window: UIWindow) {
        showRootViewController(in: window)

        if let treeQueue {
            treeQueue.async {
                self.activateAndLoad()
            }
        } else {
            activateAndLoad()
        }
    }

    /// The main-thread part of `launch(from:)`: makes the view controller of this router the root of the window.
    ///
    /// - parameter window: The window to launch the router tree in.
    public final func showRootViewController(in window: UIWindow) {
        window.rootViewController = viewControllable.uiviewController
        window.makeKeyAndVisible()
    }

    /// The tree part of `launch(from:)`: activates the interactor and loads this router. Call it on the tree
    /// queue when this router has one.
    public final func activateAndLoad() {
        interactable.activate()
        load()
    }
}
