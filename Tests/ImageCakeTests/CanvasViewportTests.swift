import CoreGraphics
import XCTest
@testable import ImageCake

/// 画布视口几何。
///
/// 这组断言的动机：一旦画布能缩放，「框选位置 ↔ 归一化坐标」就成了一次
/// 换算。它错了只表现为「选框比想象中偏一点」，越放大越明显，但在真机上
/// 没法判断是代码错了还是自己手抖。
final class CanvasViewportTests: XCTestCase {
    // 铺满容器的 4:3 画布：这是 fit() 的常见结果（等比适配会至少铺满一个方向）。
    private let container = CGSize(width: 400, height: 300)
    private let fitted = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func makeViewport(scale: CGFloat = 1, offset: CGSize = .zero) -> CanvasViewport {
        CanvasViewport(container: container, fitted: fitted, scale: scale, offset: offset)
    }

    func testFittedViewportMatchesFitRect() {
        let viewport = makeViewport()
        XCTAssertTrue(viewport.isFitted)
        XCTAssertEqual(viewport.imageRect, fitted)
    }

    /// 归一化坐标与视图坐标必须互为反函数，否则叠加/选区会随缩放漂移。
    func testNormalizedRoundTripsThroughImageRect() {
        let viewport = makeViewport(scale: 2.5, offset: CGSize(width: -120, height: 60))
        let rect = viewport.imageRect
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.7), CGPoint(x: 1, y: 1)] {
            let viewPoint = CGPoint(x: rect.minX + point.x * rect.width,
                                    y: rect.minY + point.y * rect.height)
            let back = viewport.normalized(viewPoint)
            XCTAssertEqual(back?.x ?? .nan, point.x, accuracy: 1e-6)
            XCTAssertEqual(back?.y ?? .nan, point.y, accuracy: 1e-6)
        }
    }

    func testNormalizedRejectsPointsOutsideImage() {
        let viewport = makeViewport()
        // fitted 正好铺满容器，所以容器外一点就是图像外。
        XCTAssertNil(viewport.normalized(CGPoint(x: -1, y: 150)))
        XCTAssertNil(viewport.normalized(CGPoint(x: 200, y: 301)))
    }

    /// 框选拖出画布时，选区要被夹进图像内——否则会传出一个宽度 > 1 的矩形，
    /// 下游按比例换算时直接越界。
    func testSelectionRectClampsToImage() {
        let viewport = makeViewport()
        let rect = viewport.selectionRect(from: CGPoint(x: -50, y: -50),
                                          to: CGPoint(x: 500, y: 500))
        XCTAssertEqual(rect.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(rect.maxX, 1, accuracy: 1e-6)
        XCTAssertEqual(rect.maxY, 1, accuracy: 1e-6)
    }

    func testSelectionRectNormalizesOrder() {
        // 从右下往左上拖，矩形仍是正的。
        let viewport = makeViewport()
        let rect = viewport.selectionRect(from: CGPoint(x: 300, y: 240),
                                          to: CGPoint(x: 100, y: 60))
        XCTAssertEqual(rect.minX, 0.25, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 0.2, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 0.6, accuracy: 1e-6)
    }

    /// 锚点缩放的核心契约：放大前后，锚点下方压着的图像内容不变。
    func testZoomKeepsAnchorContentInPlace() {
        let anchor = CGPoint(x: 300, y: 150)   // 中心偏右 100
        let before = makeViewport()
        let pivot = before.normalized(anchor)
        XCTAssertEqual(pivot?.x ?? .nan, 0.75, accuracy: 1e-6)

        let after = before.zoomed(to: 2, anchor: anchor)
        XCTAssertEqual(after.scale, 2, accuracy: 1e-6)
        XCTAssertEqual(after.normalized(anchor)?.x ?? .nan, 0.75, accuracy: 1e-6,
                       "放大后锚点下方的图像内容被移动了")
        XCTAssertEqual(after.normalized(anchor)?.y ?? .nan, pivot?.y ?? .nan, accuracy: 1e-6)
    }

    /// k = 1 时公式必须退化成"什么都不变"，否则反复捏合会累积漂移。
    func testZoomToSameScaleIsIdentity() {
        let viewport = makeViewport(scale: 2, offset: CGSize(width: -100, height: 40))
        let same = viewport.zoomed(to: 2, anchor: CGPoint(x: 120, y: 220))
        XCTAssertEqual(same.scale, viewport.scale, accuracy: 1e-9)
        XCTAssertEqual(same.offset.width, viewport.offset.width, accuracy: 1e-9)
        XCTAssertEqual(same.offset.height, viewport.offset.height, accuracy: 1e-9)
    }

    func testScaleIsClampedToRange() {
        let viewport = makeViewport()
        XCTAssertEqual(viewport.zoomed(to: 0.2, anchor: .zero).scale, CanvasViewport.minScale)
        XCTAssertEqual(viewport.zoomed(to: 99, anchor: .zero).scale, CanvasViewport.maxScale)
    }

    /// scale = 1 时图像正好铺满，不该允许平移（拖了也不动）。
    func testPanIsBlockedWhenImageFitsContainer() {
        let viewport = makeViewport().panned(by: CGSize(width: 120, height: -80))
        XCTAssertEqual(viewport.offset.width, 0, accuracy: 1e-9)
        XCTAssertEqual(viewport.offset.height, 0, accuracy: 1e-9)
    }

    /// 放大后平移会被夹在边界内：最多把图像边缘拖到容器边上，不露空白。
    func testPanIsClampedToImageEdges() {
        let zoomed = makeViewport(scale: 2)             // 800x600，横向余量 200、纵向 150
        let panned = zoomed.panned(by: CGSize(width: 9999, height: 9999))
        XCTAssertEqual(panned.offset.width, 200, accuracy: 1e-6)
        XCTAssertEqual(panned.offset.height, 150, accuracy: 1e-6)

        let opposite = zoomed.panned(by: CGSize(width: -9999, height: -9999))
        XCTAssertEqual(opposite.offset.width, -200, accuracy: 1e-6)
        XCTAssertEqual(opposite.offset.height, -150, accuracy: 1e-6)
    }

    func testResetReturnsToFitted() {
        let zoomed = makeViewport(scale: 3).panned(by: CGSize(width: 50, height: 50))
        XCTAssertFalse(zoomed.isFitted)
        let reset = zoomed.reset()
        XCTAssertTrue(reset.isFitted)
        XCTAssertEqual(reset.imageRect, fitted)
    }

    /// 传入的 scale 如果是 0 或负数，构造时就该夹住而不是留一个会让除法炸掉的值。
    func testInitClampsDegenerateScale() {
        XCTAssertEqual(makeViewport(scale: 0).scale, CanvasViewport.minScale)
        XCTAssertEqual(makeViewport(scale: -4).scale, CanvasViewport.minScale)
    }
}
