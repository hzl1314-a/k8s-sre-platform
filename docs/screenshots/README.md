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
| `13-alert-rule-fired.png` | Prometheus → Alerts 页面，`DeploymentReplicasUnavailable` 状态为 **FIRING** | ✅ 已采集（**合成图**：UI 的 FIRING 徽标 + `/api/v1/alerts` 原始 JSON（`state=firing`、`activeAt=21:43:16`）+ kubectl 现场 `frontend 0/0` 三样同框） |
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


### 13 这张是怎么截的（2026-09-13 实录，下次复用）

**难点**：Prometheus 的 Service 是 ClusterIP，本机浏览器够不到；而告警只在故障期间是
FIRING，必须在那段时间里截。

**实际做法**（比原计划的「kubectl port-forward + SSH -L」更省事）：

1. **隧道**：节点本身就能路由到 ClusterIP（kube-proxy 在每个节点都装了 iptables 规则），
   所以直接把本机 9090 转发到 `<Prometheus ClusterIP>:9090` 即可，**不需要 kubectl
   port-forward**（也就不依赖一个必须一直挂着的终端）。
2. **注入故障**：`kubectl -n boutique scale deploy/frontend --replicas=0`，等 70~90 秒。
3. **截图**：Chrome 自带的无头截图就够了，不需要浏览器自动化框架——
   但必须加 `--no-proxy-server`（否则走系统代理，127.0.0.1 会被代理拦成
   `ERR_CONNECTION_ABORTED`）：

   ```bash
   chrome.exe --headless=new --disable-gpu --no-proxy-server --hide-scrollbars \
     --window-size=1560,1080 --virtual-time-budget=15000 \
     --screenshot=ui.png "http://127.0.0.1:9090/alerts"
   ```
4. **补第二锚点**：同时取 `/api/v1/alerts` 的原始 JSON（`state=firing` + `activeAt`）
   和 `kubectl get deploy`（显示 0/0，证明故障确实在场），三样合成一张图。
5. **立刻恢复**：`kubectl -n boutique scale deploy/frontend --replicas=2`。

> 两个小坑：① SSH 空闲连接会被服务端掐掉，转发进程要带 keepalive 并支持重连，
> 否则表现为「隧道进程活着但连不上」；② MSYS/Git Bash 会改写看起来像 Windows 路径的
> 参数（`E://tmp//x` → `E://tmp//x`），传给 Python 前用正斜杠写法最稳。


### S5 压测与 HPA（任务 8）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `17-hpa-scale-up.png` | HPA 扩缩容全周期（6 帧合成：基线 2→CPU 爬升→扩容 3→求衡→负载归零→缩容 2，附 Prometheus 交叉验证） | ✅ 2026-09-14 合成图（数据源 `docs/hpa-drill-timeline.log`，先例同截图 13） |
| `18-hey-result.png` | hey 压测结果：7426 请求全部 200，24.66 req/s，P99 2.78s | ✅ 2026-09-14 合成图（数据源 `docs/hpa-hey-result.txt`，先例同截图 13） |
| `19-grafana-hpa-curve.png` | Grafana 业务总览 30 分钟全周期：QPS 爬坡→峰值 25 req/s→回落；P95 延迟平台；Pod CPU 峰值；含 currencyservice OOM 重启阶梯 | ✅ 2026-09-14 真机截图（puppeteer + 本机 Chrome 无头登录，`scripts/grafana-shot.mjs`） |

### S6 故障演练（任务 9）

> 本节用 `chaos-` 前缀而非数字编号——演练截图是成组的、顺序性强，
> 独立前缀比继续顺延数字更清晰，也避免后续插入时再动一遍编号。

| 文件名 | 内容 | 状态 |
|---|---|---|
| `chaos-01-drain.png` | 演练一 Pod 漂移 + 可用性 99.03% + 告警行为（合成图，数据源 chaos-drill1-timeline.log / probe-drill1.log） | ✅ 2026-09-14 |
| `chaos-02-alert-email.png` | 宕机告警邮件（NodeNotReady critical，01:42:14 到达） | ✅ 2026-09-14 |
| `chaos-03-alert-dingtalk.png` | 宕机告警钉钉（01:43 到达） | ✅ 2026-09-14 |
| `chaos-04-recovery.png` | 恢复通知邮件（RESOLVED NodeNotReady，01:49 到达） | ✅ 2026-09-14 |
| `chaos-04-recovery-dingtalk.png` | 恢复通知钉钉（01:49 到达） | ✅ 2026-09-14 |
| `chaos-05-poweroff.png` | 演练二时间线 + 可用性窗口条（合成图） | ✅ 2026-09-14 |
