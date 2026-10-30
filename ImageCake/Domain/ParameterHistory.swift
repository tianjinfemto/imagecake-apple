import Foundation

// 参数撤销/重做。
//
// 为什么只存 EditParameters 而不是整份 ImageDocument：编辑参数是可逆的，
// AI 资产（人像 α、修复补丁）一旦算出来就不随调色变化。把它们也存进历史，
// 内存会按张数乘以几十 MB，而回退一棵 α 掩码也没有产品意义。
//
// 为什么做成值类型而不是类：它要能在测试里被直接构造、比较、断言，
// 不需要 UI、不需要模型、不需要图。
//
// 为什么不锁定在 EditParameters 上：笔迹体系（液化/图章/保护笔刷）需要完全
// 相同的栈语义，而它的可逆数据也是值。把栈做成泛型，笔刷就复用同一份
// 经过断言的语义，而不是开第二个栈——两个栈各自撤销时，“撤销”到底撤的是
// 哪一边没人猜得到。锁在泛型参数上的只有 Equatable（空操作不入栈）。
//
// 合并策略不在这里：滑杆拖一下会产生几十次 commit，“什么时候算一步”
// 是 UI 的节奏问题（EditorModel 用防抖解决），不是栈的职责。栈只保证
// 「相邻且相同的值不重复入栈」。

// 栈上限的默认值。
//
// 为什么不放进 `ParameterHistory` 里当 `static let`：Swift 不允许泛型类型有
// 存储型静态成员（`static stored properties not supported in generic types`），
// 泛型参数会让「同一个类型的不同实例共享哪一个静态存储」没有定义。
// 单独开一个无泛型的枚举当命名空间，值仍然只有一处可改。
enum HistoryLimit {
    /// 50 步够覆盖一次常规精修的回退，又不至于把内存拖长。
    static let steps = 50
}

struct ParameterHistory<Value: Equatable>: Equatable {
    private(set) var past: [Value] = []
    private(set) var future: [Value] = []
    private(set) var present: Value
    let limit: Int

    init(initial: Value, limit: Int = HistoryLimit.steps) {
        self.present = initial
        self.limit = max(1, limit)
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// 记录一步。值没变就直接返回，不制造空历史——
    /// 否则「点了滑杆但没动」也会占掉一格撤销。
    /// 这一条对笔刷同样成立：涂了两笔完全重合的保护笔刷不该吃掉两格历史。
    mutating func commit(_ next: Value) {
        guard next != present else { return }
        past.append(present)
        if past.count > limit {
            past.removeFirst(past.count - limit)
        }
        present = next
        // 在旧状态上做了新改动，原来的重做分支就失效了。
        future.removeAll()
    }

    /// 回退一步并返回回退后的状态。没得退时返回 nil。
    @discardableResult
    mutating func undo() -> Value? {
        guard let previous = past.popLast() else { return nil }
        future.append(present)
        present = previous
        return previous
    }

    @discardableResult
    mutating func redo() -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(present)
        present = next
        return next
    }

    /// 换图/重置：历史整体作废。`present` 跟着换成新起点。
    mutating func reset(to value: Value) {
        past.removeAll()
        future.removeAll()
        present = value
    }

    /// 改写栈顶那一格，不新增历史。
    ///
    /// 为什么需要：有些操作只影响快照的一部分——「复位调色」不该把笔刷
    /// 一起清掉，但栈里的一格是 params + brush 整体。不先修正栈顶，下一次
    /// commit 就会把「复位」与「之后的笔刷」并成一步，撤销时两者一起消失。
    /// 这个口子只改 present，所以不会让 canUndo 凭空变 true。
    mutating func amendPresent(_ body: (inout Value) -> Void) {
        body(&present)
    }
}
