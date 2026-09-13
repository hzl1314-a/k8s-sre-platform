# k8s-sre-platform 交接文档

> **交接时间**：2026-09-13
> **交接人**：上一任工程师（与 AI 协作完成）
> **接收人**：下一任工程师
> **阅读时间**：约 15 分钟。读完本文档即可独立继续，不需要翻历史聊天记录。

---

## 零、上一轮会话交接摘要（2026-09-13 晚 · 先读这一节）

**一句话**：任务 7（告警）已从「待执行」做到「完整收尾」，下一步是**任务 8**。
本节是上一轮会话的浓缩，细节都在对应文档里，不需要翻历史聊天记录。

### 这轮做成了什么

| 事项 | 结果 |
|---|---|
| 告警双通道验收 | **故障 → 邮件/钉钉投递 = T+74s**（验收线 120s）；4 场演练 82 / 70 / 73 / 70 秒 |
| 截图 13-16 | 全部归档 `docs/screenshots/`（13 是**合成图**：UI FIRING 徽标 + `/api/v1/alerts` 原始 JSON + kubectl `frontend 0/0` 现场） |
| 时间线与投递秒数 | 已回填 `docs/alerting.md` §4，可直接进 README / 简历 |

### 这轮修掉的三个根因（都是现成的面试故事）

1. **钉钉的 helm chart 已从 prometheus-community 下架**（仓库索引 / charts 目录 / 历史
   release 资产三条证据核实）→ 改自维护清单 `manifests/alerts/dingtalk-webhook.yaml`；
   该组件**不暴露 /metrics**，不能挂 ServiceMonitor（会造成永久 `up=0`）
2. **values 里 5 个死配置键**（chart 90.1.1 中不存在，helm 静默忽略）+ 收口路由把
   `severity=none` 的 InfoInhibitor 也发了邮件 → 删死键，并在路由层加
   `severity=none → receiver discard`（**不删规则**：`general.rules` 里还住着 TargetDown）
3. **★ 最隐蔽**：Operator 的 `alertmanagerConfigMatcherStrategy` 默认 `OnNamespace`，
   会给 AlertmanagerConfig **每条路由**追加 `namespace = monitoring`，导致 `boutique`
   的告警一条都匹配不上——症状极迷惑（Prometheus 正常 FIRING、Alertmanager 也收到了，
   就是不发通知）。已设 `OnNamespaceExceptForAlertmanagerNamespace`，详见 §5.3 第 12 条

### 投递时刻怎么取（机制迭代过两次，别用旧法）

- ❌ **收件人界面**：邮箱与钉钉桌面客户端都只显示到**分钟**
- ❌ **Alertmanager 日志**：`msg="Notify success"` 在「首次投递成功」时是 **Debug** 级别
  （`notify/retry_stage.go`：`if i <= 1 { l.Debug(...) } else { l.Info(...) }`），
  默认 `logLevel=info` 下 grep 整段日志**零命中**——真机踩过，机制第一次上云就失灵
- ✅ **现行方案**：演练期间**每 2s 直连 Alertmanager `/metrics`** 采样
  `alertmanager_notifications_total`，记录各通道**首次自增**时刻（精度 ±2s）。
  实现在 `scripts/alert-drill.sh` 的 [8/8] 段；`--report` 只读复用 `alert-drill.log.samples`

### ⚠️ 待拍板的遗留问题（本轮唯一没做完的决策）

**`ScrapeTargetDown` 正在常驻 FIRING**：3 个节点的 kube-proxy 指标端点全部 `up==0`
（kps 默认开启 kubeProxy 抓取，新版 kube-proxy 默认不暴露 10249）。
不修的代价：每 6 小时一封 warning 邮件，且常驻告警会稀释真告警。二选一：

- **推荐**：kps values 加 `kubeProxy: {enabled: false}` → `helm upgrade`
  （改动小，可先本地 `helm template` 验证；改完 `ScrapeTargetDown` / `KubeProxyDown` 自动消失）
- 或给 kube-proxy 打开指标：改 3 个节点的 config 并重启静态 Pod，动静大，不建议

### 这轮新增的文件

| 文件 | 用途 |
|---|---|
| `docs/alerting.md` | S4 完整手册（部署 5 步 / 时间预算 / 链路分段排障 / 踩坑表） |
| `scripts/deploy-task7.sh` | 一键部署 + 4 项当场验收（幂等，Secret 交互式输入不进历史） |
| `scripts/alert-drill.sh` | 演练：自动时间线 + 逐通道投递判定 + 投递时刻采样；`--report` 只读回填 |
| `scripts/diag-task7.sh` | 7 段一次取证的只读诊断（含绕过 Prometheus 的端到端注入测试） |
| `scripts/validate-crd-fields.py` | 用**集群真实 CRD** 校验清单字段（防「字段被静默裁剪」） |
| `manifests/alerts/*` | 告警规则 8 条 / AlertmanagerConfig / 钉钉转发清单 / 配置模板 |

### 本机环境变化（比本文档旧版描述重要）

- 本地代理 `127.0.0.1:7897` **已失效**；**直连正常**（用环境自带代理变量，别加 `-x`）
- **GitHub release 资产下载不通**（302 后超时）；二进制走非 GitHub 官方源（helm → `get.helm.sh`）
- 本机 SSH 到 ECS **需密码**（无免密钥）；AI 可用 paramiko 直连执行命令；
  浏览器无头截图必须加 `--no-proxy-server`（否则系统代理把 127.0.0.1 拦掉）
- 单条命令跑超过约 60 秒可能被工具链中断，长任务放后台执行

### 给下一任的开场提示（新会话直接把这段粘贴给 AI 即可）

> 我在接着做 k8s-sre-platform 求职作品集项目（仓库在 `E:/yes/k8s-sre-platform`）。
> 请先通读 `docs/HANDOFF.md`——尤其「零、上一轮会话交接摘要」和第五节踩坑表，
> 然后从**任务 8**（metrics-server + HPA + hey 压测）开始。任务 7 已完整收尾，
> 手册在 `docs/alerting.md`。动手前先提醒我两件事：① 有一个待拍板的遗留问题
> （kube-proxy 抓取目标全挂，见 HANDOFF 零节）；② 按项目约定，helm values 必须先本地
> `helm template` 验证、自定义资源必须先过 `scripts/validate-crd-fields.py`。

---

## 一、这个项目是什么

**一句话**：在阿里云 3 台 ECS 上用 kubeadm 手搭一个生产级 Kubernetes 集群，跑一套微服务，
配上完整的可观测性与告警，再做故障演练——**作为云计算运维 / SRE 岗位的求职作品集**。

**定位原则（重要，决定很多技术取舍）**：
- 不写业务代码，业务负载直接用 Google 官方的 [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo)（12 个微服务电商）
- 所有过程留证（截图 / 录屏 / 踩坑记录）都是**面试素材**，比配置本身值钱
- 每个踩坑都要能讲出「现象 → 排查 → 根因 → 修复」的完整故事

---

## 二、当前进度（截至 2026-09-13）

| 任务 | 内容 | 状态 |
|---|---|---|
| 0 | 仓库脚手架、脚本、文档 | ✅ |
| 1 | ECS 购买、系统初始化（主机名/hosts/swap/chrony） | ✅ |
| 2 | containerd + kubeadm（cgroup 驱动、镜像源、锁版本） | ✅ |
| 3 | 集群组建（init + Calico + worker join + 三节点 Ready） | ✅ |
| 4 | Online Boutique 上线（22 Pod、副本 2、反亲和） | ✅ |
| 5 | Traefik Ingress + NodePort 暴露（30080/30443/30800） | ✅ |
| 6 | 可观测性（kube-prometheus-stack + Loki + Promtail + 自建看板） | ✅ |
| **7** | **告警规则与双通道触达（邮箱 + 钉钉）** | 🟩 **已完成并收尾**：双通道投递 **T+74s**（验收线 120s），时间线见 `docs/alerting.md` §4，截图 13-16 齐全 |
| 8 | metrics-server + HPA 自动扩缩容 + hey 压测 | ⬜ |
| 9 | 故障演练（drain 优雅排水 / 硬宕机） | ⬜ |
| 10 | README 收口 + 简历定稿 | ⬜ |

详细计划见 `docs/superpowers/plans/2026-09-12-k8s-job-project.md`（上一级仓库 `E:\yes\docs\`）。

---

## 三、环境与基础设施

### 3.1 集群

| 节点 | 内网 IP | 角色 |
|---|---|---|
| k8s-cp | 172.18.240.99 | control-plane（公网 IP：`8.155.129.89`） |
| k8s-w1 | 172.18.240.100 | worker |
| k8s-w2 | 172.18.240.101 | worker |

- OS：Ubuntu 22.04.5 LTS，内核 5.15.0-190
- K8s：**v1.31.14**（apt 安装，`apt-mark hold` 已锁版本）
- 运行时：**containerd 2.2.1**（注意是 2.x，配置格式与 1.x 不同，见 §5）
- CNI：Calico v3.28.0（operator 方式，**VXLAN 全封装**，`--pod-network-cidr=192.168.0.0/16`）

### 3.2 部署清单（release 名 / 命名空间 / 端口）

| 组件 | Helm release 名 | 命名空间 | 访问入口 |
|---|---|---|---|
| 监控全家桶 | `kube-prometheus-stack`（chart 90.1.1） | `monitoring` | Grafana NodePort **30300** |
| 日志 | `loki`（chart 7.3.0，singleBinary） | `monitoring` | `loki.monitoring:3100` |
| 日志采集 | `promtail`（chart 6.17.1，DaemonSet） | `monitoring` | — |
| 入口 | `traefik`（chart 41.5.0，Traefik v3.7.13） | `traefik` | 30080 / 30443 / 30800(dashboard) |
| 业务 | 非 Helm，直接 apply | `boutique` | `http://8.155.129.89:30080` |

> ⚠️ **release 名就叫 `kube-prometheus-stack`**，所以所有资源名都是
> `kube-prometheus-stack-grafana`、`kube-prometheus-stack-prometheus-0` 这种长名字。
> 网上教程里常见的 `kps-*` / `monitoring-*` 前缀都对不上，别照抄。

### 3.3 凭据

| 凭据 | 位置 |
|---|---|
| Grafana 管理员 | `kubectl -n monitoring get secret grafana-admin`（创建时用 `--from-literal` 注入，密码不在 git 里） |
| kubeconfig | cp 节点 `/etc/kubernetes/admin.conf` |
| 邮箱 SMTP 授权码 / 钉钉 secret | ✅ 已获取并在本机验证可用。**明文只在本机 `downloads/secrets/dingtalk-config.yml`（已被 .gitignore 忽略）与集群 Secret 里**；仓库内任何文件都不含明文凭据 |

### 3.4 安全组（阿里云控制台）

已放行：22 / 30080 / 30443 / 30800 / 30300。
**6443 刻意不暴露公网**——远程管理集群用 SSH 隧道：

```bash
ssh -N -L 6443:127.0.0.1:6443 root@8.155.129.89   # 本机终端 A 保持不关
kubectl get nodes                                  # 本机终端 B（kubeconfig 的 server 指向 127.0.0.1:6443）
```

### 3.5 接手后先跑一遍健康检查

```bash
# 在 cp 上
kubectl get nodes -o wide                        # 三台 Ready
kubectl get pods -A                              # 全绿（个别 completed 的 Job 除外）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:30080/    # 200
# 浏览器
#   http://8.155.129.89:30080    商店页面
#   http://8.155.129.89:30300    Grafana（Dashboards → Online Boutique 业务总览）
```

---

## 四、仓库结构与关键文件

仓库位置：`E:\yes\k8s-sre-platform`（本地 git，**尚未 push 到 GitHub**，账号 `hzl1314-a`）

```
k8s-sre-platform/
├── docs/
│   ├── setup-cluster.md          # 任务 1-5 完整手册（含 8 条踩坑记录表，必读）
│   ├── alerting.md               # ★ 任务 7 完整手册（告警双通道：步骤/时间预算/排障/面试要点）
│   ├── chaos-drill.md            # 任务 9 演练模板（预写好步骤）
│   ├── HANDOFF.md                # 本文档
│   └── screenshots/              # 留证截图 + README.md 索引（编号跨阶段不重号）
├── manifests/
│   ├── boutique/                 # 业务清单（已改造：镜像源/副本/反亲和），apply 顺序见目录内 README
│   ├── ingress/                  # traefik-values.yaml + boutique-ingress.yaml
│   ├── alerts/                   # ★ 任务 7 直接用：告警规则 + Alertmanager 路由 + 钉钉转发组件
│   ├── hpa/                      # ★ 任务 8 直接用：frontend HPA（min2/max8/CPU60%）
│   └── monitoring/               # ★ Grafana 看板 ConfigMap（JSON 生成，勿手改 yaml）
├── monitoring/                   # 三个 helm values（kps / loki / promtail）
├── scripts/                      # 幂等脚本（00 系统初始化 / 10 装运行时 / check-images / alert-drill / validate-crd-fields）
└── downloads/                    # 已下载的 chart、helm 二进制、metrics-server 清单（多数被 gitignore）
```

**三条仓库约定**（违反会出问题）：
1. **helm values 一律先本地渲染再上云**：`helm template ... -f values.yaml`，用
   `downloads/helm-win/windows-amd64/helm.exe`。chart 大版本升级常有字段静默失效。
2. **产物不改手**：Grafana 看板改 `manifests/monitoring/boutique-overview-dashboard.json`
   后跑 `scripts/gen-dashboard-configmap.py` 重新生成 yaml。
3. **截图编号跨阶段线性不重号**，见 `docs/screenshots/README.md`（01-19 已规划完）。

---

## 五、必读：踩过的坑（防止你再踩一遍）

以下每一条都真实踩过、有完整排查记录，**细节版在 `docs/setup-cluster.md` 的踩坑记录表**。

### 5.1 集群底座类

| # | 坑 | 一句话结论 |
|---|---|---|
| 1 | 阿里云 K8s apt 源地址失效 | 用 `kubernetes-new/core:/stable:/v1.31/deb/` 路径，旧路径 404 |
| 2 | `--kubernetes-version` 写死 | 必须 `$(kubeadm version -o short)`，否则去拉不存在的镜像 tag |
| 3 | containerd 2.x 配置格式变了 | 段名是 `io.containerd.cri.v1.images`，空值序列化成**单引号** `''`；2.x 默认 `config_path` 就是 certs.d |
| 4 | cri-tools 装不上 | 它在 K8s apt 源里，**必须先配源再装** |
| 5 | `conntrack` 等 preflight 依赖 | init 和 join 都会查；装 `conntrack socat ipset ethtool` |
| 6 | **sandbox(pause) 镜像没换源** | 症状：kubelet healthy 但所有 Pod 卡 `RunPodSandbox`。`--image-repository` **管不到** sandbox 镜像，必须改 containerd config 里的 `sandbox` 字段并重启 containerd |
| 7 | **Calico BGP 在云上不通** | 症状：Pod 全 Running 但跨节点服务调不通（同节点通）。原因是 `VXLANCrossSubnet` 在同子网时走 BGP，而阿里云 VPC 不转发 BGP。修复：ippool 的 `encapsulation` 改 `VXLAN` |
| 8 | 数据面验证方法论 | 「同节点通、跨节点不通 = 节点间路由缺失」；分层测试（Pod IP / Service IP / DNS）定位 |

### 5.2 镜像源类（大陆 ECS 特有）

| # | 结论 |
|---|---|
| 1 | **按 registry 分源，不能一刀切**：`quay.io→quay.m.daocloud.io`（快）、`registry.k8s.io→k8s.m.daocloud.io`、控制面镜像→`registry.cn-hangzhou.aliyuncs.com/google_containers`、**Docker Hub→`docker.1ms.run`**（DaoCloud 的 docker 系拉 437MB 要 20 分钟，已弃用） |
| 2 | **判镜像可用性不能只看 401**（那只是认证挑战），要走「取 token → 带 token 请求 manifest」看真实 200/404。工具：`scripts/check-images.sh` |
| 3 | **Traefik 流量级指标按需注册**：无流量时 `traefik_service_*` 指标族根本不存在，「配了却查不到」先造流量再查 |
| 4 | **不要用本机网络给 ECS 测速**：本机 2.8KB/s 的源，ECS 上能跑 5MB/s |

### 5.3 可观测性类

| # | 坑 | 结论 |
|---|---|---|
| 1 | chart 90.x 移除了 `grafana.adminPassword` | 改用 `grafana.admin.existingSecret` 指向自建 Secret |
| 2 | Traefik chart 28→41 字段静默失效 | `service.type` → `service.spec.type`；`logs` → `log` + `accessLog`。不生效**不报错**，只能渲染后核对 |
| 3 | ServiceMonitor CRD 依赖顺序 | Traefik 的 ServiceMonitor 必须等 kps 装完才能开（否则 helm 报 `monitoring.coreos.com/v1` 缺失）。当前已开 |
| 4 | **Loki 挂载陷阱** | chart 只在 `persistence.enabled=true` 时才挂 `/var/loki`；容器是非 root（uid 10001），不挂就 CrashLoop。我们用 `singleBinary.extraVolumes` 手工挂了 emptyDir |
| 5 | Loki 保留策略 | `retention_period` 单独写不生效，必须配套 `compactor.retention_enabled: true` + `delete_request_store` |
| 6 | **指标标签被改名 `exported_service`** | 抓取目标自带 `service` 标签冲突时，`honor_labels=false` 会给指标标签加 `exported_` 前缀。**看板查询必须用 `exported_service`** |
| 7 | PromQL 无序列返回空 | 零 5xx 时 `code=~"5.."` 匹配不到序列 → 显示 No data 而非 0%。惯用法：`or 0 * 总量` |
| 8 | **Grafana provisioning 只在启动时应用** | 数据源 ConfigMap 后续变更必须 `kubectl rollout restart deployment` 才生效 |
| 9 | **values 里的键名不存在时 helm 不报错** | `defaultRules.rules` 只接受**规则文件名**键（general / kubernetesResources / node …）。曾写的 `infoInhibitor` / `watchdog` / `KubeMemoryOvercommit` / `KubeCPUOvercommit` / `CPUThrottlingHigh` 全是死配置，静默忽略。改 values 前先在 chart 包里 `grep` 一下键名 |
| 10 | **apply 完立刻断言「没生效」必然误报** | Operator 写规则文件 + config-reloader 触发 reload + Prometheus 重读，官方预期**最长 1 分钟**；生成 Alertmanager 配置同理。校验脚本必须轮询等待，不要 apply 后 sleep 5 就判定 |
| 11 | **要不要通知 ≠ 规则要不要触发** | 用 Alertmanager 的路由表达「谁该收到什么」，别去删规则。例：`severity = none` 的元告警（InfoInhibitor）在收口路由下会污染收件箱，正确做法是加一条 `→ receiver discard` 的路由（空接收器即官方支持的丢弃写法），而不是关掉整组规则（`general.rules` 里还有 TargetDown） |
| 12 | **AlertmanagerConfig 与告警不在同一命名空间 = 一条通知都发不出** | Operator 的 `alertmanagerConfigMatcherStrategy.type` **默认 `OnNamespace`**，会给 AlertmanagerConfig 里**每条路由**追加 `namespace = <配置所在命名空间>`（源码 `pkg/alertmanager/amcfg.go` 的 `namespaceEnforcer.processRoute`）。我们的配置在 `monitoring`、业务告警在 `boutique` → 业务告警全被丢到默认 `null` 接收器。**症状极迷惑**：Prometheus 里告警正常 FIRING、Alertmanager 也收到了，就是不发通知；唯一收到的那封邮件偏偏是 `monitoring` 命名空间的 InfoInhibitor。修法：values 里设 `alertmanagerConfigMatcherStrategy.type: OnNamespaceExceptForAlertmanagerNamespace`（本项目选它而非 `None`：配置住在 Alertmanager 自己的命名空间，该策略语义正是「身边的配置=集群级策略」，且保留了对其它命名空间的默认保护），然后 `helm upgrade` |
| 13 | **收件人界面只到分钟，算不出秒级 KPI**；且**别用 Alertmanager 日志取证**——`msg="Notify success"` 在「首次投递成功」时是 **Debug** 级别（`notify/retry_stage.go`：`if i <= 1 { l.Debug(...) } else { l.Info(...) }`），默认 `logLevel=info` 下 grep 整段日志**零命中** | 先在真机 grep 日志（无命中）→ 回头读上游源码确认级别 → 换成采样 `/metrics` | ① 邮箱/钉钉客户端都只显示到分钟；② 健康投递走日志的 Debug 分支 | `alert-drill.sh` 改为演练期间**每 2s 直连 Alertmanager `/metrics`** 采样 `alertmanager_notifications_total`，记录各通道首次自增时刻（精度 ±2s、与日志级别无关）；`--report` 复用采样文件 `alert-drill.log.samples` |
| 14 | **收尾/恢复路径宁可不动，也不能基于「读失败」做变更**：用 `${cur:-0}` 判副本数时，`kubectl` 读失败会让空值被当成 `0`，脚本于是在**正常集群上执行 scale、把副本数改成 2**；同理恢复目标写死 `--replicas=2` 时，基线是 3 副本的集群会被改坏 | 桩命令让 `kubectl get deploy` 返回空，观察收尾动作 | `${var:-0}` 把「读失败」与「真的是 0」混为一谈。演练脚本会改集群状态，这类路径只允许在**确认**之后才动作 | 判定改成 `[[ "$cur" == "0" ]]`；恢复目标改用读到的**演练前真实副本数**（`RESTORE_REPLICAS`），读不到才退回 2 并显式告警 |

### 5.4 工具使用类（给「人」的提醒）

| # | 坑 |
|---|---|
| 1 | **Grafana Explore 的 Builder 模式会改写粘贴的正则**（`.*` 变 `.A.`，报 parse error）。**查复杂表达式必须切 Code 模式** |
| 2 | Git Bash 下 `grep -c $'\r'` 判 CRLF 会误报，用 `od -c` 或 `file` |
| 3 | 粘贴长命令到 SSH 出现 `^[[200~` 前缀导致 command not found，重新手输即可 |
| 4 | Helm 渲染时的资源名取决于 **release 名**（本文档 §3.2），别照抄教程 |
| 5 | **本机出网通道变了（2026-09-13 实测）**：本地代理 `127.0.0.1:7897` 已不可用（连接被拒），但直连正常——`github.com` / `api.github.com` / `get.helm.sh` / `prometheus-community.github.io` 都返回 200。**不要再按旧笔记加 `-x http://127.0.0.1:7897`**，那会得到 000 |
| 6 | **GitHub 的 release 资产下不通**：`github.com/<org>/<repo>/releases/download/...` 会 302 到 `objects.githubusercontent.com`，本机 curl 返回 000（helm、kubeconform、prometheus 的 release 包都试过）。要下载二进制请走**非 GitHub 的官方源**（如 helm 用 `get.helm.sh`）；仓库源码/索引走 `api.github.com` 与 `raw` 之外的路径仍可用 |
| 7 | **Bash 工具里 coreutils 不在 PATH**：`ls` / `head` / `grep` / `wc` 一律 command not found。命令前加 `export PATH="/usr/bin:/bin:$PATH"` 即可恢复 |
| 8 | **Git Bash 的 `/tmp` 与 Windows 程序的 `/tmp` 不是同一个目录**：bash 里 `/tmp/x.yaml` 能被 bash 的 `ls` 看到，但 Windows 版 Python 会去找 `E:\tmp\x.yaml` 而报 FileNotFoundError。跨工具传文件请统一用 `E:\...` 绝对路径 |
| 9 | **自定义资源的字段错误不会报错**，会被 CRD **静默裁剪**。上手写任何 `PrometheusRule` / `AlertmanagerConfig` / `ServiceMonitor` 之前，先用 `scripts/validate-crd-fields.py` 过一遍（本地就能跑，见 `docs/alerting.md` §3 第 3 步） |
| 10 | **脚本被工具写成 CRLF → Linux 上解析期直接崩**。症状：`line 18: $'\r': command not found`、`: invalid option nameline 19: set: pipefail`、`syntax error near unexpected token \`$'in\r'\``。**不是第一行报错、也完全不像行尾符问题**，极易误判成脚本写坏了。Windows 侧一切正常（Git Bash 容忍 CRLF、`bash -n` 也过） | scp 前自检：`grep -lU $'\r' scripts/*.sh`；命中就 `sed -i 's/\r$//' <文件>`。注意 `.gitattributes` 只在 add/checkout 规范化，**挡不住工具往工作区写 CRLF**，而 scp 传的是工作区文件 |
| 11 | **读第三方 API 前先核对 OpenAPI**。实例：以为 Alertmanager 的 `/api/v2/status` 有 `configYAML`，实际**没有这个字段**，写它会静默拿到 `null`（不报错），导致验收项连续空转 | 正确路径是 `.config.original`。核对方式：读上游仓库的 `api/v2/openapi.yaml`，别按记忆写字段名 |
| 12 | **同一条消息里对同一个文件并发做多次编辑会丢掉改动**：本次给 `alert-drill.sh` 加参数时，同批的两处编辑只落盘了一处（工具回「成功」但文件里没有），直到桩测试报出 `REPORT: unbound variable` 才暴露 | 一次性用脚本改完 + 逐条断言，改完回读文件确认 | 每次编辑都基于同一份原始内容「读-改-写」，后写的覆盖先写的 | 同一文件的多处改动合并成**一次原子操作**（本仓库用 python 改写 + `assert s.count(old)==1`）。**不要相信「成功」提示，要回读验证** |

---

## 六、下一步怎么走

### 任务 7：告警双通道（✅ 2026-09-13 已完成并实测验收）

> ★ **执行手册：`docs/alerting.md`（S4 完整步骤，含时间预算表、排障分段定位、面试要点）**
> 交接文档这里只留摘要；手册内容已按两次真实演练逐条核对并修正。

**结果**：邮箱与钉钉两个通道均**实测投递成功**（截图 14/15/16 佐证），
验收 KPI「故障 → 触达」落在 120 秒线内。

**三次演练对比（本任务最有价值的一段证据）**：

| 观测点 | ① 17:24 | ② 20:00（修命名空间策略后） | ③ 20:39（修脚本后，定稿） |
|---|---|---|---|
| 告警 Pending | T+21s | T+9s | T+13s |
| **告警 Firing** | T+82s | T+70s | **T+73s** |
| 通道计数增量 | `email` 0→1，**`webhook` 0→0** ⚠️ | `email` +1、`webhook` +1 | `email` **+2**、`webhook` **+2** ✅ |
| 收件人实际结果 | 只收到一封 InfoInhibitor 噪声 | 各 2 条 | 邮件 20:40、钉钉 20:40；恢复 20:43 **两通道两条都到** |

> ③ 是「各 +2」而 ② 只有「+1」：Alertmanager 先标 Resolved、再**异步**投递恢复通知，
> 脚本旧版一检出 Resolved 就取数会漏掉恢复那条（取数竞态，已修）。

**第一次「一条通知都不发」的根因**（详见 §5.3 第 12 条）：
Operator 的 `alertmanagerConfigMatcherStrategy` **默认 `OnNamespace`**，会给
AlertmanagerConfig 的每条路由强制追加 `namespace = monitoring` → `boutique` 的业务告警
一条都匹配不上，全被丢到默认 `null` 接收器。
唯一收到的那封 InfoInhibitor 邮件恰好是 `monitoring` 命名空间的——**这条「奇怪的噪声」就是定位线索**。

**让本任务真正落地的三件事（都已进仓库）**：

1. `monitoring/kube-prometheus-stack-values.yaml` 设
   `alertmanagerConfigMatcherStrategy.type: OnNamespaceExceptForAlertmanagerNamespace`
   （保留默认保护、不用 `None`；改动已本地 `helm template` 验证字段确实落到 Alertmanager 对象上）
2. 清掉 values 里 5 个**死配置键**（chart 90.1.1 中不存在、helm 静默忽略），
   并在路由层加 `severity = none → receiver discard` 收口元告警
3. `scripts/alert-drill.sh` 补上**精确投递时刻**采集（见下）

**时间线与投递时刻怎么记（本次新加，往后不用再手工掐表）**：

```bash
bash ~/alert-drill.sh --hold 150     # 跑演练：自动记时间线 + 逐通道投递判定
bash ~/alert-drill.sh --report       # 只读回填：从 Alertmanager 日志取精确到秒的投递时刻
```

**为什么这两个界面都不能用来算秒**（详见 §5.3 第 13 条）：邮箱与钉钉桌面客户端
**都只显示到分钟**（实测 `20:40` / `20:43`）。脚本原先想读 Alertmanager 日志里的
`msg="Notify success"`，但那条日志在「首次投递成功」时是 **Debug** 级别、默认不打印，
真机 grep 零命中。现改为演练期间每 2s 直接采样 Alertmanager `/metrics`。

**剩余事项：无。** 13-16 四张截图已全部归档到 `docs/screenshots/`，
时间线与投递秒数已回填 `docs/alerting.md` §4 —— **任务 7 完整收尾**。

**最终实测（2026-09-13 21:04:38 注入，第四次演练）**：
`Pending +9s → Firing +70s → 邮件/钉钉投递 +74s → 恢复 +220s → 恢复通知 +222s → Resolved +250s`
通道计数 `email` 21→23、`webhook` 4→6，**两通道各 +2**。
时间线与投递秒数已回填 `docs/alerting.md` §4，可直接用于 README / 简历。

**投递时刻的取证方式改过一次（别按旧版理解）**：原设计读 Alertmanager 日志里的
`msg="Notify success"`，实测**取不到**——源码 `notify/retry_stage.go` 中
「首次投递成功」是 `Debug` 级别（`if i <= 1 { l.Debug(...) } else { l.Info(...) }`），
默认 `logLevel=info` 下**根本不打印**。现改为**每 2s 直连 Alertmanager `/metrics` 采样**
`alertmanager_notifications_total`，记录各通道首次自增的时刻 —— 精度 ±2s，
且与日志级别无关，采样落在 `alert-drill.log.samples`。

> ⚠️ **原交接内容有 4 处已修正，不要再按旧版执行**（详见手册 §6）：
> 1. 钉钉的 Helm chart 已从 prometheus-community **下架**，`helm install` 必然失败 → 改为自维护清单
> 2. 排查建议里的 `sum by (service)` → 必须用 `exported_service`（标签被改名，见 §5.3 第 6 条）
> 3. 邮箱配置里的 `headers.Subject` 字段跨版本 schema 不一致且属冗余 → 已删除
> 4. 转发组件**不暴露 `/metrics`**，不能挂 ServiceMonitor（会造成永久 `up=0` 并触发自检规则）


### 任务 8：HPA 与压测

1. metrics-server 清单已备好且已 patch：`downloads/metrics-server-components-patched.yaml`，
   镜像地址需按 §5.2 换源后 `kubectl apply`；验收 `kubectl top nodes` 有输出
2. `kubectl apply -f manifests/hpa/frontend-hpa.yaml`（min2/max8/CPU60%）
3. 本机装 hey 压测：`hey -z 5m -c 50 http://8.155.129.89:30080/`
4. 压测期间 `kubectl get hpa -n boutique -w` 记录扩容；看板「业务 QPS / Pod CPU」同屏录屏
5. 验收：完整记录「QPS↑ → CPU 超阈值 → 副本 2→N → 回落」全周期，截图 17-19

### 任务 9：故障演练（项目王牌）

按 `docs/chaos-drill.md` 逐步走：开探测脚本 `scripts/availability-probe.sh` + 录屏 →
`kubectl drain k8s-w1` 优雅排水 → 控制台关机 w2 硬宕机 → `uncordon` 恢复 → 写复盘。
截图用 `chaos-01~04` 前缀。

### 任务 10：README 收口 + 简历

把 `docs/screenshots/` 的证据、压测数据、演练时间线整合进根 README；简历四个 bullet 回填实测数字。

### 遗留问题清单

- [ ] `04-remote-kubectl.png` 未截（S1 欠账，做法见截图索引里的说明）
- [ ] **有 Pod 累计重启 2-3 次**，待查是否 OOMKilled：
      `kubectl get pods -n boutique -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason'`
      （若是 OOM 就调 limit，并写进踩坑记录——监控第一次跑就抓到真问题，是加分项）
- [ ] **kube-proxy 抓取目标全挂（待拍板，见零节）**：`ScrapeTargetDown` 常驻 FIRING，
      `up==0` 的是 3 个节点的 kube-proxy:10249；推荐 kps values 里
      `kubeProxy: {enabled: false}` 后 `helm upgrade`
- [ ] 仓库还没 push 到 GitHub

---

## 七、工作方式与约定（很重要）

这个项目是**人与 AI 协作**完成的，分工如下，建议延续：

| 环节 | 谁做 |
|---|---|
| 云控制台操作、SSH 执行、截图录屏 | **人** |
| 全部配置 / 脚本 / 文档 / manifests | AI 生成，人负责 scp + apply |
| 报错定位与修法 | AI（把报错原文贴给它） |
| 验收核对 | AI |

**给 AI 的使用提示**（都是实测教训）：
1. 复杂 Grafana 查询**必须在 Code 模式**下跑，Builder 模式会改写正则
2. 让 AI 给命令前，先告诉它 **release 名**和当前所处阶段
3. AI 改完配置会先本地渲染验证（helm template / YAML 校验）再给命令，**照它给的命令执行即可**
4. 卡住超过 10 分钟就把**报错原文**贴给 AI，别自己硬扛
5. 新会话开工时，把**零节末尾的「给下一任的开场提示」**整段复制给 AI——
   它包含了项目位置、该读什么、从哪开始、以及两条必须先说的约定

---

## 八、一页速查

```bash
# 环境健康
kubectl get nodes -o wide
kubectl get pods -A
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:30080/

# 看板 / 商店
http://8.155.129.89:30300     # Grafana（Dashboards → Online Boutique 业务总览）
http://8.155.129.89:30080     # 商店
http://8.155.129.89:30800/dashboard/   # Traefik dashboard

# 镜像换源速查
quay.io/x/y          -> quay.m.daocloud.io/x/y
registry.k8s.io/x/y  -> k8s.m.daocloud.io/x/y
docker.io/x/y        -> docker.1ms.run/x/y          # DaoCloud 的 docker 系很慢
gcr.io/...           -> gcr.m.daocloud.io/...

# 校验镜像在镜像站是否存在（不要只看 401）
bash scripts/check-images.sh docker.1ms.run grafana/loki:3.6.11

# 告警链路（任务 7，细节见 docs/alerting.md）
bash scripts/alert-drill.sh --hold 150            # 触发演练 + 自动记录时间线
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[]|select(.name|startswith("boutique"))|.name'
kubectl -n monitoring get secret | grep alertmanager   # 找 alertmanager-*-generated，看路由是否合并成功
kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=30   # 钉钉通道报错

# 上云前校验自定义资源字段（防 CRD 静默裁剪）
python3 scripts/validate-crd-fields.py \
  --crd <(kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o yaml) \
  --manifest manifests/alerts/alertmanager-config.yaml
```
