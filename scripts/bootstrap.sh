#!/usr/bin/env bash
# 在 macOS 上生成 Xcode 工程。
#
# 为什么需要这一步：仓库只提交 project.yml（唯一真相），不提交 .xcodeproj。
# 这样平台清单、部署版本、SPM 依赖只有一处可改，也不会出现 pbxproj 里
# 两处不一致的经典问题。

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen。安装：brew install xcodegen"
  exit 1
fi

# XcodeGen 的 supportedDestinations 需要 2.42+（双端单 target）。
version="$(xcodegen version 2>/dev/null | awk '{print $NF}')"
echo "XcodeGen ${version:-unknown}"

xcodegen generate

echo
echo "已生成 ImageCake.xcodeproj"
echo "下一步："
echo "  1) open ImageCake.xcodeproj"
echo "  2) 在 Signing & Capabilities 里选自己的 Team（macOS 本地跑可跳过）"
echo "  3) 首次构建需要联网解析 ONNX Runtime 的 SPM 二进制包"
echo
echo "可选：把 core 档权重放进 App 包（也可在 App 的「模型」页下载/导入）"
echo "  python3 scripts/fetch_models.py --tier core"
