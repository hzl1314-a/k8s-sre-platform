# -*- coding: utf-8 -*-
"""HANDOFF 任务 9 段更新 + 遗留清单追加 Traefik 单点改进项。"""
import io

P = r'E:/yes/k8s-sre-platform/docs/HANDOFF.md'
s = io.open(P, encoding='utf-8').read()

old = """### 任务 9：故障演练（项目王牌）

按 `docs/chaos-drill.md` 逐步走：开探测脚本 `scripts/availability-probe.sh` + 录屏 →
`kubectl drain k8s-w1` 优雅排水 → 控制台关机 w2 硬宕机 → `uncordon` 恢复 → 写复盘。
截图用 `chaos-01~04` 前缀。"""
assert s.count(old) == 1, 'task9 anchor'
new = """### 任务 9：故障演练（🟩 两场演练执行完毕，2026-09-14 01:15-01:50；chaos-04 恢复通知截图 + 收尾待完成）

- **演练一（优雅排水 w1）✅**：排水 11s，可用率 99.03%（309 请求/306×200），
  业务告警未触发（11s << for:1m）。意外素材：AM 驻留 w1，驱逐瞬间
  AlertmanagerClusterDown 自报 + 计数器随 Pod 迁移清零。截图 chaos-01（合成）。
- **演练二（w2 关机）✅**：NotReady T+36s → 双通道告警 T+84s（邮箱截图 chaos-02、
  钉钉 chaos-03）→ taint 驱逐 T+338s → 服务恢复 T+384s（中断 6m18s）→
  节点 Ready T+481s → RESOLVED 通知 T+502s。可用率 28.3%。
- **★ 最值钱的发现**：Traefik 双副本全在 w2（Deployment 无反亲和 + drain 替补不回流）
  → 入口层单点，业务 Pod 在 w1 存活但流量进不来。业务层/入口层/监控层/存储层
  每层要单独做「双副本跨节点」检查——已写进 chaos-drill.md 面试口径和改进项表。
- 证据：chaos-05 合成图（时间线+可用性条）、chaos-drill2-timeline.log、probe-drill2.log；
  chaos-drill.md 演练二章节已全部回填实测数据。
- **待办**：① chaos-04（RESOLVED 邮件截图，约 01:49 到达，用户收件箱）；② Traefik
  podAntiAffinity 修复（改进项 #5，values 改 + helm template 验证 + 上云）。"""
s = s.replace(old, new)

# 遗留清单追加 Traefik 项
anchor = '- [ ] `04-remote-kubectl.png` 未截（S1 欠账，做法见截图索引里的说明）'
assert s.count(anchor) == 1, 'leftover anchor'
s = s.replace(anchor, """- [ ] **Traefik 双副本同节点（演练二发现，待修复）**：无反亲和 → w2 断电时入口层全灭
      （整站中断 6m18s，业务层却存活）。修法：traefik values 加 podAntiAffinity(required)
      → helm template 验证 → 上云；修完可做成「演练发现→修复→复验」的完整闭环叙事
""" + anchor)

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('HANDOFF task9 updated OK')
