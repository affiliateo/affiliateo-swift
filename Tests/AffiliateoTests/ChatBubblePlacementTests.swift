#if os(iOS)
import UIKit
import XCTest
@testable import Affiliateo

/// The bubble is for the app's pages (4.15.2): it sits just above the
/// window's root view, so anything presented over the pages covers it, and
/// showing it again never lifts it above what is presented.
@MainActor
final class ChatBubblePlacementTests: XCTestCase {
    private func windowWithRoot() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        if root.view.superview !== window { window.addSubview(root.view) }
        return (window, root.view)
    }

    func testItSitsJustAboveThePages() {
        let (window, root) = windowWithRoot()
        let bubble = UIView()
        LiveChat.keepOnPages(bubble, in: window)
        XCTAssertEqual(window.subviews.firstIndex(of: bubble), window.subviews.firstIndex(of: root).map { $0 + 1 })
    }

    func testWhatIsPresentedOverThePagesCoversIt() {
        let (window, _) = windowWithRoot()
        let bubble = UIView()
        LiveChat.keepOnPages(bubble, in: window)
        // A sheet, a cover or an alert: UIKit adds its container to the window on top.
        let presented = UIView()
        window.addSubview(presented)
        // Shown again (the app came back, page(_:), a new look): still below it.
        LiveChat.keepOnPages(bubble, in: window)
        let subviews = window.subviews
        XCTAssertLessThan(subviews.firstIndex(of: bubble)!, subviews.firstIndex(of: presented)!)
    }

    /// iOS 26 and later: the root view is not right in the window but inside
    /// containers (window, UITransitionView, UIDropShadowView, root view), and
    /// a sheet gets a container of its own above them (seen on iOS 27.0).
    /// 4.15.2 put the bubble under all of it, out of sight (4.15.3).
    func testItSitsAboveThePagesWhenTheyAreInAContainer() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        let transition = UIView(frame: window.bounds)
        let shadow = UIView(frame: window.bounds)
        window.addSubview(transition)
        transition.addSubview(shadow)
        shadow.addSubview(root.view)
        let bubble = UIView()
        LiveChat.keepOnPages(bubble, in: window)
        XCTAssertEqual(window.subviews.firstIndex(of: bubble), window.subviews.firstIndex(of: transition).map { $0 + 1 })
        // A sheet: its own container, added to the window on top, covers it.
        let sheet = UIView(frame: window.bounds)
        window.addSubview(sheet)
        LiveChat.keepOnPages(bubble, in: window)
        let subviews = window.subviews
        XCTAssertGreaterThan(subviews.firstIndex(of: bubble)!, subviews.firstIndex(of: transition)!)
        XCTAssertLessThan(subviews.firstIndex(of: bubble)!, subviews.firstIndex(of: sheet)!)
    }

    func testABubbleBroughtToTheFrontGoesBackDown() {
        let (window, root) = windowWithRoot()
        let presented = UIView()
        window.addSubview(presented)
        let bubble = UIView()
        window.addSubview(bubble)
        LiveChat.keepOnPages(bubble, in: window)
        let subviews = window.subviews
        XCTAssertEqual(subviews.firstIndex(of: bubble), subviews.firstIndex(of: root).map { $0 + 1 })
        XCTAssertLessThan(subviews.firstIndex(of: bubble)!, subviews.firstIndex(of: presented)!)
    }
}
#endif
