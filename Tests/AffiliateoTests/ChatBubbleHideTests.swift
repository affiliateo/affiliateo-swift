#if os(iOS)
import UIKit
import XCTest
@testable import Affiliateo

/// Hold to hide (4.19.0): held still for a second the bubble rocks with a
/// red X on its top-left corner; the X hides it, anywhere else ends it.
@MainActor
final class ChatBubbleHideTests: XCTestCase {
    private var taps = 0
    private var hides = 0

    private func bubble(size: CGFloat = 56) -> ChatBubbleView {
        ChatBubbleView(appId: "hide-tests", size: size, onHide: { [unowned self] in self.hides += 1 }) { [unowned self] in self.taps += 1 }
    }

    private func onWindow(_ view: ChatBubbleView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        view.frame.origin = CGPoint(x: 300, y: 700)
        return window
    }

    override func setUp() {
        super.setUp()
        taps = 0
        hides = 0
    }

    func testAHoldOfOneSecondThatMayNotTravelIsOnTheBubble() throws {
        let hold = try XCTUnwrap(bubble().gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        XCTAssertEqual(hold.minimumPressDuration, 1.0)
        XCTAssertEqual(hold.allowableMovement, 10)
        // The tap and the drag are still there.
        XCTAssertNotNil(bubble().gestureRecognizers?.first { $0 is UITapGestureRecognizer })
        XCTAssertNotNil(bubble().gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
    }

    func testTheXShowsAndTheBubbleRocksLikeTheAppsCards() throws {
        let view = bubble()
        XCTAssertTrue(view.hideBadge.isHidden)
        view.startHideMode(reduceMotion: false)
        XCTAssertTrue(view.isHideMode)
        XCTAssertFalse(view.hideBadge.isHidden)
        XCTAssertEqual(view.hideBadge.frame, CGRect(x: -3, y: -3, width: 18, height: 18))
        XCTAssertEqual(view.hideBadge.layer.cornerRadius, 6)
        // Above the red number and the green dot.
        XCTAssertEqual(view.subviews.last, view.hideBadge)

        let rock = try XCTUnwrap(view.layer.animation(forKey: ChatBubbleView.jiggleKey) as? CABasicAnimation)
        XCTAssertEqual(rock.keyPath, "transform.rotation.z")
        XCTAssertEqual(try XCTUnwrap(rock.fromValue as? Double) * 180 / Double.pi, -2.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rock.toValue as? Double) * 180 / Double.pi, 2.5, accuracy: 0.0001)
        XCTAssertEqual(rock.duration, 0.13, accuracy: 0.0001)
        XCTAssertTrue(rock.autoreverses)
        XCTAssertEqual(rock.repeatCount, .infinity)
        // Eased in and out, as the cards' easeInOut.
        let eased = CAMediaTimingFunction(name: .easeInEaseOut)
        let timing = try XCTUnwrap(rock.timingFunction)
        for index in 0..<4 {
            var mine: [Float] = [0, 0]
            var theirs: [Float] = [0, 0]
            timing.getControlPoint(at: index, values: &mine)
            eased.getControlPoint(at: index, values: &theirs)
            XCTAssertEqual(mine, theirs)
        }
    }

    func testReduceMotionKeepsItStillButTheXStillShows() {
        let view = bubble()
        view.startHideMode(reduceMotion: true)
        XCTAssertTrue(view.isHideMode)
        XCTAssertFalse(view.hideBadge.isHidden)
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.jiggleKey))
    }

    func testTheXHidesTheBubbleOnce() {
        let view = bubble()
        view.startHideMode(reduceMotion: false)
        view.tap(at: CGPoint(x: 6, y: 6))
        XCTAssertEqual(hides, 1)
        XCTAssertEqual(taps, 0)
        XCTAssertFalse(view.isHideMode)
        // Its target reaches past the square.
        view.startHideMode(reduceMotion: false)
        view.tap(at: CGPoint(x: -10, y: 20))
        XCTAssertEqual(hides, 2)
    }

    func testATapOnTheBubbleWhileTheXShowsOnlyEndsIt() {
        let view = bubble()
        view.startHideMode(reduceMotion: false)
        view.tap(at: CGPoint(x: 40, y: 40))
        XCTAssertFalse(view.isHideMode)
        XCTAssertTrue(view.hideBadge.isHidden)
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.jiggleKey))
        // Neither hidden nor opened.
        XCTAssertEqual(hides, 0)
        XCTAssertEqual(taps, 0)
        // The next quick tap opens the chat again.
        view.tap(at: CGPoint(x: 40, y: 40))
        XCTAssertEqual(taps, 1)
    }

    func testAQuickTapStillOpensTheChat() {
        let view = bubble()
        view.tap(at: CGPoint(x: 6, y: 6))
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(hides, 0)
    }

    func testFiveSecondsWithoutATapEndIt() {
        let view = bubble()
        view.startHideMode(reduceMotion: false)
        view.hideModeTimedOut()
        XCTAssertFalse(view.isHideMode)
        XCTAssertTrue(view.hideBadge.isHidden)
        XCTAssertEqual(hides, 0)
    }

    func testItEndsOnItsOwnAfterFiveSeconds() {
        let view = bubble()
        view.startHideMode(reduceMotion: true)
        let ended = expectation(description: "ended")
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatRules.hideModeLasts + 0.3) {
            XCTAssertFalse(view.isHideMode)
            ended.fulfill()
        }
        wait(for: [ended], timeout: ChatRules.hideModeLasts + 2)
    }

    func testHiddenOrTakenOffTheWindowLeavesNoX() {
        let view = bubble()
        let window = onWindow(view)
        view.startHideMode(reduceMotion: false)
        view.isHidden = true
        XCTAssertFalse(view.isHideMode)

        view.isHidden = false
        view.startHideMode(reduceMotion: false)
        XCTAssertTrue(view.isHideMode)
        view.removeFromSuperview()
        XCTAssertFalse(view.isHideMode)
        _ = window
    }

    func testAHiddenBubbleNeverStartsIt() {
        let view = bubble()
        view.isHidden = true
        view.startHideMode(reduceMotion: false)
        XCTAssertFalse(view.isHideMode)
    }

    func testTheWindowIsWatchedOnlyWhileTheXShows() {
        let view = bubble()
        let window = onWindow(view)
        let before = window.gestureRecognizers?.count ?? 0
        view.startHideMode(reduceMotion: false)
        let watcher = window.gestureRecognizers?.compactMap { $0 as? ChatHideWatcher }.first
        XCTAssertNotNil(watcher)
        XCTAssertEqual(watcher?.cancelsTouchesInView, false)
        XCTAssertEqual(watcher?.delaysTouchesBegan, false)
        XCTAssertEqual(watcher?.delaysTouchesEnded, false)
        view.endHideMode()
        XCTAssertEqual(window.gestureRecognizers?.count ?? 0, before)
    }

    func testTheXsTargetCountsAsTheBubbleOnlyWhileItShows() {
        let view = bubble()
        XCTAssertFalse(view.point(inside: CGPoint(x: -8, y: -8), with: nil))
        view.startHideMode(reduceMotion: false)
        XCTAssertTrue(view.point(inside: CGPoint(x: -8, y: -8), with: nil))
        XCTAssertTrue(view.point(inside: CGPoint(x: 30, y: 30), with: nil))
        XCTAssertFalse(view.point(inside: CGPoint(x: -20, y: -20), with: nil))
    }

    func testNoAttentionWiggleWhileTheXShows() {
        let view = bubble()
        view.wiggle(now: 100)
        XCTAssertNotNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        // The hold cuts it.
        view.startHideMode(reduceMotion: false)
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        view.wiggle(now: 200)
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        view.endHideMode()
        view.wiggle(now: 300)
        XCTAssertNotNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
    }

    func testTheXTakesTheGreenDotsCornerAndGivesItBack() throws {
        let view = bubble()
        view.update(unread: 0, online: true)
        let dot = try XCTUnwrap(view.subviews.first { $0 !== view.hideBadge && $0.layer.cornerRadius == 8 && !($0 is UILabel) })
        XCTAssertFalse(dot.isHidden)
        view.startHideMode(reduceMotion: false)
        XCTAssertTrue(dot.isHidden)
        // A repaint while the X shows keeps it away.
        view.update(unread: 0, online: true)
        XCTAssertTrue(dot.isHidden)
        view.endHideMode()
        XCTAssertFalse(dot.isHidden)
        // Offline by then: it stays away.
        view.startHideMode(reduceMotion: false)
        view.update(unread: 0, online: false)
        view.endHideMode()
        XCTAssertTrue(dot.isHidden)
    }

    func testVoiceOverHidesItWithoutTheHold() throws {
        let view = bubble()
        let action = try XCTUnwrap(view.accessibilityCustomActions?.first)
        let words = ChatRules.ChatWords.forLanguage(Locale.preferredLanguages.first ?? "en")
        XCTAssertEqual(action.name, words.hide)
        _ = action.actionHandler?(action)
        XCTAssertEqual(hides, 1)
        XCTAssertEqual(taps, 0)
    }

    func testLiveChatTellsTheAppOncePerHide() {
        var told = 0
        LiveChat.shared.setOnHidden { told += 1 }
        defer { LiveChat.shared.setOnHidden(nil) }
        LiveChat.shared.personHid()
        XCTAssertEqual(told, 1)
        LiveChat.shared.setOnHidden(nil)
        LiveChat.shared.personHid()
        XCTAssertEqual(told, 1)
    }
}
#endif
