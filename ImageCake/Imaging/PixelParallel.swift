import Foundation

/// 逐像素并行的统一入口。
///
/// 用它之前必须确认两件事，否则不要用：
///
/// ① `body` 只读源缓冲、只写属于自己那段 `[start, end)` 的位置 —— 不读邻域、也不跨
///    像素累加状态。满足时并行结果与串行版**逐比特相同**；反过来，带历史的滑窗不能这样
///    切：本项目把模糊裁到选区矩形时，以为"只跳过不改变算术"，实际累加器带着被跳过
///    行的 0 值滑进选区，整片结果错，被它自己的逐比特断言判红（见
///    docs/pixcake-parity.md §7）。滑窗能并行的是"每条行/列各自从下标 0 扫"，
///    所以那类内核留在各自文件里按行、按列分带，不从这里走。
///
/// ② 传进闭包的必须是指针而不是数组本身：多个线程同时改同一个 Swift 数组实例，
///    即使写的下标不相交也是未定义行为（数组不是线程安全的）。不相交的区间通过
///    同一个 `UnsafeMutableBufferPointer` 写才是本仓沿用的做法（同 `ToneEngine`）。
enum PixelParallel {
    /// 分带数。上限 16 是为了避免在大小核机器上把小任务切成过多碎片。
    static var bands: Int {
        Swift.min(Swift.max(1, ProcessInfo.processInfo.activeProcessorCount), 16)
    }

    /// 按像素数分带。小图直接单线程走完：开线程的固定开销会盖掉收益，
    /// 而这不改变任何结果（同一段算术，只是没分给多个线程）。
    static func forEach(_ count: Int, _ body: (Int, Int) -> Void) {
        guard count > 0 else { return }
        let n = bands
        guard count >= 4096, n > 1 else {
            body(0, count)
            return
        }
        DispatchQueue.concurrentPerform(iterations: n) { band in
            let start = count * band / n
            let end = count * (band + 1) / n
            if end > start { body(start, end) }
        }
    }

    /// 按行分带，给 `for y { for x { ... } }` 形状的内核用。
    /// 垂直方向的核要读相邻行时，必须确保被读的那一遍**已经全部写完**
    /// （各内核靠两次 `forEachRow` 之间的同步屏障保证这一点）。
    static func forEachRow(_ height: Int, _ body: (_ yStart: Int, _ yEnd: Int) -> Void) {
        guard height > 0 else { return }
        let n = bands
        guard height >= 64, n > 1 else {
            body(0, height)
            return
        }
        DispatchQueue.concurrentPerform(iterations: n) { band in
            let yStart = height * band / n
            let yEnd = height * (band + 1) / n
            if yEnd > yStart { body(yStart, yEnd) }
        }
    }
}
