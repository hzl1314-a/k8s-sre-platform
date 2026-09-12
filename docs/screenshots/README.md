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
| `09-grafana-datasources.png` | Grafana → Connections → Data sources：**Prometheus / Alertmanager / Loki 三个都在**，Loki 的 `Save & test` 通过 | 待采集 |
| `10-grafana-dashboard.png` | **自建业务总览看板**（`Dashboards` 搜索 `Boutique`）：QPS / P95 / 5xx / 重启 / CPU / 内存 / 日志 全部出数 | 待采集 |
| `11-grafana-pod-metrics.png` | 看板下半部分的单 Pod CPU / 内存曲线 | 待采集 |
| `12-loki-logs.png` | Explore 中数据源选 Loki，查询 `{namespace="boutique"}` 能看到容器日志 | 待采集 |

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
| `13-alert-rule-fired.png` | Prometheus 中告警规则变为 FIRING | 待采集 |
| `14-alert-email.png` | 邮箱收到的告警邮件 | 待采集 |
| `15-alert-dingtalk.png` | 钉钉机器人收到的告警 | 待采集 |
| `16-alert-recovered.png` | 恢复通知 | 待采集 |

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
