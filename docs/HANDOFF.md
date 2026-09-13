# k8s-sre-platform 交接文档

> **交接时间**：2026-09-13
> **交接人**：上一任工程师（与 AI 协作完成）
> **接收人**：下一任工程师
> **阅读时间**：约 15 分钟。读完本文档即可独立继续，不需要翻历史聊天记录。

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
| **7** | **告警规则与双通道触达（邮箱 + 钉钉）** | 🟨 **已上云；邮件通道通、钉钉待定位**（`docs/alerting.md`） |
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

---

## 六、下一步怎么走

### 任务 7：告警双通道（配置已就绪，只差两个凭据）

> ★ **执行手册：`docs/alerting.md`（S4 阶段完整步骤，含时间预算表、排障分段定位、面试要点）**
> 交接文档这里只留摘要；手册里的内容在 2026-09-13 已按实测逐条核对并修正。

**前置（✅ 2026-09-13 已完成）**：
1. QQ 邮箱 SMTP 授权码 —— 已获取，并在**本机验证 SMTP 登录成功**（465 隐式 TLS）
2. 钉钉机器人 webhook + 加签 secret —— 已获取，并在本机**实发一条消息，返回 `errcode:0`**

> 两个凭据只存在于**两处不会进 git 的地方**：本机 `downloads/secrets/dingtalk-config.yml`
> （命中 `.gitignore` 的 `downloads/*` 与 `dingtalk-config.yml` 两条规则，已用
> `git check-ignore -v` 验过）与集群内的 Secret。
> 想确认仓库里没有明文凭据：`git grep -n -I 'SEC3\|access_token=8bf' HEAD` 应无输出。

**执行（一条命令，或手工 5 步——手册里有逐条原理）**：
1. 本机上传 + 在 cp 上跑 `bash ~/deploy-task7.sh`
   （脚本逐步执行并**当场验收 4 项**：规则已加载 / 路由已合并 / 转发组件在跑 / Prometheus 认到 Alertmanager）
   scp 清单见 `docs/alerting.md` §3.5
2. 触发演练：`bash scripts/alert-drill.sh --hold 150`（自动记录时间线 + 各通道发送计数增量）
3. 留证：截图 13-16，时间线回填 `docs/alerting.md` §4

**验收**：故障到告警 ≤2 分钟（预计 95~110 秒，推理见手册 §3）。
**主验收告警是 `DeploymentReplicasUnavailable`（`for: 1m`）**，
不是 `IngressHighErrorRate`（它要 `for: 5m`，本次演练不会触发）。

> ⚠️ **原交接内容有 4 处已修正，不要再按旧版执行**（详见手册 §6）：
> 1. 钉钉的 Helm chart 已从 prometheus-community **下架**，`helm install` 必然失败 → 改为自维护清单
> 2. 排查建议里的 `sum by (service)` → 必须用 `exported_service`（标签被改名，见 §5.3 第 6 条）
> 3. 邮箱配置里的 `headers.Subject` 字段跨版本 schema 不一致且属冗余 → 已删除
> 4. 转发组件**不暴露 `/metrics`**，不能挂 ServiceMonitor（会造成永久 `up=0` 并触发自检规则）

**2026-09-13 17:24 首次演练实测**（`scripts/alert-drill.sh --hold 150`）：

| 时刻 | 事件 |
|---|---|
| T+0s | 注入故障（frontend 副本 → 0） |
| T+21s | 告警 Pending |
| **T+82s** | **告警 Firing**（已优于 120 秒验收线） |
| T+82s | Alertmanager 收到该告警 |
| T+232s | 恢复副本为 2 |
| T+262s | 告警 Resolved（距恢复 30 秒） |
| — | 通道发送计数：`email` 0→1，**`webhook`（钉钉）0→0** ⚠️ |

**卡点根因（已定位，见 §5.3 第 12 条）**：钉钉与邮件**都没收到主告警**，
原因是 Operator 的 `alertmanagerConfigMatcherStrategy` 默认 `OnNamespace`，
给我们 AlertmanagerConfig 的每条路由强制追加了 `namespace = monitoring`
→ `boutique` 的告警一条都匹配不上，全被丢到默认 `null` 接收器。
唯一收到的那封 InfoInhibitor 邮件恰好是 `monitoring` 命名空间的——这条「奇怪的噪声」正是定位线索。

**需要执行的一步（改 values + upgrade，云上操作由本人做）**：

```bash
# 本机
scp monitoring/kube-prometheus-stack-values.yaml root@8.155.129.89:~/
# cp 上（helm 若未装见 downloads/README.md）
helm upgrade kube-prometheus-stack ~/kube-prometheus-stack-90.1.1.tgz \
  -n monitoring -f ~/kube-prometheus-stack-values.yaml
```

顺带已修掉的两个问题（都会造成误判，详见 §5.3 第 9、10 条与 `docs/alerting.md` §6/§7）：
values 里 5 个**死配置键**（chart 90.1.1 中不存在，静默忽略）、
部署脚本验收 1/2 的**检查时机与方法**缺陷（apply 后立刻断言必然误报）。

**下一步**：upgrade 之后重跑

```bash
bash ~/alert-drill.sh --hold 150     # 看这次邮件与钉钉是否都到
bash ~/diag-task7.sh                 # 若还有问题，7 段一次取证（含绕过 Prometheus 的端到端注入）
```


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
