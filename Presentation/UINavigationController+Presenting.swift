//
//  UINavigationController+Presenting.swift
//  Presentation
//
//  Created by Måns Bernhardt on 2016-01-27.
//  Copyright © 2016 iZettle. All rights reserved.
//

import UIKit
import Flow

public extension PresentationOptions {
    /// Pushing and popping on a navigation controller defaults to batch subsequent operation from the same run-loop togeher. This options turnes that of.
    public static let disablePushPopCoalecing = PresentationOptions()

    /// Automatically pop a pushed view controller once the presentation completes.
    public static let autoPop = PresentationOptions()

    /// Any succeedingly pushed view controllers (pushed after itself) will be popped when `self` is cancelled or completed.
    public static let autoPopSuccessors = PresentationOptions()

    /// Equivalent to [.autoPop, .autoPopSuccessors]
    public static let autoPopSelfAndSuccessors: PresentationOptions = [.autoPop, .autoPopSuccessors]
}

extension UINavigationController: PresentingViewController {
    public func present(_ vc: UIViewController, options: PresentationOptions) -> PresentingViewController.Result {
        let dismissFuture = vc.installDismissButton().future.map { throw PresentError.dismissed }
        let pushFuture = self.pushViewController(vc, options: options)

        let dismiss = { () -> Future<()> in
            var futures = [Future<()>]()
            let nc = (vc.navigationController ?? self)
            if options.contains(.autoPop) {
                futures.append(nc.popViewController(vc, options: options))
            }

            if let index = nc.viewControllers.index(of: vc), options.contains(.autoPopSuccessors) {
                for vc in nc.viewControllers.suffix(from: index).dropFirst() {
                    futures.append(nc.popViewController(vc, options: options))
                }
            }
            return join(futures).toVoid()
        }

        return (Flow.select(dismissFuture, or: pushFuture).toVoid(), dismiss)
    }
}

/// Customization of the default title used by the navigation controller back button.
public var customNavigationBackButtonWithTitle: (String) -> UIBarButtonItem? = { _ in nil }

public extension UINavigationController {
    /// Push `viewController` onto `self` and return a future that completes once the animation completes.
    @discardableResult
    func pushViewController(_ viewController: UIViewController, options: PresentationOptions) -> Future<()> {
        return Future { completion in
            let pushPoper = PushPoper(vc: viewController, vcPrefersNavBarHidden: options.navigationBarHidden(), animated: options.animated, disableCoalecing: options.contains(.disablePushPopCoalecing)) {
                completion($0)
            }

            self.append(pushPoper)
            return pushPoper.bag
        }
    }

    /// Pop `viewController` from `self` and return a future that completes once the animation completes.
    @discardableResult
    func popViewController(_ viewController: UIViewController, options: PresentationOptions) -> Future<()> {
        return Future { completion in
            let pushPoper = PushPoper(vc: viewController, vcPrefersNavBarHidden: options.navigationBarHidden(), animated: options.animated, disableCoalecing: options.contains(.disablePushPopCoalecing), isPopping: true) { _ in
                completion(.success)
            }
            self.append(pushPoper)
            return pushPoper.bag
        }
    }
}

private class PushPoper: NSObject {
    let vc: UIViewController
    let vcPrefersNavBarHidden: Bool?
    let animated: Bool
    let disableCoalecing: Bool
    weak var _onComplete: Box<((Result<()>) -> ())>?
    var onComplete: (Result<()>) -> () {
        return _onComplete?.unbox ?? { _ in }
    }
    let isPopping: Bool
    let bag = DisposeBag()

    init(vc: UIViewController, vcPrefersNavBarHidden: Bool?, animated: Bool, disableCoalecing: Bool = false, isPopping: Bool = false, onComplete: @escaping (Result<()>) -> ()) {

        self.vc = vc
        self.vcPrefersNavBarHidden = vcPrefersNavBarHidden
        self.animated = animated
        self.disableCoalecing = disableCoalecing
        self.isPopping = isPopping
        let onComplete = Box(onComplete)
        self._onComplete = onComplete
        bag.hold(onComplete) // hold on, keeping reference of onComplete inside the bag to avoid potential retain cycles  (PushPoper > onComplete > UINavigationController > PushPoper)
    }
}

private var pushPopersKey = false

// Helper to coalesce (and cancel out push/pops) to work around UINavigationController animation issues when push/pops several times during the same run-loop
private extension UINavigationController {
    var pushPopers: [PushPoper] {
        get { return associatedValue(forKey: &pushPopersKey, initial: []) }
        set { setAssociatedValue(newValue, forKey: &pushPopersKey) }
    }

    func append(_ pushPoper: PushPoper) {
        if let i = pushPopers.index(where: { $0.vc == pushPoper.vc && !$0.isPopping }), pushPoper.isPopping {
            pushPopers.remove(at: i)
            return
        }

        pushPopers.append(pushPoper)
        if (pushPoper.disableCoalecing || self.viewControllers.isEmpty) { // not coalescing if no viewcontroller is set yet, in order to not display an empty navigation controller
            self.processPushPopers()
        } else {
            DispatchQueue.main.async {
                self.processPushPopers()
            }
        }
    }

    func processPushPopers() {
        guard !pushPopers.isEmpty else { return }

        var vcs = viewControllers

        var animated = false
        for pushPoper in pushPopers {
            animated = animated || pushPoper.animated
            if pushPoper.isPopping {
                _ = vcs.index(of: pushPoper.vc).map { vcs.remove(at: $0) }
            } else {
                guard !vcs.contains(pushPoper.vc) else {
                    pushPoper.onComplete(.failure(PresentError.alreadyPresented))
                    if let i = pushPopers.index(of: pushPoper) {
                        pushPopers.remove(at: i)
                    }
                    continue
                }
                if let lastVC = vcs.last, let item = customNavigationBackButtonWithTitle(lastVC.title ?? "") {
                    lastVC.navigationItem.backBarButtonItem = item
                }
                vcs.append(pushPoper.vc)
            }
        }

        let navBarHidden = pushPopers.lastIndex(where: { $0.vc == vcs.last }).map{ pushPopers[$0] }?.vcPrefersNavBarHidden

        if vcs.count == viewControllers.count {
            animated = false
        } else if vcs.count < viewControllers.count {
            animated = animated && vcs.last.map({ viewControllers.contains($0) }) ?? false
        } else if vcs.count > viewControllers.count {
            animated = animated && viewControllers.count > 0
        }


        if let coordinator = transitionCoordinator, !animated {
            // If we update the vcs while the nc (self) is being presented, the nc gets lost and controls in the the presented vcs can't become first responders.
            // Moving presentation inside transition animate fixes issue.
            let willAnimate = coordinator.animate(alongsideTransition: { context in
                let wasEnabled = UIView.areAnimationsEnabled
                UIView.setAnimationsEnabled(false)
                self.setViewControllers(vcs, animated: false)
                if let navBarHidden = navBarHidden {
                    self.setNavigationBarHidden(navBarHidden, animated: false)
                }
                UIView.setAnimationsEnabled(wasEnabled)
            })

            if !willAnimate { // if the animation block wont't be called, fallback to normal setting up of vcx
                setViewControllers(vcs, animated: animated)
                if let navBarHidden = navBarHidden {
                    self.setNavigationBarHidden(navBarHidden, animated: animated)
                }
            }
        } else {
            setViewControllers(vcs, animated: animated)
            if let navBarHidden = navBarHidden {
                self.setNavigationBarHidden(navBarHidden, animated: animated)
            }
        }

        func finalizeProcessedPushPoppers() {
            let processedPushPopers = pushPopers.filter { pushPoper in (pushPoper.isPopping && !viewControllers.contains(pushPoper.vc)) || (!pushPoper.isPopping && viewControllers.contains(pushPoper.vc)) }
            pushPopers = pushPopers.filter { pushPoper in !processedPushPopers.contains(pushPoper) }

            for pushPoper in processedPushPopers {
                animated = animated || pushPoper.animated
                if pushPoper.isPopping {
                    pushPoper.onComplete(.success)
                } else {
                    listenOnPop(for: pushPoper)
                }
            }
        }

        finalizeProcessedPushPoppers()

        guard vcs == viewControllers else { // transition in progress let's try again next run-loop
            DispatchQueue.main.async {
                finalizeProcessedPushPoppers()
                self.processPushPopers() // in case there are some remaining push popers at this point
            }
            return
        }
    }

    func listenOnPop(for pushPoper: PushPoper) {
        popSignalPushPopers.append(Weak(pushPoper))
        pushPoper.bag += popViewControllerSignal.filter { $0 == pushPoper.vc }.onFirstValue { _ in
            pushPoper.vc.navigationItem.popCallbacker.callAll(with: ())
            pushPoper.onComplete(.success)
        }
        pushPoper.bag += willPopViewControllerSignal.filter { $0 == pushPoper.vc }.onFirstValue { vc in
            guard self.viewControllers.count > 1 else { return }
//            if let previousPopSignalPushPoper = self.popSignalPushPopers.lastIndex(where: { $0.value?.vc == pushPoper.vc}).map({ self.popSignalPushPopers[$0 - 1] }), let previousPushPoper = previousPopSignalPushPoper.value, let navBarVisibilityPrefernce = previousPushPoper.vcPrefersNavBarHidden {
//                self.setNavigationBarHidden(!navBarVisibilityPrefernce, animated: previousPushPoper.animated)
//            }

//            self.popSignalPushPopers.map({ $0.value?.vc == vc })
            if let previousPushPoper = self.popSignalPushPopers.first(where: { $0.value?.vc == self.viewControllers.last }).flatMap({ $0.value }), let navBarHidden = previousPushPoper.vcPrefersNavBarHidden {
                self.setNavigationBarHidden(navBarHidden, animated: previousPushPoper.animated)
            }
        }
    }

    var popSignalPushPopers: [Weak<PushPoper>] {
        get { return associatedValue(forKey: &popSignalPushPopersKey, initial: []) }
        set { setAssociatedValue(newValue, forKey: &popSignalPushPopersKey) }
    }
}

extension UINavigationController {
    func transferViewControllers(from: UINavigationController) {
        viewControllers += from.viewControllers
        for pushPoper in from.popSignalPushPopers.compactMap({ $0.value }) {
            let onComplete = pushPoper._onComplete
            pushPoper.bag.dispose()
            pushPoper._onComplete = onComplete
            pushPoper.bag += {
                _ = onComplete // hold on, keeping reference of onComplete inside the bag to avoid potential retain cycles  (PushPoper > onComplete > UINavigationController > PushPoper)
            }
            listenOnPop(for: pushPoper)
        }
        from.popSignalPushPopers.removeAll()
    }
}

private final class Box<A> {
    let unbox: A
    init(_ value: A) { unbox = value }
}

private var popSignalPushPopersKey = false
