# 阿里云 K8s 高可用运维平台

> 在阿里云 3 台 ECS 上，用 kubeadm 从零搭建的生产级 Kubernetes 集群，承载 Google Online Boutique
> 微服务负载，配套完整的可观测性、告警、弹性伸缩与故障演练体系。
>
> **本仓库定位：** 运维工程实践记录，不含业务代码。业务负载使用开源 Online Boutique。

![状态](https://img.shields.io/badge/status-building-yellow)

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
| Kubernetes | v1.31.x（kubeadm） |
| 容器运行时 | containerd（SystemdCgroup=true） |
| CNI | Calico v3.28.x |
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

<!-- TODO(S3): 贴 Grafana 看板截图，docs/screenshots/ -->

| 面板 | 指标来源 |
|---|---|
| 入口 QPS / P95 延迟 | Traefik |
| 各服务错误率 | Traefik 状态码 |
| Pod 重启次数 | kube-state-metrics |
| 节点资源水位 | node-exporter |

---

## 5. 告警

<!-- TODO(S4): 回填实测触达时间 -->

| 规则 | 阈值 | 持续时间 | 通道 |
|---|---|---|---|
| 节点内存水位 | > 85% | 5m | 邮件 |
| Pod 频繁重启 | > 3 次 / 15m | — | 钉钉 |
| 入口 5xx 错误率 | > 1% | 5m | 邮件 + 钉钉 |
| 服务副本不可用 | 可用副本 = 0 | 1m | 邮件 + 钉钉 |

**实测：故障发生 → 告警到达 `__` 秒；恢复 → 恢复通知 `__` 秒。**

---

## 6. 弹性伸缩与压测

<!-- TODO(S5): 回填压测数据 -->

| 指标 | 实测值 |
|---|---|
| 压测工具 / 并发 | hey · `__` 并发 · `__` 分钟 |
| 峰值 QPS | `__` |
| 扩容触发条件 | CPU > 60% |
| 副本变化 | 2 → `__` |
| 扩容耗时 | `__` 秒 |
| 缩容策略 | 5 分钟稳定窗口后逐步缩回 |

---

## 7. 故障演练

<!-- TODO(S6): 回填时间线 -->

| 演练 | 手段 | 服务可用性 | 恢复耗时 |
|---|---|---|---|
| 优雅排水 | `kubectl drain k8s-w1` | `__` | `__` |
| 节点硬宕机 | 控制台强制关机 k8s-w2 | `__` | `__` |

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
    └── availability-probe.sh    # 演练期间可用性探测
```

---

## 说明

- 本仓库所有配置均经实测验证，README 中带 `__` 的数据待对应阶段完成后回填实测值，不提前填写估算值。
- 业务负载 Online Boutique 版权归 Google，仅作运维演示用途。
