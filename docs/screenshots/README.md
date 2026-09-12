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
| `01-nodes-ready.png` | `kubectl get nodes -o wide`，三节点 Ready | 待采集 |
| `02-calico-pods.png` | `kubectl get pods -n calico-system` 全 Running | 待采集 |
| `03-kube-system.png` | `kubectl get pods -n kube-system` 全 Running | 待采集 |
| `04-remote-kubectl.png` | **本机**执行 `kubectl get nodes`（证明远程管理能力） | 待采集 |

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
| `05-boutique-pods.png` | `kubectl get pods -n boutique -o wide`，Pod 分散在两节点 | 待采集 |
| `06-antiaffinity.png` | 反亲和生效证明（同一 Deployment 的副本在不同 NODE 列） | 待采集 |
| `07-shop-page.png` | 浏览器访问 `http://<IP>:30080` 的商店页面 | 待采集 |

### S3 可观测性（任务 6）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `08-grafana-dashboard.png` | 自建业务总览看板 | 待采集 |
| `09-grafana-pod-metrics.png` | 单 Pod CPU/内存曲线 | 待采集 |
| `10-loki-logs.png` | Explore 中查询 boutique 容器日志 | 待采集 |

### S4 告警（任务 7）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `11-alert-rule-fired.png` | Prometheus 中告警规则变为 FIRING | 待采集 |
| `12-alert-email.png` | 邮箱收到的告警邮件 | 待采集 |
| `13-alert-dingtalk.png` | 钉钉机器人收到的告警 | 待采集 |
| `14-alert-recovered.png` | 恢复通知 | 待采集 |

### S5 压测与 HPA（任务 8）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `15-hpa-scale-up.png` | `kubectl get hpa -w` 扩容过程 | 待采集 |
| `16-hey-result.png` | hey 压测结果（QPS / 延迟分布） | 待采集 |
| `17-grafana-hpa-curve.png` | 压测期间 QPS 与副本数曲线 | 待采集 |

### S6 故障演练（任务 9）

| 文件名 | 内容 | 状态 |
|---|---|---|
| `chaos-01-drain.png` | drain 过程 Pod 漂移 | 待采集 |
| `chaos-02-alert-email.png` | 宕机告警邮件 | 待采集 |
| `chaos-03-alert-dingtalk.png` | 宕机告警钉钉 | 待采集 |
| `chaos-04-recovery.png` | 恢复通知 | 待采集 |
