#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""README 收口（任务 10）：回填 §4.3/§5/§6/§7 实测数据 + 精确版本号 + 目录结构 + 成果速览。"""
import io

p = "README.md"
s = io.open(p, encoding="utf-8").read()
edits = [
    # 1. 状态徽章 + 核心成果速览
    (
        """![状态](https://img.shields.io/badge/status-building-yellow)

---""",
        """![状态](https://img.shields.io/badge/status-phase1--complete-green)

## 0. 核心成果速览（全部为实测值）

- **可观测**：Prometheus + Grafana + Loki 全栈，自建业务总览看板，8 条告警规则四组分治
- **告警触达**：故障 → 邮件/钉钉双通道 **74s**（验收线 120s），恢复通知 **222s**
- **弹性**：hey 50 并发 × 5m，**7426 请求全 200**（24.66 req/s，P99 2.78s）；HPA 扩容 **56s**
- **演练**：优雅排水可用率 **99.03%**；节点硬宕机暴露入口层单点 → required 反亲和修复复验闭环
- **踩坑沉淀**：40+ 条真实排查记录（现象 → 排查 → 根因 → 修复），是本仓库最值钱的部分

---""",
    ),
    # 2. §3 版本号精确化
    (
        "| Kubernetes | v1.31.x（kubeadm） |",
        "| Kubernetes | v1.31.14（kubeadm，apt 锁版本） |",
    ),
    (
        "| 容器运行时 | containerd（SystemdCgroup=true） |",
        "| 容器运行时 | containerd 2.2.1（SystemdCgroup=true） |",
    ),
    (
        "| CNI | Calico v3.28.x |",
        "| CNI | Calico v3.28.0（VXLAN 全封装——云上 VPC 不转发 BGP） |",
    ),
    # 3. §4.3 看板截图 TODO → 已有截图引用
    (
        """<!-- TODO(S3): 贴 Grafana 看板截图，docs/screenshots/ -->

| 面板 | 指标来源 |""",
        """自建 1 个业务总览看板（「Online Boutique 业务总览」，截图见
[docs/screenshots/](docs/screenshots/) 编号 10 / 11 / 19）：

| 面板 | 指标来源 |""",
    ),
    # 4. §5 告警：真实规则表 + 实测触达
    (
        """<!-- TODO(S4): 回填实测触达时间 -->

| 规则 | 阈值 | 持续时间 | 通道 |
|---|---|---|---|
| 节点内存水位 | > 85% | 5m | 邮件 |
| Pod 频繁重启 | > 3 次 / 15m | — | 钉钉 |
| 入口 5xx 错误率 | > 1% | 5m | 邮件 + 钉钉 |
| 服务副本不可用 | 可用副本 = 0 | 1m | 邮件 + 钉钉 |

**实测：故障发生 → 告警到达 `__` 秒；恢复 → 恢复通知 `__` 秒。**""",
        """自建 PrometheusRule 8 条，覆盖节点 / Pod / 入口 / 监控链路自检四组；路由按 severity 分发：
critical → 邮件 + 钉钉双通道（`continue: true` 实现一对多），warning → 邮件，元告警显式丢弃。

| 组 | 规则 | 阈值 / 条件 | for | 通道 |
|---|---|---|---|---|
| 节点 | NodeMemoryHigh | 内存水位 > 85% | 5m | 邮件 |
| 节点 | NodeNotReady | Ready 条件不为真 | 1m | 邮件 + 钉钉 |
| Pod | PodFrequentRestart | 15m 内重启 > 3 次 | 0m | 邮件 |
| 服务 | DeploymentReplicasUnavailable | 可用副本 = 0 | 1m | 邮件 + 钉钉 |
| 入口 | IngressHighErrorRate | 5xx 占比 > 1%（5m 速率窗口） | 5m | 邮件 + 钉钉 |
| 入口 | IngressLatencyHigh | P95 延迟 > 2s | 5m | 邮件 |
| 自检 | ScrapeTargetDown | 抓取目标 up == 0 | 5m | 邮件 |
| 自检 | AlertmanagerNotificationFailures | 通知发送失败率 > 0 | 10m | 邮件 + 钉钉 |

**实测触达**（`DeploymentReplicasUnavailable` 注入演练，时间线见 [docs/alerting.md](docs/alerting.md) §4）：
故障注入 → Firing **T+70s** → 邮件/钉钉双通道投递 **T+74s**（验收线 120s）→ 恢复通知 **T+222s**。
真实节点宕机场景（演练二）：双通道告警 **T+84s**，RESOLVED 通知 **T+502s**。""",
    ),
    # 5. §6 弹性伸缩：压测实测
    (
        """<!-- TODO(S5): 回填压测数据 -->

| 指标 | 实测值 |
|---|---|
| 压测工具 / 并发 | hey · `__` 并发 · `__` 分钟 |
| 峰值 QPS | `__` |
| 扩容触发条件 | CPU > 60% |
| 副本变化 | 2 → `__` |
| 扩容耗时 | `__` 秒 |
| 缩容策略 | 5 分钟稳定窗口后逐步缩回 |""",
        """| 指标 | 实测值 |
|---|---|
| 压测负载 | hey（cp 节点本机打 127.0.0.1:30080）· 50 并发 · 5 分钟 |
| 结果 | 7426 请求**全部 200** · 24.66 req/s · P99 2.78s |
| 扩容触发条件 | HPA CPU 目标 60%（实测利用率冲到 80% 越阈值） |
| 副本变化 | 2 → 3，**扩容耗时 56s**；3 副本求衡在 ~57% |
| 缩容 | 负载结束后 5 分钟稳定窗口到期，3 → 2 |
| 交叉验证 | Prometheus query_range 副本数序列与 3s 轮询日志一致 |

压测由 [`scripts/hpa-drill.py`](scripts/hpa-drill.py) 全自动执行（等基线回落 → 压测 → 3s 轮询
HPA → 缩容观察 → 报告落盘），完整时间线见 [docs/autoscaling.md](docs/autoscaling.md)。""",
    ),
    # 6. §7 故障演练：实测时间线 + 闭环修复
    (
        """<!-- TODO(S6): 回填时间线 -->

| 演练 | 手段 | 服务可用性 | 恢复耗时 |
|---|---|---|---|
| 优雅排水 | `kubectl drain k8s-w1` | `__` | `__` |
| 节点硬宕机 | 控制台强制关机 k8s-w2 | `__` | `__` |""",
        """| 演练 | 手段 | 可用率 | 关键时间线 |
|---|---|---|---|
| 优雅排水 | `kubectl drain k8s-w1` | **99.03%**（309 请求仅 3 失败，2s 自愈） | 排水 11s；业务告警未触发（11s < for:1m） |
| 节点硬宕机 | 控制台强制关机 k8s-w2 | **28.3%** | NotReady T+36s → 双通道告警 T+84s → taint 驱逐 T+338s → 服务恢复 T+384s（**中断 6m18s**）→ RESOLVED 通知 T+502s |

**演练二的王牌发现与闭环修复**：硬宕机暴露**入口层单点**——Traefik 双副本同落 w2
（preferred 软反亲和在「控制面污点不可入 + drain 替补不回流」场景下失效），
业务 Pod 在 w1 存活但流量进不来。修复：反亲和 preferred→required + 控制面 toleration，
复验双副本分落 w2+cp、入口 200。「发现 → 修复 → 复验」全过程见 [docs/chaos-drill.md](docs/chaos-drill.md)。""",
    ),
    # 7. 目录结构
    (
        """k8s-sre-platform/
├── docs/
│   ├── setup-cluster.md         # 集群搭建手册与踩坑记录
│   ├── chaos-drill.md           # 故障演练复盘
│   └── screenshots/             # 留证截图索引
├── manifests/
│   ├── boutique/                # Online Boutique 部署清单（镜像已替换）
│   ├── ingress/                 # Traefik values + IngressRoute
│   ├── hpa/                     # HPA 配置
│   └── alerts/                  # 告警规则 + Alertmanager 配置
├── monitoring/
│   ├── kube-prometheus-stack-values.yaml
│   ├── loki-values.yaml
│   └── promtail-values.yaml
└── scripts/
    ├── mirror-push.sh           # 镜像中转（本地 → ACR）
    └── availability-probe.sh    # 演练期间可用性探测""",
        """k8s-sre-platform/
├── docs/
│   ├── setup-cluster.md         # 集群搭建手册（8 条踩坑记录）
│   ├── alerting.md              # 告警手册：步骤 / 时间预算 / 排障 / 实测时间线
│   ├── autoscaling.md           # HPA + 压测手册：8 步流程 / 实测时间线 / 踩坑表
│   ├── chaos-drill.md           # 演练复盘（含入口层单点的发现→修复→复验闭环）
│   ├── HANDOFF.md               # 交接文档（进度 / 环境 / 踩坑总表 / 协作约定）
│   └── screenshots/             # 留证截图索引（01-19 + chaos-01~05）
├── manifests/
│   ├── boutique/                # Online Boutique 清单（镜像换源，副本 ≥2 + 反亲和）
│   ├── ingress/                 # Traefik values（required 反亲和 + 控制面 toleration）
│   ├── hpa/                     # frontend HPA（min 2 / max 8 / CPU 60%）
│   └── alerts/                  # 8 条告警规则 + Alertmanager 路由 + 钉钉转发组件
├── monitoring/                  # kube-prometheus-stack / loki / promtail 三个 helm values
└── scripts/                     # 幂等脚本：系统初始化 / 镜像与 CRD 校验 / 压测演练观测器 / Grafana 截图自动化""",
    ),
    # 8. 说明
    (
        "- 本仓库所有配置均经实测验证，README 中带 `__` 的数据待对应阶段完成后回填实测值，不提前填写估算值。",
        "- 本仓库所有配置均经实测验证；文中数字全部为实测值，证据链（日志 / 截图 / 时间线）见对应手册。",
    ),
]
for old, new in edits:
    assert s.count(old) == 1, f"命中 {s.count(old)} 次（应为 1）：{old[:40]!r}"
    s = s.replace(old, new)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
print(f"OK：{len(edits)} 处编辑全部原子落盘")
