# -*- coding: utf-8 -*-
"""演练二实测数据回填 chaos-drill.md（原子替换 + 断言）。数据源：
docs/chaos-drill2-timeline.log、docs/probe-drill2.log、用户截图（chaos-02/03）。
"""
import io

P = r'E:/yes/k8s-sre-platform/docs/chaos-drill.md'
s = io.open(P, encoding='utf-8').read()

# 1) 执行时间
old = '**执行时间：** `待填`'
assert s.count(old) == 1, 'exec-time anchor'
new = ('**执行时间：** 2026-09-14 01:39-01:50（T0=01:39:40 观测器启动；'
       '约 01:40:50 控制台普通关机，探针 01:40:54 起首次异常）')
s = s.replace(old, new)

# 2) 时间线表（整表替换；T+ 以断电 01:40:50 为原点）
old_tl = """| 时刻 | 事件 | 距关机 |
|---|---|---|
| T+0s | 控制台强制关机 | — |
| T+__s | probe.log 首次出现异常状态码 | __s |
| T+__s | 节点变为 NotReady（心跳超时，约 40s） | __s |
| T+__s | **告警抵达邮箱** | __s |
| T+__s | **告警抵达钉钉** | __s |
| T+__s | Pod 被驱逐（taint-based eviction 生效） | __s |
| T+__s | 新 Pod 在 k8s-w1 上 Running | __s |
| T+__s | 服务恢复 200 | __s |
| T+__s | 节点开机，节点状态 Ready | __s |
| T+__s | 收到恢复通知 | __s |"""
assert s.count(old_tl) == 1, 'timeline anchor'
new_tl = """| 时刻 | 事件 | 距断电（01:40:50 起） |
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
> 只是 Pod 侧多了优雅终止。结论不受影响。"""
s = s.replace(old_tl, new_tl)

# 3) 可用性表
old_av = """| 指标 | 数值 |
|---|---|
| 探测总请求数 | `__` |
| 200 响应数 | `__` |
| 非 200 响应数 | `__` |
| **可用率** | `__%` |
| **最长中断时长** | `__` 秒 |"""
assert s.count(old_av) == 1, 'availability anchor'
new_av = """| 指标 | 数值 |
|---|---|
| 探测总请求数 | `460`（01:39:53 - 01:50:33） |
| 200 响应数 | `130` |
| 非 200 响应数 | `329×000 + 1×502` |
| **可用率** | `28.3%`（入口层单点所致，见下方结论） |
| **最长中断时长** | `378` 秒（01:40:54 → 01:47:12） |"""
s = s.replace(old_av, new_av)

# 4) 面试口径结论（重写为实测真相）
old_con = '> 关键结论（面试口径）：\n> "节点硬关机场景下，中断窗口约 `__` 秒，来源是 K8s 判定节点失联的等待时间。\n> 这个窗口可以通过调小 `node-monitor-grace-period` 缩短，但会增大误判风险——\n> **这是一个可用性和稳定性的权衡，不是配置错误**。"'
assert s.count(old_con) == 1, 'conclusion anchor'
new_con = """> 关键结论（面试口径，**本节是本次演练最值钱的发现**）：
> "业务 Pod 按副本 ≥2 + 反亲和部署，w2 断电后另一半副本在 w1 存活——
> 直连 frontend ClusterIP 验证业务层健康。但探针却中断了 6 分 18 秒，
> 根因是 **Traefik 两个副本都在 w2**：这个 Deployment 没配反亲和，
> 且演练一排水时替补 Pod 落在 w2 后没有再均衡，入口层成了事实上的单点。
> **K8s 的高可用是逐层的——Pod 反亲和只保护了业务层，不代表整条链路高可用；
> ingress、监控（kube-state-metrics 也在 w2）、存储（redis-cart 单副本）
> 每一层都要单独做同样的检查**。这就是混沌工程的价值：配置审查时每层"看起来都对"，
> 只有真把节点打挂才能暴露层间的组合缺陷。" """
s = s.replace(old_con, new_con)

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('drill2 section backfilled OK')
