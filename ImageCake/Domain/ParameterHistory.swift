import Foundation

// 参数撤销/重做。
//
// 为什么只存 EditParameters 而不是整份 ImageDocument：编辑参数是可逆的，
// AI 资产（人像 α、修复补丁）一旦算出来就不随调色变化。把它们也存进历史，
// 内存会按张数乘以几十 MB，而回退一棵 α 掩码也没有产品意义。
//
// 为什么做成值类型而不是类：它要能在测试里被直接构造、比较、断言，
// 不需要 UI、不需要模型、不需要图。笔迹体系（液化/图章/保护笔刷）以后
// 会复用同一份栈语义——那些操作的可逆数据也应当是值。
//
// 合并策略不在这里：滑杆拖一下会产生几十次 commit，"什么时候算一步"
// 是 UI 的节奏问题（EditorModel 用防抖解决），不是栈的职责。栈只保证
// 「相邻且相同的值不重复入栈」。

struct ParameterHistory: Equatable {
    /// 栈上限。50 步够覆盖一次常规精修的回退，又不至于把内存拖长。
    static let defaultLimit = 50

    private(set) var past: [EditParameters] = []
    private(set) var future: [EditParameters] = []
    private(set) var present: EditParameters
    let limit: Int

    init(initial: EditParameters = EditParameters(), limit: Int = ParameterHistory.defaultLimit) {
        self.present = initial
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// 记录一步。值没变就直接返回，不制造空历史——
    /// 否则「点了滑杆但没动」也会占掉一格撤销。
    mutating func commit(_ next: EditParameters) {
        guard next != present else { return }
        past.append(present)
        if past.count > limit {
            past.removeFirst(past.count - limit)
        }
        present = next
        // 在旧状态上做了新改动，原来的重做分支就失效了。
        future.removeAll()
    }

    /// 回退一步并返回回退后的参数。没得退时返回 nil。
    @discardableResult
    mutating func undo() -> EditParameters? {
        guard let previous = past.popLast() else { return nil }
        future.append(present)
        present = previous
        return previous
    }

    @discardableResult
    mutating func redo() -> EditParameters? {
        guard let next = future.popLast() else { return nil }
        past.append(present)
        present = next
        return next
    }

    /// 换图/重置：历史整体作废。`present` 跟着换成新起点。
    mutating func reset(to value: EditParameters = EditParameters()) {
        past.removeAll()
        future.removeAll()
        present = value
    }
}
