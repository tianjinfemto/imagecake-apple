import XCTest
@testable import ImageCake

/// 导出文件名模板。
///
/// 这组断言盯的是「导出失败」最常见的两种起因：文件名里混进路径分隔符，
/// 以及模板写错（缺扩展名、空模板、拼错占位符）。这些在 UI 里写死就
/// 再也测不到了。
final class ExportNamingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    /// 固定时间：2026-10-29 14:05:07 UTC。用 UTC 构造、传 UTC 进去，
    /// 断言才不会随跑测试的机器时区飘。
    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 29
        components.hour = 14
        components.minute = 5
        components.second = 7
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: components)!
    }

    func testExpandsAllTokens() {
        let name = ExportNaming.filename(template: "{stem}_{date}_{time}_{index}.{ext}",
                                        stem: "photo",
                                        ext: "jpg",
                                        date: fixedDate,
                                        index: 3,
                                        timeZone: utc)
        XCTAssertEqual(name, "photo_20261029_140507_003.jpg")
    }

    /// 默认模板必须与实现模板之前的行为完全一致，否则老用户的导出习惯被打断。
    func testDefaultTemplateKeepsPreviousBehaviour() {
        let name = ExportNaming.filename(template: ExportNaming.defaultTemplate,
                                        stem: "IMG_0001",
                                        ext: "jpeg",
                                        timeZone: utc)
        XCTAssertEqual(name, "IMG_0001-imagecake.jpeg")
    }

    /// 模板里没写 {ext} 时自动补：缺扩展名会让文件系统/导出器去猜类型。
    func testMissingExtensionIsAppended() {
        let name = ExportNaming.filename(template: "{stem}-out",
                                        stem: "photo",
                                        ext: "png",
                                        timeZone: utc)
        XCTAssertEqual(name, "photo-out.png")
    }

    /// 路径分隔符与 Windows 保留字符必须在生成阶段就清掉——
    /// 否则错误会拖到写盘那一刻才出现，而且报的是“路径非法”，很难联想到文件名。
    func testIllegalCharactersAreStripped() {
        let name = ExportNaming.filename(template: "{stem}.{ext}",
                                        stem: "a/b:c*d?e",
                                        ext: "jpg",
                                        timeZone: utc)
        XCTAssertEqual(name, "abcde.jpg")
    }

    func testBlankStemFallsBack() {
        let name = ExportNaming.filename(template: "{stem}.{ext}",
                                        stem: "   ",
                                        ext: "jpg",
                                        timeZone: utc)
        XCTAssertEqual(name, "imagecake.jpg")
    }

    /// 空模板会只剩 ".jpg"，那是隐藏文件；要兜底成可读的名字。
    func testEmptyTemplateFallsBackToReadableName() {
        let name = ExportNaming.filename(template: "", stem: "photo", ext: "jpg", timeZone: utc)
        XCTAssertEqual(name, "imagecake.jpg")
        XCTAssertFalse(name.hasPrefix("."), "不该生成隐藏文件")
    }

    /// 拼错的占位符原样保留，让用户在预览里看得见；静默换成空串会让人以为写对了。
    func testUnknownTokenIsPreserved() {
        let name = ExportNaming.filename(template: "{stme}-{ext}",
                                        stem: "photo",
                                        ext: "jpg",
                                        timeZone: utc)
        XCTAssertTrue(name.contains("{stme}"), "未知占位符被吃掉了：\(name)")
    }

    func testUnknownTokenDetection() {
        XCTAssertEqual(ExportNaming.unknownTokens(in: "{stem}-{foo}.{ext}"), ["{foo}"])
        XCTAssertTrue(ExportNaming.unknownTokens(in: ExportNaming.defaultTemplate).isEmpty)
        XCTAssertTrue(ExportNaming.unknownTokens(in: "plain-name").isEmpty)
        XCTAssertEqual(ExportNaming.unknownTokens(in: "{a}{b}"), ["{a}", "{b}"])
    }

    /// 序号固定三位，且 0/负数被夹到 1——模板写了 {index} 就不该出现 000。
    func testIndexIsPaddedAndClamped() {
        let a = ExportNaming.filename(template: "{index}", stem: "p", ext: "jpg", index: 0, timeZone: utc)
        XCTAssertEqual(a, "001.jpg")
        let b = ExportNaming.filename(template: "{index}", stem: "p", ext: "jpg", index: 42, timeZone: utc)
        XCTAssertEqual(b, "042.jpg")
        let c = ExportNaming.filename(template: "{index}", stem: "p", ext: "jpg", index: 1234, timeZone: utc)
        XCTAssertEqual(c, "1234.jpg", "超过三位不该被截断")
    }
}
