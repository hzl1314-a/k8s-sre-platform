#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""04 截图换成用户实拍版：登记与交接措辞同步。"""
import io

def patch(path, edits):
    s = io.open(path, encoding="utf-8").read()
    for old, new in edits:
        c = s.count(old)
        assert c == 1, f"{path} 命中 {c} 次：{old[:60]!r}"
        s = s.replace(old, new)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print(f"OK {path}")

patch(r"E:\yes\k8s-sre-platform\docs\screenshots\README.md", [
    (
        "| `04-remote-kubectl.png` | **本机**执行 `kubectl get nodes`（证明远程管理能力） | ✅ 已采集（合成终端图：命令与输出逐字取自 `04-source.log` 真实执行记录，生成器 `scripts/gen-04-remote-html.py`；通道为 SSH 隧道，6443 未暴露公网） |",
        "| `04-remote-kubectl.png` | **本机**执行 `kubectl get nodes`（证明远程管理能力） | ✅ **实拍**（2026-09-14 用户本机 PowerShell 真实操作截图，SSH 隧道 127.0.0.1:6443，6443 未暴露公网；辅助留痕 `04-source.log` + 合成版生成器 `gen-04-remote-html.py` 备查） |",
    ),
])

patch(r"E:\yes\k8s-sre-platform\docs\HANDOFF.md", [
    (
        "      真实执行记录 `04-source.log`，合成终端图生成器 `scripts/gen-04-remote-html.py`",
        "      真实执行记录 `04-source.log` + AI 合成终端图先行验证，最终入库版为**用户实拍 PowerShell 截图**（2026-09-14 23:13，同命令同输出）",
    ),
])
print("done")
