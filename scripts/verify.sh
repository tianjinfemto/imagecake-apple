#!/usr/bin/env bash
# 本机（macOS）一条命令跑完 CI 的全部检查。
#
# 与 .github/workflows/ci.yml 同序：生成工程 → 校验清单 → 跑测试 → 构建 iOS。
# 为什么还要一份本地脚本：CI 一次排队要几分钟，而开发机上想把
# "改一行、验一次"压到一条命令。

set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 1/4 工具链 =="
command -v xcodegen >/dev/null || { echo "缺少 XcodeGen：brew install xcodegen"; exit 1; }
xcodegen version
xcodebuild -version

echo
echo "== 2/4 模型清单（只读，不下载）=="
python3 scripts/fetch_models.py --list

echo
echo "== 3/4 生成工程 =="
xcodegen generate

echo
echo "== 4/4 测试（macOS）+ 构建（iOS Simulator）=="
mkdir -p build
xcodebuild \
  -project ImageCake.xcodeproj \
  -scheme ImageCake \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "build/Test-$(date +%Y%m%d-%H%M%S).xcresult" \
  test

xcodebuild \
  -project ImageCake.xcodeproj \
  -scheme ImageCake \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  build

echo
echo "全部通过。"
