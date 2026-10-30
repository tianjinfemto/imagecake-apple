import Foundation

// 撤销栈里的一格。
//
// 为什么是 params + brush 两个字段，而不是给笔刷单独做第二个栈：单栈时
// 「改曝光 → 液化一笔 → 撤销」回到的是有液化、没改曝光的状态；两个栈各自
// 撤销，同一步操作会先弹出哪一边完全看实现顺序，用户看不出规律。撤销的
// 心智模型是「回到上一步」，那就必须是一个栈、一格装下那一步的全部状态。
//
// AI 资产（人像 α、修复补丁）仍然不在这里——理由与 ParameterHistory 头部
// 那条一致：它们是算出来的几十 MB，回退它们没有产品意义，而且各自有
// 明确的入口（清除抠图 / 撤销最近一次消除）。
struct EditSnapshot: Equatable, Sendable {
    var params: EditParameters
    var brush: BrushState

    init(params: EditParameters = EditParameters(), brush: BrushState = BrushState()) {
        self.params = params
        self.brush = brush
    }

    /// 从文档取当前可逆状态。渲染与历史都用这一个入口，避免两边读到的
    /// 不是同一份笔刷。
    init(_ document: ImageDocument) {
        self.params = document.params
        self.brush = document.brush
    }
}
