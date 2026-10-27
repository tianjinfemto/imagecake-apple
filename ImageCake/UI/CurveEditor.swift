import SwiftUI

// 曲线编辑器。
//
// 弧线走的是 CurveMath.lut —— 与烘进像素的是同一段插值，不允许 UI 另画一份
// "好看的形状"（imagecake 的 sample_curve 是同一条立场）。
//
// 端点只能上下拖（x 锚在 0/1）；内点可以左右拖，但夹在相邻点之间，
// 保证 x 严格递增——否则曲线在 [0,0]–[1,1] 之外没有定义，黑场/白场就变成
// 实现细节。

struct CurveEditorView: View {
    @Binding var curves: [CurveChannel]
    @State private var channel = 0

    private let labels = ["RGB", "红", "绿", "蓝"]

    var body: some View {
        VStack(spacing: 8) {
            Picker("通道", selection: $channel) {
                ForEach(0 ..< labels.count, id: \.self) { index in
                    Text(labels[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let plot = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 12, dy: 12)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.28))
                    grid(in: plot)
                    curvePath(in: plot)
                    handles(in: plot)
                }
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 8) {
                Button("加点") { addPoint() }
                Button("重置") { resetChannel() }
                Spacer()
                Text("控制点 \(curve.x.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - 数据

    private var safeChannel: Int { min(max(channel, 0), 3) }

    private var curve: CurveChannel {
        guard curves.count == 4 else { return .identity }
        return curves[safeChannel]
    }

    private func update(_ body: (inout CurveChannel) -> Void) {
        guard curves.count == 4 else { return }
        var copy = curves
        body(&copy[safeChannel])
        if copy[safeChannel].isValid {
            curves = copy
        }
    }

    private func addPoint() {
        update { channel in
            guard channel.x.count < 16 else { return }
            // 在最长的一段中间插一个点，y 取该处的曲线值（插上去不改变形状）。
            let lut = CurveMath.lut(channel)
            var bestIndex = 0
            var bestGap = 0.0
            for i in 0 ..< (channel.x.count - 1) {
                let gap = channel.x[i + 1] - channel.x[i]
                if gap > bestGap { bestGap = gap; bestIndex = i }
            }
            let x = (channel.x[bestIndex] + channel.x[bestIndex + 1]) / 2
            let y = Double(CurveMath.sample(lut, Float(x)))
            channel.x.insert(x, at: bestIndex + 1)
            channel.y.insert(y, at: bestIndex + 1)
        }
    }

    private func resetChannel() {
        update { $0 = .identity }
    }

    private func move(index: Int, to normalized: CGPoint, in plot: CGRect) {
        update { channel in
            var x = channel.x[index]
            var y = channel.y[index]
            y = Double(min(max((plot.maxY - normalized.y) / plot.height, 0), 1))
            if index > 0, index < channel.x.count - 1 {
                let lower = channel.x[index - 1] + 0.01
                let upper = channel.x[index + 1] - 0.01
                x = Double(min(max((normalized.x - plot.minX) / plot.width, lower), upper))
            }
            channel.x[index] = x
            channel.y[index] = y
        }
    }

    // MARK: - 绘制

    private func grid(in plot: CGRect) -> some View {
        Path { path in
            for i in 0 ... 4 {
                let t = CGFloat(i) / 4
                let x = plot.minX + t * plot.width
                let y = plot.minY + t * plot.height
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        .stroke(Tokens.border.opacity(0.6), lineWidth: 0.5)
    }

    private func curvePath(in plot: CGRect) -> some View {
        let lut = CurveMath.lut(curve)
        return Path { path in
            for i in 0 ..< lut.count {
                let t = CGFloat(i) / CGFloat(lut.count - 1)
                let point = CGPoint(x: plot.minX + t * plot.width,
                                    y: plot.maxY - CGFloat(lut[i]) * plot.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        .stroke(Tokens.accent, lineWidth: 1.6)
    }

    private func handles(in plot: CGRect) -> some View {
        ForEach(Array(curve.x.indices), id: \.self) { index in
            let point = CGPoint(x: plot.minX + CGFloat(curve.x[index]) * plot.width,
                                y: plot.maxY - CGFloat(curve.y[index]) * plot.height)
            Circle()
                .fill(Tokens.bgWindow)
                .overlay(Circle().stroke(Tokens.accent, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .position(point)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            move(index: index, to: value.location, in: plot)
                        }
                )
        }
    }
}
