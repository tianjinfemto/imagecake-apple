import SwiftUI

// 双端入口。一个 WindowGroup 同时出 macOS 与 iPadOS——
// 这不是"跨平台壳"，而是同一份 SwiftUI 视图树在两个平台上各自原生渲染：
// 工具栏在 iPad 上进导航栏、在 Mac 上进标题栏，文件选择器各自是系统那一套。
//
// 平台差异用 `#if` 包**完整的 Scene 表达式**，不包链上的单个修饰符
// （后者不是完整语句，Swift 不接受）。

@main
struct ImageCakeApp: App {
    @StateObject private var model = EditorModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            root
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            // 这是一个修图器，不是文档型编辑器：把"新建文稿"换成空组，
            // 避免菜单里出现一个点了没反应的项。
            CommandGroup(replacing: .newItem) { }
        }
        #else
        WindowGroup {
            root
        }
        #endif
    }

    private var root: some View {
        EditorView()
            .environmentObject(model)
    }
}
