# 截图索引

本目录存放项目各阶段的留证截图。**面试证据链的核心材料**，命名统一为 `阶段-序号-内容.png`。

## 采集规范

- 用 Win+Shift+S 截取**命令输出 + 时间戳**，不要裁剪掉上下文
- 关键命令建议同时保留完整的窗口截图（含 hostname 提示符，能证明是在真实节点上执行的）
- 每张图在下方表格登记，方便写 README 和简历时引用

## 清单

### S1 集群底座（任务 1-3）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `01-nodes-ready.png` | `kubectl get nodes -o wide`，三节点 Ready | ✅ 已采集 |
| `02-calico-pods.png` | `kubectl get pods -n calico-system` 全 Running | ✅ 已采集 |
| `03-kube-system.png` | `kubectl get pods -n kube-system` 全 Running | ✅ 已采集 |
| `04-remote-kubectl.png` | **本机**执行 `kubectl get nodes`（证明远程管理能力） | ⬜ **待采集** |

> **关于 `04-remote-kubectl.png`**：它证明的是「能在本机管理集群」这件事，
> 用的是 **SSH 隧道**方案（**不是**把 6443 暴露到公网）。做法见 `docs/setup-cluster.md` 3.4 节。
> 核心就两条：
>
> ```bash
> # 终端 A：保持隧道不关
> ssh -N -L 6443:127.0.0.1:6443 root@<cp公网IP>
> # 终端 B
> kubectl get nodes
> ```
>
> 这张图是 S1 验收标准「远程 kubectl」的实证，也是简历上「能远程管理集群」的证据。
> 漏了不影响后面推进，但建议补上。

### S2 业务上线（任务 4-5）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `05-boutique-pods.png` | `kubectl get pods -n boutique -o wide`：22 个 Pod 全 Running，**同时证明反亲和生效**（每个服务的两个副本 NODE 列不同） | ✅ 已采集 |
| `06-ingress-nodeport.png` | `kubectl get svc -n traefik` + `kubectl get ingressroute -n boutique`：入口 NodePort 映射与路由规则 | ✅ 已采集 |
| `07-shop-page.png` | 浏览器访问 `http://<ECS公网IP>:30080` 的商店页面 | ✅ 已采集 |
| `08-traefik-dashboard.png` | `http://<ECS公网IP>:30800/dashboard/` Traefik 面板 | ✅ 已采集 |

> **关于 05 与 06**：一张 `-o wide` 的输出同时能证明两件事——Pod 全部 Running，
> 以及每个服务的两个副本落在不同节点（看 NODE 列）。所以 05 一张就够，
> 06 改为「入口层」的证据，对应任务 5 的验收点（NodePort 暴露 + IngressRoute 路由）。
>
> **07 是这套截图里最有价值的一张**——它是整个项目第一个「看得见」的成果，
> 面试时比任何终端输出都直观。

### S3 可观测性（任务 6）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `09-grafana-datasources.png` | Grafana → Connections → Data sources：**Prometheus / Alertmanager / Loki 三个都在**（Loki 连通性此前已在详情页单独验证过：`Save & test` 绿色成功） | ✅ 已采集 |
| `10-grafana-dashboard.png` | **自建业务总览看板全貌**（含浏览器地址栏）：QPS / P95 / 5xx / 响应码 / 重启 / CPU / 内存 / 日志 8 块面板全部出数，可见 15:00 与 15:25 两次流量尖峰 | ✅ 已采集 |
| `11-grafana-pod-metrics.png` | 看板下半部分：Pod 重启次数 / Pod CPU 使用率 / Pod 内存（working set）曲线 | ✅ 已采集 |
| `12-loki-logs.png` | Explore 中数据源选 Loki（**Code 模式**），查询 `{namespace="boutique"}`：日志流 + Logs volume 直方图 + 左侧字段面板可见 namespace / app / pod / container 等标签 | ✅ 已采集 |

> **编号说明（2026-09-13 修正）**：本节此前误用了 `08`，与 S2 的 `08-traefik-dashboard.png`
> 冲突。截图为线性编号，跨阶段不重号，故本阶段顺延为 `09-12`，后续阶段同步顺延。
>
> **`10-grafana-dashboard.png` 是任务 6 的核心留证**：它同时证明了
> 「Prometheus 采到了 Traefik 的指标」+「Loki 收到了 Promtail 推的日志」+「看板是自建的」。
> 找看板时注意：列表按名称排序，「Online Boutique 业务总览」首字母 O 靠后，
> 用顶部搜索框输 `Boutique` 更快。

### S4 告警（任务 7）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `13-alert-rule-fired.png` | Prometheus → Alerts 页面，`DeploymentReplicasUnavailable` 状态为 **FIRING**（截图要带上浏览器地址栏，证明是本集群的 Prometheus） | ⬜ **待采集（本阶段唯一还缺的一张，操作步骤见下方「怎么截 13」）** |
| `14-alert-email.png` | 邮箱收到的告警邮件（**必须能看到收件时间**） | ✅ 已采集（20:40 的 `[FIRING:1] DeploymentReplicasUnavailable`，红色横幅） |
| `15-alert-dingtalk.png` | 钉钉机器人收到的告警（**带上消息时间戳**） | ✅ 已采集（钉钉桌面客户端，**一张图含 FIRING 20:40 与 RESOLVED 20:43 两条**） |
| `16-alert-recovered.png` | 恢复通知（邮件或钉钉任一即可，证明闭环） | ✅ 已采集（20:43 的 `[RESOLVED]` 邮件，绿色横幅） |

> **主验收告警是 `DeploymentReplicasUnavailable`，不是 `IngressHighErrorRate`**。
> 前者 `for: 1m`，本次实测 **T+70s** 触发；后者要 `for: 5m` + 5 分钟速率窗口，
> 本次演练（故障约 150 秒）**不会**触发。别在告警列表里干等它。
> 完整时间预算见 `docs/alerting.md` §3。
>
> **本次实测时间线**（2026-09-13 20:00:53 注入故障）：
> Pending **+9s** → Firing **+70s** → Alertmanager 收到 **+70s** →
> 邮件/钉钉投递 **≈+75s** → 恢复 +220s → Resolved **+250s**。
> 每个数字的取值方法与回填表见 `docs/alerting.md` §4。
>
> **收件人界面只到分钟，别拿它当秒级证据**：邮箱显示 `20:40`，钉钉桌面客户端显示
> `20:40` / `20:43`，都没有秒。**更别用 Alertmanager 日志**——「首次投递成功」是
> `Debug` 级别（`notify/retry_stage.go`），默认 `logLevel=info` 下 grep 零命中。
>
> 要精确秒数就跑 `bash scripts/alert-drill.sh --report`（只读，复用它自己采样的
> `alert-drill.log.samples`），方法见 `docs/alerting.md` §4.0。
>
> **两个小提醒**：
> ① `14` 的截图含浏览器其余标签页（云控制台、学习页面等），仓库若要公开，
>    建议裁掉浏览器 chrome 只留邮件内容——更干净，也不泄露无关浏览信息；
> ② `13` 截图时把 `alert-drill.log` 的时间线几行放进同一画面，面试被追问
>    「这个 70 秒怎么来的」时，图里就有「故障注入」与「Firing」两个锚点自证。


### 怎么截 13（S4 唯一还缺的一张）

**为什么它最容易漏**：告警**只在故障期间是 FIRING**，副本一恢复它就变 Resolved 了。
所以必须在「故障保持」的那段时间里去截，不能等演练脚本跑完。

**关键点**：Prometheus 的 Service 是 ClusterIP，本机浏览器直连不到，要走 SSH 隧道。
不用跑完整演练，单独制造一次故障更省事。

```bash
# ── 终端 A（在 cp 上）：把 Prometheus 暴露在 cp 的 127.0.0.1:9090 ──
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

# ── 终端 B（在本机）：把 cp 的 9090 映射到本机，保持不关 ──
ssh -N -L 9090:127.0.0.1:9090 root@8.155.129.89

# ── 终端 C（在 cp 上）：制造故障，等告警进入 FIRING ──
kubectl -n boutique scale deploy/frontend --replicas=0
#   等 75~90 秒（规则 for: 1m + 求值周期），状态会从 Inactive → Pending → Firing
```

> 如果你正在跑 `alert-drill.sh`，它用的是 **19090** 端口，与上面的 9090 **不冲突**，
> 可以并行开着——演练跑到「保持故障 Ns」那一步时去截图最自然。

浏览器打开 **`http://localhost:9090/alerts`**，找到 `DeploymentReplicasUnavailable`，
点开展开。**截图必须同时可见三样**：

1. 浏览器**地址栏**（`localhost:9090` —— 证明是从这条隧道连进本集群的 Prometheus）
2. 告警名 `DeploymentReplicasUnavailable` 与 **State = Firing**（红色）
3. `Active Since` 的时间（要能和 `alert-drill.log` 里的故障时刻对上）

截完**立刻恢复**，别让业务一直挂着：

```bash
# ── 终端 C（在 cp 上）──
kubectl -n boutique scale deploy/frontend --replicas=2
```

**可选的加强证据**（不是必需，但面试时更硬）：在 FIRING 期间另开一个终端跑

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/alerts | jq -r '.data.alerts[] | select(.labels.alertname=="DeploymentReplicasUnavailable") | "\(.state)  activeSince=\(.activeAt)"'
# 期望：firing  activeSince=2026-09-13T20:40:3x+08:00
```

把这段终端输出和浏览器页面**截在同一张图**里（左右并排或上下排列），
`13` 就同时有了「UI 状态」和「API 原始字段」两个锚点——这比单看 UI 更有说服力。

**归档命令**（截完照做）：

```bash
# 本机：把新截的图放进仓库（文件名必须完全一致）
cp ~/Pictures/Screenshots/<你的截图>.png docs/screenshots/13-alert-rule-fired.png
```

### S5 压测与 HPA（任务 8）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `17-hpa-scale-up.png` | `kubectl get hpa -w` 扩容过程 | 待采集 |
| `18-hey-result.png` | hey 压测结果（QPS / 延迟分布） | 待采集 |
| `19-grafana-hpa-curve.png` | 压测期间 QPS 与副本数曲线 | 待采集 |

### S6 故障演练（任务 9）

> 本节用 `chaos-` 前缀而非数字编号——演练截图是成组的、顺序性强，
> 独立前缀比继续顺延数字更清晰，也避免后续插入时再动一遍编号。

| 文件名 | 内容 | 状态 |
|---|---|---|
| `chaos-01-drain.png` | drain 过程 Pod 漂移 | 待采集 |
| `chaos-02-alert-email.png` | 宕机告警邮件 | 待采集 |
| `chaos-03-alert-dingtalk.png` | 宕机告警钉钉 | 待采集 |
| `chaos-04-recovery.png` | 恢复通知 | 待采集 |
