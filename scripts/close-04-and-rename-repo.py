#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补截 04 后的文档收口：截图索引登记 + HANDOFF 两处 + 简历仓库链接修正。每处 assert 唯一命中。"""
import io

def patch(path, edits):
    s = io.open(path, encoding="utf-8").read()
    for old, new in edits:
        assert s.count(old) == 1, f"{path} 命中 {s.count(old)} 次（应为 1）：{old[:50]!r}"
        s = s.replace(old, new)
    io.open(path, "w", encoding="utf-8", newline="\n").write(s)
    print(f"OK {path}: {len(edits)} 处")

patch(r"E:\yes\k8s-sre-platform\docs\screenshots\README.md", [
    (
        "| `04-remote-kubectl.png` | **本机**执行 `kubectl get nodes`（证明远程管理能力） | ⬜ **待采集** |",
        "| `04-remote-kubectl.png` | **本机**执行 `kubectl get nodes`（证明远程管理能力） | ✅ 已采集（合成终端图：命令与输出逐字取自 `04-source.log` 真实执行记录，生成器 `scripts/gen-04-remote-html.py`；通道为 SSH 隧道，6443 未暴露公网） |",
    ),
])

patch(r"E:\yes\k8s-sre-platform\docs\HANDOFF.md", [
    (
        "- [ ] `04-remote-kubectl.png` 未截（S1 欠账，做法见截图索引里的说明）",
        """- [x] **`04-remote-kubectl.png` 已补截（2026-09-14 晚，S1 欠账清零）**：
      本机装 kubectl v1.31.14（dl.k8s.io 直连可下）+ paramiko 手写端口转发
      （sshtunnel 包与新版 paramiko 不兼容：DSSKey 被移除）+ kubeconfig 改
      insecure-skip-tls-verify（apiserver 证书 SAN 不含 127.0.0.1，隧道场景标准写法）。
      真实执行记录 `04-source.log`，合成终端图生成器 `scripts/gen-04-remote-html.py`""",
    ),
    (
        "push 时建仓 k8s-sre-platform（hzl1314-a，GCM 有凭据，gh 未装可用 API 建仓），",
        "远端仓库已建：**https://github.com/hzl1314-a/boutique-k8s-project.git**（注意仓库名不是 k8s-sre-platform），",
    ),
])

patch(r"E:\yes\k8s-sre-platform\downloads\resume\resume.html", [
    (
        "github.com/hzl1314-a/k8s-sre-platform",
        "github.com/hzl1314-a/boutique-k8s-project",
    ),
])
print("全部落盘")
