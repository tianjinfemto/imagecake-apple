import CoreGraphics
import XCTest
@testable import ImageCake

/// 参数撤销/重做。
///
/// 这组断言守的是栈语义本身：值没变不占格、撤销后新改动让重做失效、
/// 超上限丢最旧的。这些边界在 UI 上几乎不可能靠手点验证——用户不会
/// 为了测试「撤销后再改一步」而故意戳 50 次。
final class ParameterHistoryTests: XCTestCase {
    private func params(_ exposure: Double) -> EditParameters {
        var value = EditParameters()
        value.exposure = exposure
        return value
    }

    func testInitialStateHasNothingToUndoOrRedo() {
        let history = ParameterHistory(initial: params(0))
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.present, params(0))
    }

    func testCommitMovesPresentAndEnablesUndo() {
        var history = ParameterHistory(initial: params(0))
        history.commit(params(1))
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.present, params(1))
        XCTAssertEqual(history.past.count, 1)
    }

    /// 「点了滑杆但没动」不该占掉一格撤销。
    func testCommittingSameValueDoesNothing() {
        var history = ParameterHistory(initial: params(0))
        history.commit(params(0))
        history.commit(params(0))
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.past.isEmpty)
    }

    func testUndoRestoresPreviousAndEnablesRedo() {
        var history = ParameterHistory(initial: params(0))
        history.commit(params(1))
        history.commit(params(2))

        XCTAssertEqual(history.undo(), params(1))
        XCTAssertEqual(history.present, params(1))
        XCTAssertTrue(history.canRedo)

        XCTAssertEqual(history.undo(), params(0))
        XCTAssertFalse(history.canUndo)
    }

    func testUndoAtBottomReturnsNil() {
        var history = ParameterHistory(initial: params(0))
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.present, params(0))
    }

    func testRedoRestoresForward() {
        var history = ParameterHistory(initial: params(0))
        history.commit(params(1))
        history.undo()
        XCTAssertEqual(history.redo(), params(1))
        XCTAssertEqual(history.present, params(1))
        XCTAssertFalse(history.canRedo)
    }

    /// 撤销之后又做新改动时，原来那条重做分支必须失效——
    /// 否则重做会把用户的新修改覆盖掉。
    func testNewCommitAfterUndoClearsRedo() {
        var history = ParameterHistory(initial: params(0))
        history.commit(params(1))
        history.undo()
        XCTAssertTrue(history.canRedo)

        history.commit(params(5))
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.present, params(5))
    }

    /// 超上限时丢最旧的：limit = 3 时连推 5 步，可回退点应该是 2/3/4。
    func testOldestEntriesAreDroppedBeyondLimit() {
        var history = ParameterHistory(initial: params(0), limit: 3)
        for step in 1 ... 5 {
            history.commit(params(Double(step)))
        }
        XCTAssertEqual(history.past.count, 3)
        XCTAssertEqual(history.past.first, params(2))
        XCTAssertEqual(history.present, params(5))
    }

    func testResetClearsBothDirections() {
        var history = ParameterHistory(initial: params(0))
        history.commit(params(1))
        history.commit(params(2))
        history.undo()

        history.reset(to: params(9))
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.present, params(9))
    }

    // MARK: - 笔刷进历史

    /// 参数没变、只多了一笔笔迹时也必须入栈。这条挂了的症状很阴：
    /// 液化涂上去能看见，但撤销按下去“什么都没发生”。
    func testBrushOnlyChangeStillEntersHistory() {
        var stroke = LiquifyStroke()
        stroke.from = CGPoint(x: 0.5, y: 0.5)
        stroke.to = CGPoint(x: 0.6, y: 0.5)
        var brush = BrushState()
        brush.liquify = [stroke]

        var history = ParameterHistory(initial: EditSnapshot(params: params(0)))
        history.commit(EditSnapshot(params: params(0), brush: brush))
        XCTAssertTrue(history.canUndo, "只改笔刷没入栈")

        let restored = history.undo()
        XCTAssertEqual(restored?.brush, BrushState(), "撤销后笔迹没消失")
        XCTAssertEqual(restored?.params, params(0), "撤销不该动参数")

        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo()?.brush, brush, "重做后笔迹没回来")
    }

    /// 改写栈顶不得新增历史。`resetParams` 靠它把栈顶的 params 换掉而不清笔刷；
    /// 如果 amendPresent 自己也算一步，“复位调色”会在历史里多占一格。
    func testAmendPresentDoesNotCreateAnEntry() {
        var history = ParameterHistory(initial: EditSnapshot(params: params(0)))
        history.amendPresent { $0.params = params(3) }
        XCTAssertFalse(history.canUndo, "amendPresent 不该产生可撤销项")
        XCTAssertEqual(history.present.params, params(3))

        history.commit(EditSnapshot(params: params(4)))
        XCTAssertEqual(history.past.count, 1)
        XCTAssertEqual(history.past.first?.params, params(3))
    }
}
