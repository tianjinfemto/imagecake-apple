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
}
