# 阿里云 K8s 高可用运维平台

> 在阿里云 3 台 ECS 上，用 kubeadm 从零搭建的生产级 Kubernetes 集群，承载 Google Online Boutique
> 微服务负载，配套完整的可观测性、告警、弹性伸缩与故障演练体系。
>
> **本仓库定位：** 运维工程实践记录，不含业务代码。业务负载使用开源 Online Boutique。

![状态](https://img.shields.io/badge/status-phase1--complete-green)

## 0. 核心成果速览（全部为实测值）

- **可观测**：Prometheus + Grafana + Loki 全栈，自建业务总览看板，8 条告警规则四组分治
- **告警触达**：故障 → 邮件/钉钉双通道 **74s**（验收线 120s），恢复通知 **222s**
- **弹性**：hey 50 并发 × 5m，**7426 请求全 200**（24.66 req/s，P99 2.78s）；HPA 扩容 **56s**
- **演练**：优雅排水可用率 **99.03%**；节点硬宕机暴露入口层单点 → required 反亲和修复复验闭环
- **踩坑沉淀**：40+ 条真实排查记录（现象 → 排查 → 根因 → 修复），是本仓库最值钱的部分

---

## 1. 项目概述

| 维度 | 内容 |
|---|---|
| 目标 | 验证 K8s 集群在真实云环境下的部署、可观测、弹性与自愈能力 |
| 集群形态 | 1 控制面 + 2 worker，kubeadm 原生部署（非托管 K8s） |
| 网络方案 | Calico（BGP/VXLAN），Pod CIDR `192.168.0.0/16` |
| 入口 | Traefik Ingress（NodePort 30080 / 30443） |
| 业务负载 | Online Boutique，11 个多语言微服务（Go / Java / Python / Node.js / C#） |
| 可观测 | kube-prometheus-stack（Prometheus + Grafana + Alertmanager）+ Loki/Promtail |
| 弹性 | metrics-server + HPA（CPU 驱动） |
| 告警通道 | 邮件 + 钉钉机器人双通道 |

**为什么不用 ACK 托管集群：** 托管 K8s 隐藏了控制面组件细节。用 kubeadm 从零搭建，
才能把 apiserver / etcd / scheduler / controller-manager / kubelet / CNI 的协作关系讲清楚——
这是面试中区分"用过 K8s"和"懂 K8s"的分水岭。

---

## 2. 架构

```
                公网用户 / 压测机 (hey)
                        │
                        ▼
        ┌───────────────────────────────────┐
        │  阿里云 VPC · 安全组                │
        │  放行: 22 / 6443 (仅管理机)          │
        │        30080 / 30443 (公网)         │
        └───────────────┬───────────────────┘
                        ▼
┌───────────────────────────────────────────────────────┐
│  kubeadm Kubernetes v1.31                             │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │  k8s-cp      │  │  k8s-w1      │  │  k8s-w2     │  │
│  │  control-    │  │  worker      │  │  worker     │  │
│  │  plane       │  │              │  │             │  │
│  │  2C4G        │  │  4C8G        │  │  4C8G       │  │
│  └──────────────┘  └──────────────┘  └─────────────┘  │
│                                                       │
│  Traefik Ingress (2 副本, NodePort 30080)              │
│  Online Boutique ×11  (副本 ≥2 + Pod 反亲和)            │
│  kube-prometheus-stack + Loki + Promtail              │
│  Alertmanager ──► 邮件 / 钉钉                          │
└───────────────────────────────────────────────────────┘
```

<!-- TODO(S7): 替换为实际架构图截图，放入 docs/screenshots/ -->

---

## 3. 集群信息

| 项 | 值 |
|---|---|
| 云厂商 / 地域 | 阿里云 · `待填` |
| 节点规格 | cp: 2C4G / w1: 4C8G / w2: 4C8G |
| 操作系统 | Ubuntu 22.04 LTS |
| Kubernetes | v1.31.14（kubeadm，apt 锁版本） |
| 容器运行时 | containerd 2.2.1（SystemdCgroup=true） |
| CNI | Calico v3.28.0（VXLAN 全封装——云上 VPC 不转发 BGP） |
| Pod CIDR / Service CIDR | 192.168.0.0/16 / 10.96.0.0/12 |

搭建过程与踩坑记录见 [`docs/setup-cluster.md`](docs/setup-cluster.md)。

---

## 4. 可观测性

### 4.1 指标

kube-prometheus-stack 提供四层指标采集：

| 采集器 | 覆盖范围 |
|---|---|
| node-exporter | 节点 CPU / 内存 / 磁盘 / 网络 |
| kube-state-metrics | K8s 对象状态（副本数、重启次数、调度情况） |
| cAdvisor（kubelet 内置） | 容器级资源用量 |
| ServiceMonitor（Traefik） | 入口层 QPS / 状态码 / 延迟 |

### 4.2 日志

Loki + Promtail：Promtail 以 DaemonSet 采集各节点容器日志，仅索引标签（namespace / pod / container），
日志正文压缩存储。相比 ELK 资源占用低一个量级。

### 4.3 自建看板

自建 1 个业务总览看板（「Online Boutique 业务总览」，截图见
[docs/screenshots/](docs/screenshots/) 编号 10 / 11 / 19）：

| 面板 | 指标来源 |
|---|---|
| 入口 QPS / P95 延迟 | Traefik |
| 各服务错误率 | Traefik 状态码 |
| Pod 重启次数 | kube-state-metrics |
| 节点资源水位 | node-exporter |

---

## 5. 告警

自建 PrometheusRule 8 条，覆盖节点 / Pod / 入口 / 监控链路自检四组；路由按 severity 分发：
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
真实节点宕机场景（演练二）：双通道告警 **T+84s**，RESOLVED 通知 **T+502s**。

---

## 6. 弹性伸缩与压测

| 指标 | 实测值 |
|---|---|
| 压测负载 | hey（cp 节点本机打 127.0.0.1:30080）· 50 并发 · 5 分钟 |
| 结果 | 7426 请求**全部 200** · 24.66 req/s · P99 2.78s |
| 扩容触发条件 | HPA CPU 目标 60%（实测利用率冲到 80% 越阈值） |
| 副本变化 | 2 → 3，**扩容耗时 56s**；3 副本求衡在 ~57% |
| 缩容 | 负载结束后 5 分钟稳定窗口到期，3 → 2 |
| 交叉验证 | Prometheus query_range 副本数序列与 3s 轮询日志一致 |

压测由 [`scripts/hpa-drill.py`](scripts/hpa-drill.py) 全自动执行（等基线回落 → 压测 → 3s 轮询
HPA → 缩容观察 → 报告落盘），完整时间线见 [docs/autoscaling.md](docs/autoscaling.md)。

---

## 7. 故障演练

| 演练 | 手段 | 可用率 | 关键时间线 |
|---|---|---|---|
| 优雅排水 | `kubectl drain k8s-w1` | **99.03%**（309 请求仅 3 失败，2s 自愈） | 排水 11s；业务告警未触发（11s < for:1m） |
| 节点硬宕机 | 控制台强制关机 k8s-w2 | **28.3%** | NotReady T+36s → 双通道告警 T+84s → taint 驱逐 T+338s → 服务恢复 T+384s（**中断 6m18s**）→ RESOLVED 通知 T+502s |

**演练二的王牌发现与闭环修复**：硬宕机暴露**入口层单点**——Traefik 双副本同落 w2
（preferred 软反亲和在「控制面污点不可入 + drain 替补不回流」场景下失效），
业务 Pod 在 w1 存活但流量进不来。修复：反亲和 preferred→required + 控制面 toleration，
复验双副本分落 w2+cp、入口 200。「发现 → 修复 → 复验」全过程见 [docs/chaos-drill.md](docs/chaos-drill.md)。

完整时间线与复盘见 [`docs/chaos-drill.md`](docs/chaos-drill.md)。

---

## 8. 二期路线

- [ ] 域名 + HTTPS + ICP 备案
- [ ] GitHub Actions CI/CD（镜像构建 → ACR → 自动滚动更新）
- [ ] Velero 集群备份与恢复演练
- [ ] Chaos Mesh 故障注入（网络延迟 / 丢包）
- [ ] 控制面高可用（追加第 4 台 ECS 作第二控制面）

---

## 目录结构

```
k8s-sre-platform/
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
└── scripts/                     # 幂等脚本：系统初始化 / 镜像与 CRD 校验 / 压测演练观测器 / Grafana 截图自动化
```

---

## 说明

- 本仓库所有配置均经实测验证；文中数字全部为实测值，证据链（日志 / 截图 / 时间线）见对应手册。
- 业务负载 Online Boutique 版权归 Google，仅作运维演示用途。
