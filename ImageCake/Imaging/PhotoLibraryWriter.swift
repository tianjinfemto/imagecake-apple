#if os(iOS)
import Foundation
import Photos

// 存入系统相册。仅 iOS/iPadOS。
//
// 为什么单独一个文件而不是塞进 ImageLoader：ImageLoader 是「字节 ↔ 图像」的
// 纯函数集合，不碰系统权限；相册是**权限 + TCC + 照片库事务**，失败原因
// 五花八门且必须原样告诉用户（本项目的立场：缺件点名，不静默降级）。
//
// 只申请 .addOnly：我们只写不读，申请完整访问权限属于越权，
// 而且完整权限会触发系统弹更重的授权框。
//
// 为什么整个文件包在 #if os(iOS) 里：Photos 的部分 API 在 macOS 上的
// 可用性与行为与 iOS 不一致（App Sandbox 下还需要额外的 entitlement），
// 而本项目在 macOS 侧不提供相册入口——那边用 Files 更自然。收敛成 iOS-only
// 就不必在 macOS 上赌 API 的可用性；iOS Simulator 的构建 job 仍会编译这里。

enum PhotoLibraryError: LocalizedError {
    /// 用户拒绝、或被「屏幕使用时间」限制。
    case denied
    /// 权限已定但写入失败（空间不足、编码不被接受、照片库不可用）。
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return "[photos_denied] 相册写入权限被拒；到「设置 → 隐私与安全性 → 照片」里允许，或改用「文件」导出"
        case .failed(let detail):
            return "[photos_failed] 写入相册失败：\(detail)"
        }
    }
}

enum PhotoLibraryWriter {
    /// 把一整个图像文件（JPEG/HEIC/PNG 的字节）作为一张照片写进相册。
    ///
    /// 不转码、不重新编码：交给照片库自己处理容器。这样 Files 与相册两条路
    /// 拿到的是同一份编码结果。
    static func save(_ data: Data) async throws {
        guard !data.isEmpty else {
            throw PhotoLibraryError.failed("数据为空")
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted:
            throw PhotoLibraryError.denied
        case .notDetermined:
            // 申请之后仍是未决，通常是系统的授权框没弹出来（被家长控制、
            // 或 Info.plist 少了用途说明）。
            throw PhotoLibraryError.failed("授权状态未确定，系统没有弹出授权框")
        @unknown default:
            throw PhotoLibraryError.failed("未知授权状态 \(status.rawValue)")
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        } catch {
            throw PhotoLibraryError.failed(error.localizedDescription)
        }
    }
}
#endif
