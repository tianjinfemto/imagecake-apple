import Foundation

// XMP 导入：把 Adobe Lightroom / Camera Raw 的编辑参数映射到 EditParameters。
//
// XMP 是 RDF/XML 格式，crs:（Camera Raw Schema）命名空间下存调色参数。
// 映射表约 40 键，逐条对照 imagecake 的 XmpImporter。
//
// 不做完整 XML 解析（太重）：用正则抽 crs: 属性，按映射表赋值。
// 未知键不报错，跳过——XMP 版本多、各家扩展多，点名到每一个不现实。

enum XMPImporter {
    /// 从 XMP 字符串导入参数。返回更新后的 EditParameters + 未识别键列表。
    static func import_(_ xmp: String, into params: EditParameters) -> (EditParameters, unknownKeys: [String]) {
        var p = params
        var unknown: [String] = []
        let attrs = parseCRSAttributes(xmp)
        for (key, value) in attrs {
            if let mapped = mapKey(key) {
                apply(mapped, value: value, to: &p)
            } else if !key.isEmpty {
                unknown.append(key)
            }
        }
        p.clamp()
        return (p, unknown)
    }

    // MARK: - 解析

    /// 抽出 crs: 命名空间下的属性键值对。
    private static func parseCRSAttributes(_ xmp: String) -> [(String, String)] {
        var result: [(String, String)] = []
        // 匹配 crs:Key="value" 或 crs:Key='value'
        let pattern = #"crs:([A-Za-z0-9_]+)\s*=\s*["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(xmp.startIndex..., in: xmp)
        for match in regex.matches(in: xmp, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: xmp),
                  let valueRange = Range(match.range(at: 2), in: xmp) else { continue }
            result.append((String(xmp[keyRange]), String(xmp[valueRange])))
        }
        return result
    }

    // MARK: - 映射表

    private enum Mapping {
        case exposure, temperature, tint, contrast, saturation, hue
        case fillLight, highlightSoften, denoise, sharpen
        case defringe, bgBlur
        case hslHue(Int), hslSat(Int), hslLum(Int)
        case whHue, whSat, whLum, wmtHue, wmtSat, wmtLum, wshHue, wshSat, wshLum
    }

    private static func mapKey(_ key: String) -> Mapping? {
        switch key {
        case "Exposure2012": return .exposure
        case "Temperature": return .temperature
        case "Tint": return .tint
        case "Contrast2012": return .contrast
        case "Saturation": return .saturation
        case "HueAdjustment": return .hue
        case "FillLight2012": return .fillLight
        case "Highlights2012": return .highlightSoften
        case "LuminanceSmoothing": return .denoise
        case "Sharpness": return .sharpen
        case "Defringe": return .defringe
        case "Blur2012": return .bgBlur
        case "ConvertToGrayscale": return nil
        default:
            if key.hasPrefix("HueAdjustment") {
                let band = key.dropFirst("HueAdjustment".count)
                if let i = Int(band), i >= 0, i < 8 { return .hslHue(i) }
            }
            if key.hasPrefix("SaturationAdjustment") {
                let band = key.dropFirst("SaturationAdjustment".count)
                if let i = Int(band), i >= 0, i < 8 { return .hslSat(i) }
            }
            if key.hasPrefix("LuminanceAdjustment") {
                let band = key.dropFirst("LuminanceAdjustment".count)
                if let i = Int(band), i >= 0, i < 8 { return .hslLum(i) }
            }
            if key == "SplitToningShadowHue" { return .wshHue }
            if key == "SplitToningShadowSaturation" { return .wshSat }
            if key == "SplitToningShadowLuminance" { return .wshLum }
            if key == "SplitToningBalance" { return .wmtHue }
            return nil
        }
    }

    private static func apply(_ mapping: Mapping, value: String, to params: inout EditParameters) {
        guard let v = Double(value) else { return }
        switch mapping {
        case .exposure: params.exposure = v
        case .temperature:
            // crs:Temperature 是开尔文（2000...50000），app 用 -100...100（0 = 6500K）
            params.temperature = (v - 6500) / 50
        case .tint: params.tint = v
        case .contrast: params.contrast = v
        case .saturation: params.saturation = v
        case .hue: params.hue = v
        case .fillLight: params.fillLight = v
        case .highlightSoften: params.highlightSoften = v
        case .denoise: params.denoise = v
        case .sharpen: params.sharpen = v
        case .defringe: params.defringe = v
        case .bgBlur: params.bgBlur = v
        case .hslHue(let i): params.hslHue[i] = v
        case .hslSat(let i): params.hslSat[i] = v
        case .hslLum(let i): params.hslLum[i] = v
        case .wshHue: params.wshHue = v
        case .wshSat: params.wshSat = v
        case .wshLum: params.wshLum = v
        case .wmtHue: params.wmtHue = v
        case .wmtSat: params.wmtSat = v
        case .wmtLum: params.wmtLum = v
        case .whHue: params.whlHue = v
        case .whSat: params.whlSat = v
        case .whLum: params.whlLum = v
        }
    }
}