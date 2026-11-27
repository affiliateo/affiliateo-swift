#if os(iOS)
import UIKit
import XCTest
@testable import Affiliateo

/// The bubble's wiggle (4.17.0): the whole bubble turns left and right and
/// grows a touch, on the bubble's own layer, so its circle, its icon, its red
/// number and its green dot move as one piece, drawn on every frame.
@MainActor
final class ChatBubbleWiggleTests: XCTestCase {
    private func bubble() -> ChatBubbleView {
        ChatBubbleView(appId: "wiggle-tests", size: 56) {}
    }

    private func parts(_ view: ChatBubbleView) throws -> (group: CAAnimationGroup, turn: CAKeyframeAnimation, size: CAKeyframeAnimation) {
        let group = try XCTUnwrap(view.layer.animation(forKey: ChatBubbleView.wiggleKey) as? CAAnimationGroup)
        let animations = try XCTUnwrap(group.animations as? [CAKeyframeAnimation])
        let turn = try XCTUnwrap(animations.first { $0.keyPath == "transform.rotation.z" })
        let size = try XCTUnwrap(animations.first { $0.keyPath == "transform.scale" })
        return (group, turn, size)
    }

    func testOneWiggleTurnsAndGrowsTheWholeBubbleAndEndsAtRest() throws {
        let view = bubble()
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        view.wiggle()
        let (group, turn, size) = try parts(view)
        XCTAssertEqual(group.animations?.count, 2)
        XCTAssertEqual(group.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(turn.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(size.duration, 0.9, accuracy: 0.0001)

        let turns = try XCTUnwrap(turn.values as? [Double])
        XCTAssertEqual(turns.first, 0)
        XCTAssertEqual(turns.last, 0)
        let largest = (turns.map { abs($0) }.max() ?? 0) * 180 / Double.pi
        XCTAssertGreaterThan(largest, 13)
        XCTAssertLessThan(largest, 15)

        let sizes = try XCTUnwrap(size.values as? [Double])
        XCTAssertEqual(sizes.first, 1)
        XCTAssertEqual(sizes.last, 1)
        XCTAssertEqual(sizes.max() ?? 0, 1.06, accuracy: 0.0001)

        // The bubble itself is left where it was: only its layer moves.
        XCTAssertEqual(view.transform, .identity)
    }

    /// The first version played seven turns that each eased to a stop, which
    /// looked jerky. This one has a sample for every frame, straight steps
    /// between them and no easing anywhere.
    func testItIsDrawnOnEveryFrameWithNoEasing() throws {
        let view = bubble()
        view.wiggle()
        let (group, turn, size) = try parts(view)
        let turns = try XCTUnwrap(turn.values as? [Double])
        let sizes = try XCTUnwrap(size.values as? [Double])
        XCTAssertEqual(turns.count, ChatRules.wiggleSteps + 1)
        XCTAssertEqual(sizes.count, ChatRules.wiggleSteps + 1)
        XCTAssertGreaterThanOrEqual(turns.count, 55)
        XCTAssertEqual(turn.calculationMode, .linear)
        XCTAssertEqual(size.calculationMode, .linear)
        XCTAssertNil(turn.keyTimes, "evenly spaced")
        XCTAssertNil(turn.timingFunctions)
        XCTAssertNil(size.timingFunctions)
        XCTAssertNil(turn.timingFunction)
        XCTAssertNil(size.timingFunction)
        var c1: [Float] = [0, 0]
        var c2: [Float] = [0, 0]
        group.timingFunction?.getControlPoint(at: 1, values: &c1)
        group.timingFunction?.getControlPoint(at: 2, values: &c2)
        XCTAssertEqual(c1, [0, 0], "linear")
        XCTAssertEqual(c2, [1, 1], "linear")
    }

    /// The red number, the green dot and the hold's red X (4.19.0) are
    /// inside the bubble, so the turn and the growing carry them along.
    func testTheBadgesArePartOfTheBubble() {
        let view = bubble()
        view.update(unread: 2, online: true)
        let badges = view.subviews.filter { !($0 is UIVisualEffectView) }
        XCTAssertEqual(badges.count, 3)
        XCTAssertTrue(badges.contains(view.hideBadge))
        XCTAssertTrue(badges.allSatisfy { $0.superview === view })
    }

    func testAWiggleInProgressIsNotStartedAgain() {
        let view = bubble()
        view.wiggle(now: 100)
        let first = view.layer.animation(forKey: ChatBubbleView.wiggleKey)
        XCTAssertNotNil(first)
        view.wiggle(now: 100.5)
        XCTAssertTrue(view.layer.animation(forKey: ChatBubbleView.wiggleKey) === first)
        view.wiggle(now: 100.89)
        XCTAssertTrue(view.layer.animation(forKey: ChatBubbleView.wiggleKey) === first)
        XCTAssertFalse(view.isDragging)
    }

    /// Core Animation can leave a finished wiggle on the layer until it next
    /// tidies up. Going by that made every second wiggle of an idle app skip
    /// (seen in a recording: one every 6 seconds for a setting of 3). The
    /// clock decides: once the 0.9 s are over, the next one plays.
    func testAFinishedWiggleLeftOnTheLayerDoesNotBlockTheNext() {
        let view = bubble()
        view.wiggle(now: 100)
        let first = view.layer.animation(forKey: ChatBubbleView.wiggleKey)
        XCTAssertNotNil(first)
        // 3 seconds later the first one is over, and here it is still attached.
        view.wiggle(now: 103)
        let second = view.layer.animation(forKey: ChatBubbleView.wiggleKey)
        XCTAssertNotNil(second)
        XCTAssertFalse(second === first, "a new wiggle replaced the finished one")
        // Once its own 0.9 s are over it may start again.
        view.wiggle(now: 104)
        XCTAssertFalse(view.layer.animation(forKey: ChatBubbleView.wiggleKey) === second)
    }

    /// A drag, a hidden bubble or the chat opening cuts it: back to rest at once.
    func testAWiggleCanBeCutCleanly() {
        let view = bubble()
        view.wiggle()
        XCTAssertNotNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        view.stopWiggle()
        XCTAssertNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
        XCTAssertEqual(view.transform, .identity)
        XCTAssertTrue(CATransform3DIsIdentity(view.layer.transform))
        // And it can play again right away afterwards.
        view.wiggle()
        XCTAssertNotNil(view.layer.animation(forKey: ChatBubbleView.wiggleKey))
    }
}
#endif
