import AVFoundation
import Foundation

// 联机拍摄的采集壳：AVFoundation 的设备列表 + 一次快门。
//
// 这一层刻意做薄，而且**不测**：CI 上没有相机，真机上为了测它要点几十次
// 快门。可验证的部分（选设备、命名、连拍队列、缺件点名）全部在
// `TetherPlan` 里，是纯函数。这里只留"必须碰硬件"的那几行。
//
// 不做实时预览，理由不是省事：预览要 video data output + 像素缓冲到 CGImage
// 的转换，而那会带来一条跨线程写同一个变量的竞态（预览帧与 UI 读取）。
// 联机的实际诉求是"按完快门立刻在编辑器里看到这张"，回片缩略图已经满足，
// 不必为了"看着像专业软件"多养一层竞态。
//
// 权限：需要 Info.plist 的 `NSCameraUsageDescription`（已在 project.yml 声明），
// 首次调用会弹系统授权框；拒绝后 `discover()` 返回空列表，
// 面板据此显示 `[no_camera]` 而不是一个死掉的按钮。

final class TetherCapture: NSObject, AVCapturePhotoCaptureDelegate {
    enum CaptureError: LocalizedError {
        case denied
        case noDevice(String)
        case busy
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "[no_camera] 相机权限未获批准：系统设置 → ImageCake → 相机"
            case .noDevice(let detail): return "[no_camera] \(detail)"
            case .busy: return "[camera_busy] 上一张还在处理"
            case .timeout: return "[camera_timeout] 相机 10 秒没回片，检查连接线/供电"
            case .failed(let detail): return "[camera_failed] \(detail)"
            }
        }
    }

    /// 单张等待上限。相机自己缓冲满的时候，宁可报错也不要让 UI 卡死。
    static let captureTimeoutSeconds: Double = 10

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var heldDevice: AVCaptureDevice?
    /// 已配好的设备 id。换设备才重新配 session（`commitConfiguration` 不是便宜操作）。
    private(set) var configuredID: String?

    // 快门回调与调用侧之间只传一份 Data：用锁 + 条件等待，不用信号量
    // ——回调可能早于 wait 到达，信号量那种情况下会永久等待。
    private let lock = NSLock()
    private var pendingData: Data?
    private var pendingError: String?

    /// 系统列出的视频设备。
    ///
    /// 用 `builtInWideAngleCamera` 这一类去问是**故意**的：macOS 上的 USB 相机
    /// 与采集卡都会以这一类上报，而"外接/内置"的区分用 `position` 判断
    /// （内置摄像头有 front/back 方位，外接设备通常报 unspecified）。
    /// 不做厂商识别：那是 entitlement 与 USB 描述符的事，不是这里能确定的事。
    static func discover() -> [TetheredDevice] {
        let finder = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video,
                                                       position: .unspecified)
        return finder.devices.map { device in
            let external = device.position == .unspecified
            return TetheredDevice(id: device.uniqueID,
                                  name: device.localizedName,
                                  kind: external ? "external" : "builtIn",
                                  isUsable: device.isConnected)
        }
    }

    /// 申请相机权限。UI 在打开面板时调一次；被拒绝时后续都会点名。
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// 配好设备并开始跑 session。必须在**非主线程**调用：
    /// `startRunning()` 是阻塞调用，放主线程上的症状是"点开始之后整个界面定住"。
    func configure(deviceID: String) throws {
        guard let match = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                            mediaType: .video,
                                                            position: .unspecified).devices
            .first(where: { $0.uniqueID == deviceID }) else {
            throw CaptureError.noDevice("找不到 id 为 \(deviceID) 的设备")
        }
        if configuredID == deviceID, heldDevice != nil { return }

        try match.lockForConfiguration(nil)
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let old = deviceInput { session.removeInput(old) }
        let input = try AVCaptureDeviceInput(device: match)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            match.unlockForConfiguration()
            throw CaptureError.noDevice("设备无法作为输入接入")
        }
        session.addInput(input)
        // `session.outputs` 是 `[Any]`，拿 `contains(photoOutput)` 编译不过
        // （Any 没有 Equatable）；身份比较用 `===`。输出只能加一次，先查再加。
        let hasPhotoOutput = session.outputs.contains { ($0 as AnyObject) === photoOutput }
        if !hasPhotoOutput, session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        match.unlockForConfiguration()
        deviceInput = input
        heldDevice = match
        configuredID = deviceID
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    /// 按一次快门，等回片（JPEG 字节）。必须在**非主线程**调：它会阻塞到回片。
    func capture() throws -> Data {
        guard session.isRunning, session.outputs.contains(where: { ($0 as AnyObject) === photoOutput }) else {
            throw CaptureError.noDevice("还没配好设备")
        }
        let settings = AVCapturePhotoSettings()
        lock.lock()
        pendingData = nil
        pendingError = nil
        lock.unlock()

        photoOutput.capturePhoto(with: settings, delegate: self)

        let deadline = Date().addingTimeInterval(Self.captureTimeoutSeconds)
        while Date() < deadline {
            lock.lock()
            let data = pendingData
            let failure = pendingError
            pendingData = nil
            pendingError = nil
            lock.unlock()
            if let data { return data }
            if let failure { throw CaptureError.failed(failure) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CaptureError.timeout
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    /// 方法名必须是 `photoOutput(_:didFinishProcessingPhoto:error:)`。
    /// 写成 `capture(...)` 只会得到一个"nearly matches optional requirement"警告，
    /// 而不是错 —— 症状是快门按了但永远等不到回片，最后报 `[camera_timeout]`。
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            pendingError = error.localizedDescription
            return
        }
        pendingData = photo.fileDataRepresentation()
    }
}
