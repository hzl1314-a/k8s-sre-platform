# 故障演练复盘

> 对应实施计划任务 9 / 规格文档 S6 阶段。
> **本文件是项目的王牌材料**：它证明的不是"我能把集群装起来"，而是"我能证明它真的不会挂"。
>
> 撰写原则：**只写实测数据，不写推测数据**。时间线要精确到秒，来自当时的录屏和 `probe.log`。

---

## 演练设计

| 项 | 内容 |
|---|---|
| 目标 | 验证单节点故障时，业务 Pod 自动漂移，服务对用户**不中断**（或中断在秒级） |
| 手段一 | 优雅排水 `kubectl drain`（模拟计划内维护：打补丁、换盘、升级） |
| 手段二 | 控制台强制关机（模拟真实宕机：硬件故障、内核 panic、断电） |
| 观测点 | ① `probe.log` 的 HTTP 状态码连续性 ② 告警触达时间 ③ Pod 重新调度耗时 |
| 前提 | 所有业务 Deployment 副本 ≥2 且配置了 Pod 反亲和（否则副本可能在同一节点，一锅端） |

### 为什么设计两个场景

`drain` 是**优雅**的：会先驱逐 Pod，Pod 有机会走完 `terminationGracePeriodSeconds`，
配合 `preStop` 钩子和就绪探针摘流量，理论上可以做到零中断。

**硬关机是野蛮的**：节点瞬间失联，没有优雅退出，kubelet 不再上报心跳。
此时 K8s 需要靠 `node-monitor-grace-period`（默认 40s）+ `pod-eviction-timeout`
（v1.13+ 由 taint-based eviction 接管，默认 300s）才能判定节点死亡并重建 Pod。

> 这两个场景的差异本身就是极好的面试话题：
> **"优雅排水能零中断，硬关机必然有分钟级中断窗口——因为 K8s 无法区分'节点死了'和'节点只是网络抖了一下'，
> 它必须等待一段时间才敢重建 Pod，否则会造成脑裂（两个同名 Pod 同时写同一个 volume）。"**

---

## 演练前准备

```bash
# 1) 确认反亲和生效：两个副本必须落在不同节点
kubectl get pods -n boutique -o wide | grep frontend

# 2) 确认副本数
kubectl get deploy -n boutique

# 3) 启动探测脚本
#    ★ 强烈建议在 k8s-cp 上执行，不要在本机 Windows 上执行
#
#    原因：Windows Git Bash 下每次 curl 启动开销约 2~3 秒（实测 4 次请求耗时 13 秒），
#    根本达不到「每秒一次」的粒度，探测数据会出现大段盲区，直接影响留证质量。
#    Linux 上开销可忽略，能稳定做到 1 秒一次。
#
#    在 cp 上执行：
#      scp scripts/availability-probe.sh root@<k8s-cp公网IP>:~/
#      ssh root@<k8s-cp公网IP>
#      bash availability-probe.sh http://127.0.0.1:30080/ -o probe.log
#
#    为什么探测 127.0.0.1 也有效：NodePort 会在**每个节点**监听 30080，
#    cp 上访问本机 30080 走的是和外部完全相同的 kube-proxy 转发链路，
#    能真实反映 Service → Pod 的可用性（只是少了公网这一段）。
#
#    想记录「公网视角」的话，本机浏览器开着商店页面录屏即可，作为辅助证据。
bash scripts/availability-probe.sh http://127.0.0.1:30080/ -o probe.log
#   ↑ 每秒一次请求，输出「时间戳 / 状态码 / 耗时」

# 4) 开录屏（OBS / Windows 自带录屏），全屏覆盖终端 + Grafana 面板
#    录屏分辨率建议 1920x1080，演练全程不剪辑
```

---

## 演练一：优雅排水

**执行时间：** 2026-09-14 01:15:01 - 01:15:13（排水全程 11s），探针观察窗 600s

```bash
# 录屏开始 --------------------------------
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data
# 观察 Pod 漂移
kubectl get pods -n boutique -o wide -w
# 观察完成后恢复
kubectl uncordon k8s-w1
# 录屏结束 --------------------------------
```

### 时间线（实测回填）

| 时刻 | 事件 | 距演练开始 |
|---|---|---|
| T+0s | 执行 drain（01:15:01） | — |
| T+2s | 8 个 w1 Pod 进入 Terminating（SIGTERM 已发，节点转 SchedulingDisabled） | 2s |
| T+4s | 首批替补 Pod 在 w2/cp 进入 ContainerCreating | 4s |
| T+6s | frontend 替补 Running（frontend-58c745c7-nkzch），4s 完成镜像→启动→就绪 | 6s |
| T+9s | 10 个被驱逐服务中 8 个已有 Running 替补 | 9s |
| T+11s | w1 清空（10 pod evicted），drain 返回 | 11s |
| T+12s | `uncordon` 恢复节点 | 12s |
| T+24s~ | 节点 Ready 可调度；**无 Pod 迁回 w1**（K8s 无自动 rebalance，预期行为，见改进项 #3） | — |

> 镜像已预热的价值：替补 Pod 从 ContainerCreating 到 Running 最快 2s（镜像本就在节点上），
> 没有「拉镜像几分钟」的等待，这是改进项 #4 已隐性达成的原因。

### 服务可用性

| 指标 | 数值（实测 600s 窗口） |
|---|---|
| 探测总请求数 | 309 |
| 200 响应数 | 306 |
| 非 200 响应数 | 3（000 × 2、500 × 1，全部集中在 01:15:15-01:15:17 驱逐窗口） |
| **可用率** | **99.03%** |
| 最长连续失败 | 2 次（2 秒） |
| 最高延迟 | 3.11s（01:15:27，驱逐后 endpoints 收敛期），其余全部 <1.25s |

> 结论：309 次请求只有 3 次失败，且 2 秒后自愈——「副本 ≥2 + 反亲和 + NodePort 全节点暴露 +
> 就绪探针摘流量」的组合把排水影响压到了秒级。kube-proxy endpoints 收敛的几秒延迟是
> 那 3 次失败的来源（旧 Pod 已死、新 Pod 已就绪，但 Service 端点表还没刷新完）。

> 若可用率 100%：说明端口暴露在**多个节点**上（NodePort 特性）+ 就绪探针正确摘流量，
> 请求始终被转发到其他节点的健康 Pod。这正是"副本 ≥2 + 反亲和"的价值所在。
> 若出现少量 5xx：分析是 drain 瞬间的连接重置（客户端未重试），还是有 Pod 未及时摘流量。

### 告警行为（实测，来自 AM 通知计数与 Prometheus ALERTS 序列）

- **业务告警 `DeploymentReplicasUnavailable` 全程未触发**——迁移 11s 远小于 `for: 1m`
  阈值。优雅排水根本不该触发告警，这正是副本 ≥2 的意义。
- 新增通知 email+3 / webhook+2，**全部是监控栈自噪音**：
  - `AlertmanagerClusterDown`：AM 的 StatefulSet Pod 恰好驻留在 w1，驱逐它自己的瞬间
    它给自己报了警（且通知计数器随 Pod 迁移清零）——「监控组件没有反亲和/独占调度」
    是这次演练暴露的真实改进项；
  - `CPUThrottlingHigh`：node-exporter 替补 Pod 短时节流；
  - `InfoInhibitor`(boutique) 按任务 7 的路由被抑制，未产生通知。
- 教训（面试可用）：**演练之前先查清楚监控组件住在哪个节点**，否则排水会顺手把
  监控/告警链路自己也抖一下——观测系统要先于被观测对象高可用。

---

## 演练二：节点硬宕机

**执行时间：** 2026-09-14 01:39-01:50（T0=01:39:40 观测器启动；约 01:40:50 控制台普通关机，探针 01:40:54 起首次异常）

```bash
# 录屏开始 --------------------------------
# 【阿里云控制台】找到 k8s-w2 → 实例状态 → 停止/重启 → 强制关机
# 观察 k8s-cp 上的节点状态变化
kubectl get nodes -w
# 观察 Pod 漂移
kubectl get pods -n boutique -o wide -w
# 观察告警（邮箱 / 钉钉）
# 演练结束后在控制台开机
# 【cp 上执行】节点回来后解除驱逐保护
kubectl uncordon k8s-w2
# 录屏结束 --------------------------------
```

### 时间线（实测回填）

| 时刻 | 事件 | 距断电（01:40:50 起） |
|---|---|---|
| 01:40:54 | probe 首次异常（1×502，随后 000 连接拒绝） | T+4s |
| 01:41:26 | 节点 w2 转 NotReady（心跳超时） | T+36s |
| 01:42:14 | **告警抵达邮箱**（NodeNotReady，critical，截图 chaos-02） | T+84s |
| 01:42:49 | AM 计数 email=1 / webhook=1（钉钉 01:43 到达，截图 chaos-03） | T+119s |
| 01:46:28 | taint 驱逐生效：10 个 w2 Pod → Terminating | T+338s |
| 01:46:30 | 替补 Pod 在 w1 批量 Running（Traefik 两个替补同时拉起） | T+340s |
| 01:47:14 | **服务恢复 200**（01:47:33-35 有 3s 抖动后稳定） | T+384s |
| 01:48:51 | 控制台开机后节点重新 Ready（开机→Ready 约 80s） | T+481s |
| 01:49:12 | RESOLVED 恢复通知开始投递（email 8→12、webhook 1→2） | T+502s |
| 01:49:34 | w2 重入引起 endpoints 抖动：单次 5s 超时后恢复 | T+524s |

> 本次演练实际为「普通关机」而非强制断电：kubelet 收到 SIGTERM 优雅退出，
> 但后续现象（NotReady → taint 驱逐 → 重建 → 告警）与硬宕机完全一致，
> 只是 Pod 侧多了优雅终止。结论不受影响。

### 服务可用性

| 指标 | 数值 |
|---|---|
| 探测总请求数 | `460`（01:39:53 - 01:50:33） |
| 200 响应数 | `130` |
| 非 200 响应数 | `329×000 + 1×502` |
| **可用率** | `28.3%`（入口层单点所致，见下方结论） |
| **最长中断时长** | `378` 秒（01:40:54 → 01:47:12） |

> 关键结论（面试口径，**本节是本次演练最值钱的发现**）：
> "业务 Pod 按副本 ≥2 + 反亲和部署，w2 断电后另一半副本在 w1 存活——
> 直连 frontend ClusterIP 验证业务层健康。但探针却中断了 6 分 18 秒，
> 根因是 **Traefik 两个副本都在 w2**：这个 Deployment 配的是 preferred（软）反亲和，
> 演练一排水 w1 时控制面带污点不可入、当时唯一可调度节点只剩 w2，软反亲和必然让位；
> 且 K8s 没有 rebalance，替补落 w2 后就再也回不去了，入口层成了事实上的单点。
> **K8s 的高可用是逐层的——Pod 反亲和只保护了业务层，不代表整条链路高可用；
> ingress、监控（kube-state-metrics 也在 w2）、存储（redis-cart 单副本）
> 每一层都要单独做同样的检查**。这就是混沌工程的价值：配置审查时每层"看起来都对"，
> 只有真把节点打挂才能暴露层间的组合缺陷。"
>
> **修复**（2026-09-14 02:22 已上云，见下节「修复与复验」）：软反亲和升 required（硬）
> + 控制面 toleration，任一 worker 故障时另一半容量必然存活、替补自动落控制面。

---

## 修复与复验：Traefik 入口层单点（改进项 #5 闭环，2026-09-14 02:22）

> 「发现 → 修复 → 复验」完整闭环。修复手段 = **反亲和 preferred→required + 控制面 toleration**。

### 修复内容

`manifests/ingress/traefik-values.yaml` 两处（本地 `helm template` 渲染 diff 验证：394 行输出
仅这两处变化，其余逐字节一致，无字段静默失效）：

1. **软反亲和 → 硬（required）反亲和**（`kubernetes.io/hostname`）：调度期强制不同节点。
   修复的是「全灭」模式——任一 worker 故障，另一节点上的入口副本**必然**存活
   （NodePort 全节点监听 + `externalTrafficPolicy: Cluster`，流量可达存活副本）
2. **新增控制面 toleration**（`node-role.kubernetes.io/control-plane:NoSchedule`）：
   否则替补 Pod 在「两 worker 各占一副本」时只能 Pending 等节点回来；
   容忍后替补自动落控制面，故障期间保持 2 副本全容量、零人工干预。
   取舍：入口组件请求量极小（100m/128Mi），实验室 3 节点集群值得用控制面换全容量自愈

### 上云与复验（scripts/fix-traefik-affinity.py，全程时间戳留痕）

| 时刻 | 事件 |
|---|---|
| 02:22:14 | 修复前基线：**双副本同落 w1**（演练二 taint 驱逐后替补只能落 w1，又一层「无回流」印证） |
| 02:22:14 | 新 values SFTP 上传 + md5 校验一致 |
| 02:22:16 | `helm upgrade` 成功（Revision 4） |
| 02:22:23 | 滚动更新开始：新副本① 落 **w2**（老副本占 w1，required 生效的第一手证据） |
| 02:22:4x | 新副本② 落 **cp**（toleration 生效的直接证据——w1/w2 均被占，硬反亲和把第二个新副本逼到控制面） |
| 02:23:38 | **稳态复验**：`successfully rolled out`，双副本 **w2 + cp** 分落两节点，入口探活 **200** |

> 复验证据链：`docs/traefik-affinity-fix.log`（SFTP md5 / 轮询过程 / rollout status / 最终分布 / 探活）。
> 若要复演此修复的防御效果，可重放演练二（w2 关机）：预期入口**不再全灭**，
> cp/w1 上的副本继续服务，整站可用率从 28.3% 显著抬升（复演属可选加分项）。

---

## 根因与改进项

### 观察到的不足

| # | 问题 | 影响 | 改进方案 | 是否已实施 |
|---|---|---|---|---|
| 1 | 节点失联到驱逐有 338s 窗口（心跳 40s + toleration 300s） | 故障期间流量全部失败（本次因入口层同灭） | 缩短 tolerationSeconds / grace period（增大误判风险，需权衡） | 否（保持默认，理由见结论） |
| 2 | 告警到达延迟 84s（断电→邮箱） | 值班响应变慢 | 已在合理范围（采集15s+求值15s+for 60s）；可增加即时通道 | 已达标 |
| 3 | 节点恢复后未自动 rebalance | 负载不均（本次全部堆在 w1） | 引入 descheduler，或定期人工再均衡 | 否 |
| 4 | Pod 漂移期间新 Pod 拉镜像慢 | 恢复时间变长 | 各节点预热镜像（DaemonSet 预拉） | 否 |
| 5 | ★ **Traefik 双副本同节点（软反亲和在 drain 场景失效）**，且替补不回流 | **入口层单点：节点断电=整站不可用，尽管业务层存活** | Traefik values 反亲和 preferred→required + 控制面 toleration；把 ingress/监控/存储纳入「双副本必须跨节点」检查清单 | ✅ **已实施（2026-09-14 02:22-02:23）**，见下方「修复与复验」 |
| 6 | kube-state-metrics、metrics-server、redis-cart 均无跨节点冗余 | w2 断电期间部分指标缺失、购物车暂不可用 | 关键组件反亲和 / redis-cart 改主从 | 否 |

### 做得对的地方（也要写，面试时是加分项）

- 副本 ≥2 + 反亲和（业务层），单节点故障业务层只损失一半容量
- 告警链路（Prometheus → AM → 邮箱/钉钉）在故障场景下 84s 触达，恢复通知 502s 到达，全程无需人工介入
- taint 驱逐 + 重建全自动完成：断电后 340s 替补已在健康节点 Running，无需人工
- 探测脚本提供了**连续可量化的证据**，而不是"我感觉没断"
- ⚠️ 修正预设认知：原以为「NodePort 在所有节点监听 = 入口高可用」——实测**入口的可用性
  取决于后端 Traefik Pod 在哪个节点**，而不是 NodePort 端口在哪监听。这正是演练二的价值

---

## 附件

| 文件 | 说明 |
|---|---|
| `probe.log` | 演练全程可用性原始数据 |
| `screenshots/chaos-01-drain.png` | drain 过程 Pod 漂移截图 |
| `screenshots/chaos-02-alert-email.png` | 邮件告警截图 |
| `screenshots/chaos-03-alert-dingtalk.png` | 钉钉告警截图 |
| `screenshots/chaos-04-recovery.png` | 恢复通知截图 |
| `screenshots/chaos-05-poweroff.png` | 演练二时间线 + 可用性窗口条（合成图，数据源 chaos-drill2-timeline.log / probe-drill2.log） |
| `chaos-drill2-timeline.log` / `probe-drill2.log` | 演练二 2s 轮询时间线 / 460 条探针原始数据 |
| `traefik-affinity-fix.log` | 改进项 #5 修复全程日志（SFTP md5 / 轮询 / 稳态复验） |
| 录屏文件 | 演练一 / 演练二各一段（不上传仓库，放网盘） |
