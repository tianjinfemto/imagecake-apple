#!/usr/bin/env bash
# 推上 GitHub 并看着 CI 跑完（需要先 gh auth login）。
#
# 这一步只能在你自己的机器上做：它用的是你的 GitHub 凭据。
# 用法：
#   bash scripts/create_repo.sh [仓库名]
#   bash scripts/create_repo.sh imagecake-apple --public

set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "缺少 GitHub CLI：brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null || { echo "先登录：gh auth login"; exit 1; }

REPO_NAME="${1:-imagecake-apple}"
shift || true
VISIBILITY="${1:---private}"

if [ ! -d .git ]; then
  git init -q
  git add -A
  git -c user.name="$(git config user.name || echo imagecake)" \
      -c user.email="$(git config user.email || echo imagecake@local)" \
      commit -q -m "ImageCake for Apple: v0.1 (macOS + iPadOS, ONNX Runtime)"
fi

# --source=. --push 会同时建仓库、加 origin、推当前分支。
gh repo create "$REPO_NAME" "$VISIBILITY" --source=. --remote=origin --push

echo
echo "已推送。等待 CI："
gh run watch --exit-status || true
echo
echo "失败时看这一步："
echo "  gh run view --log-failed"
