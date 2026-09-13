# 回填 chaos-drill.md 演练一实测数据 + 注册截图索引
import io

p = r'E:/yes/k8s-sre-platform/docs/chaos-drill.md'
s = io.open(p, encoding='utf-8').read()

old_time = '**执行时间：** `待填`'
assert s.count(old_time) == 2  # 演练一、演练二各一处，只回填演练一（第一处）
s = s.replace(old_time, '**执行时间：** 2026-09-14 01:15:01 - 01:15:13（排水全程 11s），探针观察窗 600s', 1)

old_tl = """| 时刻 | 事件 | 距演练开始 |
|---|---|---|
| T+0s | 执行 drain | — |
| T+__s | 第一个 Pod 收到 SIGTERM | __s |
| T+__s | Pod 状态变为 Terminating | __s |
| T+__s | 新 Pod 在其他节点 Pending | __s |
| T+__s | 新 Pod Running 并通过就绪探针 | __s |
| T+__s | 全部 Pod 迁移完成，drain 返回 | __s |
| T+__s | `uncordon` 恢复节点 | __s |"""
new_tl = """| 时刻 | 事件 | 距演练开始 |
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
> 没有「拉镜像几分钟」的等待，这是改进项 #4 已隐性达成的原因。"""
assert s.count(old_tl) == 1
s = s.replace(old_tl, new_tl)

old_av = """| 指标 | 数值 |
|---|---|
| 探测总请求数 | `__` |
| 200 响应数 | `__` |
| 非 200 响应数 | `__` |
| **可用率** | `__%` |
| 最长连续失败 | `__` 次 |"""
new_av = """| 指标 | 数值（实测 600s 窗口） |
|---|---|
| 探测总请求数 | 309 |
| 200 响应数 | 306 |
| 非 200 响应数 | 3（000 × 2、500 × 1，全部集中在 01:15:15-01:15:17 驱逐窗口） |
| **可用率** | **99.03%** |
| 最长连续失败 | 2 次（2 秒） |
| 最高延迟 | 3.11s（01:15:27，驱逐后 endpoints 收敛期），其余全部 <1.25s |

> 结论：309 次请求只有 3 次失败，且 2 秒后自愈——「副本 ≥2 + 反亲和 + NodePort 全节点暴露 +
> 就绪探针摘流量」的组合把排水影响压到了秒级。kube-proxy endpoints 收敛的几秒延迟是
> 那 3 次失败的来源（旧 Pod 已死、新 Pod 已就绪，但 Service 端点表还没刷新完）。"""
assert s.count(old_av) == 1
s = s.replace(old_av, new_av)

# 告警观察（追加到可用性小节后）
anchor = "> 若出现少量 5xx：分析是 drain 瞬间的连接重置（客户端未重试），还是有 Pod 未及时摘流量。"
assert s.count(anchor) == 1, 'anchor not found'
s = s.replace(anchor, anchor + """

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
  监控/告警链路自己也抖一下——观测系统要先于被观测对象高可用。""")

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('chaos-drill.md backfilled OK')

# ---- 截图索引 ----
p2 = r'E:/yes/k8s-sre-platform/docs/screenshots/README.md'
s2 = io.open(p2, encoding='utf-8').read()
old2 = '| `chaos-01-drain.png` | drain 过程 Pod 漂移 | 待采集 |'
new2 = '| `chaos-01-drain.png` | 演练一 Pod 漂移 + 可用性 99.03% + 告警行为（合成图，数据源 chaos-drill1-timeline.log / probe-drill1.log） | ✅ 2026-09-14 |'
assert s2.count(old2) == 1
s2 = s2.replace(old2, new2)
io.open(p2, 'w', encoding='utf-8', newline='\n').write(s2)
print('screenshots README registered OK')
