# -*- coding: utf-8 -*-
"""HANDOFF.md 交接摘要更新：任务 8/9 收官，零节重写为 2026-09-14 版。"""
import io

P = r'E:/yes/k8s-sre-platform/docs/HANDOFF.md'
s = io.open(P, encoding='utf-8').read()

# ---------- 1) 顶部交接时间 ----------
old = '> **交接时间**：2026-09-13'
assert s.count(old) == 1, 'hdr'
s = s.replace(old, '> **交接时间**：2026-09-14（最新一轮：任务 8、9 已执行完毕并留证）')

# ---------- 2) 重写零节（从 '## 零、' 到 '## 一、' 之间整段替换） ----------
i = s.index('## 零、')
j = s.index('## 一、这个项目是什么')

new_zero = """## 零、上一轮会话交接摘要（2026-09-14 凌晨 · 先读这一节）

**一句话**：任务 8（HPA + 压测）与任务 9（两场故障演练）已全部执行完毕、证据链齐全，
下一步是**收尾三件事**：① Traefik 反亲和修复 → ② 任务 10（README + 简历）→ ③ push GitHub。
本节是上一轮会话的浓缩，细节都在对应文档里，不需要翻历史聊天记录。

### 这轮做成了什么

| 事项 | 结果 |
|---|---|
| 任务 8：HPA + 压测 | hey 5m/c50 全自动压测：7426 请求全 200、24.66 req/s、P99 2.78s；扩容 2→3 @T+56s（CPU 80% 越阈值）、缩容 @负载结束+300s；副本数经 Prometheus 序列交叉验证。手册 `docs/autoscaling.md` 已回填实测时间线，截图 17/18/19 齐 |
| kube-proxy 遗留闭环 | `kubeProxy.enabled: false` 已上云，ScrapeTargetDown 清零（三步验证全过，遗留清单 [x]） |
| OOMKilled 实锤修复 | payment(Node) 静息 78% 贴 limit、currency(Go) 流量毛刺打穿 128Mi → 提到 request 128Mi / limit 256Mi，滚动更新后零重启。「监控第一次跑就抓到真问题」达成（遗留清单 [x]） |
| 任务 9：两场故障演练 | 演练一（优雅排水 w1）：排水 11s、可用率 99.03%、业务告警未触发；演练二（w2 关机）：NotReady T+36s → 双通道告警 T+84s → 服务恢复 T+384s（中断 6m18s）→ RESOLVED 通知 T+502s。截图 chaos-01~05 六张全齐，`docs/chaos-drill.md` 已全部回填实测数据与面试口径 |
| ★ 演练二王牌发现 | **Traefik 双副本同落 w2（Deployment 无反亲和）→ 入口层单点**：业务 Pod 在 w1 存活但流量进不来，整站中断 6m18s。「K8s 的 HA 是逐层的」面试口径已写进 chaos-drill.md |
| 截图与通道 | HPA 17-19 + chaos-01~05 全部归档登记；Grafana 截图已自动化（`scripts/grafana-shot.mjs`），合成图有生成器先例 |

### 这轮新增的工具与文件

| 文件 | 用途 |
|---|---|
| `docs/autoscaling.md` | 任务 8 手册（8 步流程 / 实测时间线 / 踩坑表 / 面试要点） |
| `scripts/hpa-drill.py` | 全自动压测：等回落基线 → hey → 3s 轮询 HPA → 缩容观察 → 报告落盘 |
| `scripts/chaos-drill1.py` / `chaos-drill2.py` | 两场演练观测器（探针 + 节点/Pod/AM 计数轮询 + 时间线落盘；drill2 分 watch/resume 两阶段） |
| `scripts/grafana-shot.mjs` | puppeteer + 本机 Chrome 无头登录 Grafana 截图（页面不认 basic auth，只能表单登录） |
| `scripts/gen-hpa-shot-html.py` / `gen-chaos01-html.py` / `gen-chaos05-html.py` | 合成截图生成器（先例：截图 13；数据逐字取自日志） |
| `docs/hpa-drill-timeline.log` / `docs/probe-drill*.log` / `docs/chaos-drill*-timeline.log` | 原始证据数据 |

### 这轮踩的新坑（完整版在 autoscaling.md §6 / chaos-drill.md）

1. **HPA TARGETS 按列 split 会错位**：`cpu: 11%/60%` 带空格，MAXPODS 被当副本数
   （第一次压测 run1 报废的根因）→ 一律 jsonpath / json，别解析人类可读输出
2. **apply 忘带 `-n` = 误建全套到 default ns**：识别信号是输出全 `created`（正常滚动应为
   configured/unchanged）、Deployment AGE 不变、scp 实际失败（md5 不符）——见信号就停手查现场
3. **Grafana 页面不认 URL basic auth**（API 认、页面 302 登录）；headless Chrome 带
   `--disable-gpu` 时 uPlot canvas 不渲染（图例有、曲线无）
4. **演练前必须盘点全节点 Pod 分布**：drain 替补不回流 + 无自动 rebalance，
   曾出现 22 个业务 Pod 全堆 w2 的险情（直接关机 = 全灭剧本）

### ⚠️ 下一步（按顺序三件事）

1. **Traefik podAntiAffinity 修复**（演练二改进项 #5）：traefik values 加反亲和 →
   本地 `helm template` 渲染 diff 验证 → 上云 → 确认两副本分落两节点。
   做完即形成「发现→修复→复验」完整闭环，改进项 #5 从待实施翻已实施
2. **任务 10：README 收口 + 简历**：把实测数字写进根 README 与简历 bullet——
   压测 24.66 req/s / P99 2.78s、演练可用率 99.03% 与 28.3%、告警触达 84s、
   恢复通知 502s、排水 11s 等（素材全在两份手册里）
3. **杂项**：仓库 push GitHub、`04-remote-kubectl.png` 补截（S1 欠账）

### 本机环境变化（比本文档旧版描述重要）

- 本地代理 `127.0.0.1:7897` **已失效**；**直连正常**（用环境自带代理变量，别加 `-x`）
- **GitHub release 资产下载不通**（302 后超时）；二进制走非 GitHub 官方源（helm → `get.helm.sh`）
- SSH 到 ECS **需密码**（无免密钥）；AI 用 paramiko 直连执行命令；
  **传文件用 paramiko SFTP**（scp 在本机通道不稳定，曾静默失败）
- **Grafana 凭据从集群 secret 取**（`kubectl -n monitoring get secret grafana-admin ...`），
  用户口述凭据有笔误风险，以 secret 为准
- Prometheus 直连走 **ClusterIP**（节点可路由；cp 的 `localhost:9090` 只在用户手动
  port-forward 时才通，不要当成常驻通道）
- **Bash 工具 heredoc 会吃反斜杠**（`\\n`→`/n`、`\\s`→`/s`，静默不报错）：
  含转义/正则的代码一律先用 Write 写成文件再执行

### 给下一任的开场提示（新会话直接把这段粘贴给 AI 即可）

> 我在接着做 k8s-sre-platform 求职作品集项目（仓库在 `E:/yes/k8s-sre-platform`）。
> 请先通读 `docs/HANDOFF.md`——尤其「零、上一轮会话交接摘要」和第五节踩坑表。
> 任务 8（HPA 压测）和任务 9（两场故障演练）已执行完毕、证据链齐全
> （手册：`docs/autoscaling.md`、`docs/chaos-drill.md`）。接下来按顺序做三件事：
> ① Traefik podAntiAffinity 修复（演练二发现入口层单点，见 HANDOFF 零节和遗留问题清单）；
> ② 任务 10：README 收口 + 简历回填实测数字；③ 仓库 push GitHub。
> 动手前先提醒我：按项目约定，helm values 必须先本地 `helm template` 验证、
> 自定义资源必须先过 `scripts/validate-crd-fields.py`；SSH/凭据见 HANDOFF 第三节。

---

"""

s = s[:i] + new_zero + s[j:]

# ---------- 3) 进度表 ----------
old = '## 二、当前进度（截至 2026-09-13）'
assert s.count(old) == 1, 'sec2'
s = s.replace(old, '## 二、当前进度（截至 2026-09-14 凌晨）')

old = '| 8 | metrics-server + HPA 自动扩缩容 + hey 压测 | ⬜ |'
assert s.count(old) == 1, 't8'
s = s.replace(old, '| **8** | **metrics-server + HPA 自动扩缩容 + hey 压测** | 🟩 **完成**：压测 7426 请求全 200 / 24.66 req/s，扩容 T+56s；截图 17-19，见 `docs/autoscaling.md` |')
old = '| 9 | 故障演练（drain 优雅排水 / 硬宕机） | ⬜ |'
assert s.count(old) == 1, 't9'
s = s.replace(old, '| **9** | **故障演练（drain 优雅排水 / 节点关机）** | 🟩 **完成**：可用率 99.03% / 28.3%，告警全生命周期闭环 T+84s→T+502s；截图 chaos-01~05，见 `docs/chaos-drill.md` |')

# ---------- 4) 任务 9 段落收尾 ----------
old = '### 任务 9：故障演练（🟩 两场演练执行完毕，2026-09-14 01:15-01:50；chaos-04 恢复通知截图 + 收尾待完成）'
assert s.count(old) == 1, 't9hdr'
s = s.replace(old, '### 任务 9：故障演练（✅ 完整收官，2026-09-14 01:15-01:56；chaos-01~05 六张截图全齐）')

old = """- **待办**：① chaos-04（RESOLVED 邮件截图，约 01:49 到达，用户收件箱）；② Traefik
  podAntiAffinity 修复（改进项 #5，values 改 + helm template 验证 + 上云）。"""
assert s.count(old) == 1, 't9todo'
s = s.replace(old, """- 恢复证据：`chaos-04-recovery.png`（邮件 RESOLVED 01:49）+
  `chaos-04-recovery-dingtalk.png`（钉钉 01:49）已归档登记——**告警触发→通知→恢复全生命周期闭环**。
- **唯一待办**：Traefik podAntiAffinity 修复（改进项 #5，values 改 + helm template 验证 +
  上云 + 复验副本分布）。""")

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('HANDOFF.md updated: 5 patches OK, total lines =', len(s.splitlines()))
