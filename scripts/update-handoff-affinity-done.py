#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""HANDOFF.md 原子更新：改进项 #5 闭环 + 根因表述修正 + 新增踩坑 13/14。每处 assert 唯一命中。"""
import io

p = "docs/HANDOFF.md"
s = io.open(p, encoding="utf-8").read()
edits = [
    # 1. 零节：下一步三件事的第 1 件标记完成
    (
        """1. **Traefik podAntiAffinity 修复**（演练二改进项 #5）：traefik values 加反亲和 →
   本地 `helm template` 渲染 diff 验证 → 上云 → 确认两副本分落两节点。
   做完即形成「发现→修复→复验」完整闭环，改进项 #5 从待实施翻已实施""",
        """1. ✅ **Traefik podAntiAffinity 修复（2026-09-14 02:22-02:36 已完成）**：
   preferred→required + 控制面 toleration，双副本 **w2+cp** 分落两节点、探活 200。
   闭环叙事见 `docs/chaos-drill.md`「修复与复验」，证据 `docs/traefik-affinity-fix.log`。
   ⚠️ 过程备注：修复实际由**上一个会话在 02:22 用本会话备好的脚本抢先执行**（Revision 4），
   本会话 02:27 同配置重放（Revision 5，SFTP md5 对齐 cp 文件与仓库）；
   两个 Revision 的 values 经 `helm get values --all` diff 逐字节一致（见踩坑 #13/#14）""",
    ),
    # 2. 零节：演练二王牌发现的表述修正（无反亲和 → 软反亲和失效）
    (
        "| ★ 演练二王牌发现 | **Traefik 双副本同落 w2（Deployment 无反亲和）→ 入口层单点**",
        "| ★ 演练二王牌发现 | **Traefik 双副本同落 w2（preferred 软反亲和在 drain 场景失效，见 §5.4 #15）→ 入口层单点**",
    ),
    # 3. 遗留问题清单
    (
        """- [ ] **Traefik 双副本同节点（演练二发现，待修复）**：无反亲和 → w2 断电时入口层全灭
      （整站中断 6m18s，业务层却存活）。修法：traefik values 加 podAntiAffinity(required)
      → helm template 验证 → 上云；修完可做成「演练发现→修复→复验」的完整闭环叙事""",
        """- [x] **Traefik 双副本同节点（已修复并复验，2026-09-14 02:22-02:36）**：
      根因是 preferred（软）反亲和在 drain 场景失效——cp 污点不可入、替补只能落唯一可用
      节点、无自动回流（早期「无反亲和」表述不准确，values 自脚手架起就有软反亲和）。
      修复 = preferred→required + 控制面 toleration；复验双副本 w2+cp、探活 200。
      完整闭环：chaos-drill.md「修复与复验」+ `docs/traefik-affinity-fix.log`
      （rev4 原始日志被覆盖，已重建注释并补稳态复验）""",
    ),
    # 4. §六 任务 9 节：根因表述 + 唯一待办
    (
        "- **★ 最值钱的发现**：Traefik 双副本全在 w2（Deployment 无反亲和 + drain 替补不回流）",
        "- **★ 最值钱的发现**：Traefik 双副本全在 w2（软反亲和在 drain 场景失效 + 替补不回流）",
    ),
    (
        """- **唯一待办**：Traefik podAntiAffinity 修复（改进项 #5，values 改 + helm template 验证 +
  上云 + 复验副本分布）。""",
        """- **改进项 #5 已闭环（2026-09-14 02:22-02:36）**：preferred→required + 控制面 toleration，
  复验 w2+cp、探活 200，见 chaos-drill.md「修复与复验」与 `docs/traefik-affinity-fix.log`。""",
    ),
    # 5. §5.4 踩坑表追加 #13/#14/#15
    (
        """| 12 | **同一条消息里对同一个文件并发做多次编辑会丢掉改动**""",
        """| 13 | **同一个项目开两个 AI 会话并行操作 = 抢跑与互相覆盖**：上一会话没关，本会话备好修复物料（values + 脚本）后，它直接拿密码抢先执行（helm Revision 4），本会话随后又重放一遍（Revision 5） | 修好的配置恰好幂等 + helm Revision 历史可追溯，才没出事；`helm get values --revision 4/5` diff 确认两次逐字节一致 | 开新会话前关掉旧的；上云动作前先 `helm history` 看一眼有没有人动过 |
| 14 | **会留证据的脚本日志禁止用覆盖模式写**：修复脚本第二次运行把首次运行的原始日志（含「双副本同落 w1」修复前基线段）覆盖丢失 | 靠 chaos-drill.md 的逐字回填 + helm history / kubectl events / RS 创建时间重建了证据链，并在日志里追加了重建注释 | 日志一律追加（`open('a')`）或文件名带时间戳；确需覆盖前先改名备份 |
| 15 | **「Deployment 无反亲和」的目视结论未必准确**：演练复盘时凭截图断言 Traefik 无反亲和，实际 values 从脚手架起就有 preferred 软反亲和，真实根因是「cp 污点不可入 → drain 时唯一可调度节点 → 软反亲和让位 → 无回流」 | `kubectl get deploy -o jsonpath='{.spec.template.spec.affinity}'` 一步就能核实，别靠记忆下结论 | 复盘根因前先看线上 spec 原文，表述错会让面试追问穿帮 |
| 12 | **同一条消息里对同一个文件并发做多次编辑会丢掉改动**""",
    ),
]
for old, new in edits:
    assert s.count(old) == 1, f"命中 {s.count(old)} 次（应为 1）：{old[:40]!r}"
    s = s.replace(old, new)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print(f"OK：{len(edits)} 处编辑全部原子落盘")
