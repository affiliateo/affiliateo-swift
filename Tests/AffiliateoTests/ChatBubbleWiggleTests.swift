#if os(iOS)
import UIKit
import XCTest
@testable import Affiliateo

/// The bubble's wiggle (4.17.0): one short turn left and right that dies
/// down, on the bubble itself, so its red number and green dot move with it.
@MainActor
final class ChatBubbleWiggleTests: XCTestCase {
    private func bubble() -> ChatBubbleView {
        ChatBubbleView(appId: "wiggle-tests", size: 56) {}
    }

    func testOneWiggleTurnsTheBubbleAndEndsAtRest() throws {
        let view = bubble()
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        view.wiggle()
        let turns = try XCTUnwrap(view.layer.animation(forKey: ChatBubbleView.wiggleKey) as? CAKeyframeAnimation)
        XCTAssertEqual(turns.keyPath, "transform.rotation.z")
        XCTAssertEqual(turns.duration, 0.6, accuracy: 0.001)
        let values = try XCTUnwrap(turns.values as? [Double])
        XCTAssertEqual(values.count, ChatRules.wiggleDegrees.count)
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 0)
        XCTAssertEqual(values.map { abs($0) }.max() ?? 0, 12 * Double.pi / 180, accuracy: 0.0001)
        // The bubble itself is left where it was: only the layer turns.
        XCTAssertEqual(view.transform, .identity)
    }

    /// The red number and the green dot are inside the bubble, so the turn
    /// carries them along.
    func testTheBadgesArePartOfTheBubble() {
        let view = bubble()
        view.update(unread: 2, online: true)
        let badges = view.subviews.filter { !($0 is UIVisualEffectView) }
        XCTAssertEqual(badges.count, 2)
        XCTAssertTrue(badges.allSatisfy { $0.superview === view })
    }

    func testAWiggleInProgressIsNotStartedAgain() {
        let view = bubble()
        view.wiggle()
        let first = view.layer.animation(forKey: ChatBubbleView.wiggleKey)
        view.wiggle()
        XCTAssertTrue(view.layer.animation(forKey: ChatBubbleView.wiggleKey) === first)
        XCTAssertFalse(view.isDragging)
    }
}
#endif
