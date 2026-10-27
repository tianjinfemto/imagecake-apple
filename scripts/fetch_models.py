#!/usr/bin/env python3
"""按清单下载 AI 权重。清单是唯一真相：ImageCake/Resources/Models/models.json。

与 imagecake 的 scripts/fetch_models.ps1 同一条立场：
  · 文件名/字节数/SHA-256 全部来自清单，脚本里不写第二份；
  · 先落临时文件、双重校验通过才搬进目标目录（半个文件比没有文件更坏）；
  · 缺件不静默——列出来，退出码非 0。

用法：
  python3 scripts/fetch_models.py --list
  python3 scripts/fetch_models.py                 # 只拉 core 档
  python3 scripts/fetch_models.py --tier all      # 全表（约 660MB）
  python3 scripts/fetch_models.py --only matting_modnet,superres_esrgan
  python3 scripts/fetch_models.py --mirror        # 先试 hf-mirror.com
  python3 scripts/fetch_models.py --dest ~/Library/Application\\ Support/ImageCake/models
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "ImageCake" / "Resources" / "Models" / "models.json"
DEFAULT_DEST = ROOT / "ImageCake" / "Resources" / "Models"

HOSTS = ("https://huggingface.co", "https://hf-mirror.com")


def human(n: int) -> str:
    return f"{n / 1_048_576:.1f} MB"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_manifest() -> dict:
    with MANIFEST.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if data.get("schema") != 1:
        raise SystemExit(f"[schema] 清单版本不认识：{data.get('schema')}")
    return data


def select(models: list[dict], tier: str, only: set[str]) -> list[dict]:
    if only:
        picked = [m for m in models if m["id"] in only or m["file"] in only]
        missing = only - {m["id"] for m in picked} - {m["file"] for m in picked}
        if missing:
            raise SystemExit(f"[unknown] 清单里没有：{', '.join(sorted(missing))}")
        return picked
    if tier == "all":
        return list(models)
    return [m for m in models if m.get("tier") == tier]


def download(url: str, target: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "imagecake-fetch/1.0"})
    with urllib.request.urlopen(req, timeout=600) as resp, target.open("wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        done = 0
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if total:
                pct = done * 100 // total
                sys.stdout.write(f"\r    下载 {pct:3d}%  {human(done)} / {human(total)}")
                sys.stdout.flush()
        sys.stdout.write("\r" + " " * 60 + "\r")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="只报账，不下载")
    parser.add_argument("--tier", default="core", choices=["core", "onDemand", "all"])
    parser.add_argument("--only", default="", help="按 id 或文件名点名（逗号分隔）")
    parser.add_argument("--dest", default=str(DEFAULT_DEST))
    parser.add_argument("--mirror", action="store_true", help="先试 hf-mirror.com")
    parser.add_argument("--force", action="store_true", help="已有也重下")
    args = parser.parse_args()

    manifest = load_manifest()
    only = {s.strip() for s in args.only.split(",") if s.strip()}
    picked = select(manifest["models"], args.tier, only)
    dest = Path(os.path.expanduser(args.dest))
    dest.mkdir(parents=True, exist_ok=True)

    print(f"清单：{MANIFEST.relative_to(ROOT)}")
    print(f"目标：{dest}")
    print(f"{'文件':52} {'大小':>10} {'档位':>9}  状态")

    failures: list[str] = []
    skipped = 0
    for model in picked:
        name = model["file"]
        target = dest / name
        state = ""
        if target.exists() and not args.force:
            size = target.stat().st_size
            if size == model["bytes"] and sha256_of(target).lower() == model["sha256"].lower():
                state = "已存在（校验通过）"
                skipped += 1
                print(f"{name:52} {human(model['bytes']):>10} {model['tier']:>9}  {state}")
                continue
            state = "已存在但校验失败，重下"
        print(f"{name:52} {human(model['bytes']):>10} {model['tier']:>9}  {state or '待下载'}")
        if args.list:
            continue

        hosts = list(HOSTS)
        if args.mirror:
            hosts.reverse()
        repo = model["source"]["repo"]
        inner = model["source"]["path"]
        ok = False
        for host in hosts:
            url = f"{host}/{repo}/resolve/main/{inner}?download=true"
            print(f"    来源 {host}")
            fd, tmp_name = tempfile.mkstemp(prefix=name, suffix=".part")
            os.close(fd)
            tmp = Path(tmp_name)
            try:
                download(url, tmp)
                size = tmp.stat().st_size
                if size != model["bytes"]:
                    print(f"    [size_mismatch] 期望 {model['bytes']}，实际 {size}")
                    continue
                digest = sha256_of(tmp)
                if digest.lower() != model["sha256"].lower():
                    print(f"    [sha256_mismatch] {digest[:16]}…")
                    continue
                shutil.move(str(tmp), target)
                print("    [ok] 校验通过")
                ok = True
                break
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
                print(f"    [fail] {exc}")
            finally:
                if tmp.exists():
                    tmp.unlink(missing_ok=True)
        if not ok:
            failures.append(name)

    print()
    print(f"summary picked={len(picked)} skipped={skipped} failed={len(failures)}")
    if failures:
        print("失败：" + ", ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
