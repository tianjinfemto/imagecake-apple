import Foundation

// 批量队列：对多张图应用同一组参数/预设，批量导出。
//
// 不是并行处理——iPad 的内存只够一张一张来。队列串行执行，
// 每张完成后报告进度。失败的不中断队列，记进报告。

struct BatchItem: Identifiable, Sendable {
    var id: UUID = UUID()
    var url: URL
    var status: BatchItemStatus = .pending
    var error: String?
}

enum BatchItemStatus: String, Sendable {
    case pending, processing, done, failed
}

struct BatchConfig: Sendable {
    var params: EditParameters
    var format: ExportFormat
    var quality: Double = 0.92
    var maxEdge: Int = 0
    var outputDirectory: URL
    var namingTemplate: String = "{stem}_edited.{ext}"
}

struct BatchReport: Sendable {
    var total: Int
    var succeeded: Int
    var failed: Int
    var notes: [String]
}

enum BatchQueue {
    /// 串行处理队列。每完成一张调 onProgress。
    static func process(items: [BatchItem], config: BatchConfig,
                        store: ModelStore, ort: ORTEngine,
                        onProgress: @Sendable @MainActor (Int, Int) -> Void) async -> BatchReport {
        var results = items
        var succeeded = 0
        var failed = 0
        var notes: [String] = []

        for (index, item) in results.enumerated() {
            results[index].status = .processing
            await onProgress(index, items.count)

            do {
                let loaded = try await ImageLoader.load(url: item.url, maxEdge: 0)
                var doc = ImageDocument(loaded: loaded, url: item.url)
                doc.params = config.params

                let outcome = await ExportPipeline.render(doc, store: store, ort: ort, fullResolution: false)
                let data = try ExportPipeline.encode(outcome, format: config.format,
                                                      quality: config.quality, maxEdge: config.maxEdge)
                let filename = ExportNaming.filename(template: config.namingTemplate,
                                                      stem: item.url.deletingPathExtension().lastPathComponent,
                                                      ext: config.format.fileExtension)
                let outputURL = config.outputDirectory.appendingPathComponent(filename)
                try data.write(to: outputURL)
                results[index].status = .done
                succeeded += 1
            } catch {
                results[index].status = .failed
                results[index].error = error.localizedDescription
                failed += 1
                notes.append("[batch] \(item.url.lastPathComponent): \(error.localizedDescription)")
            }

            await onProgress(index + 1, items.count)
        }

        return BatchReport(total: items.count, succeeded: succeeded, failed: failed, notes: notes)
    }
}