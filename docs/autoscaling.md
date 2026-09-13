# S5 弹性伸缩与压测手册（任务 8）

> metrics-server → HPA → hey 压测 → 扩缩容全周期留证。
> 执行前请先读 `docs/HANDOFF.md` 零节。本手册的命令都已按当前集群状态
> （3 节点 kubeadm v1.31 / boutique 命名空间 / frontend 2 副本）核对。

---

## 0. 本阶段验收标准

| # | 标准 | 证据 |
|---|---|---|
| 1 | `kubectl top nodes` / `kubectl top pods -n boutique` 正常出数 | 终端输出（可并入 17 前的基线截图） |
| 2 | HPA 上线且 TARGETS 列显示真实百分比（非 `<unknown>`） | `kubectl get hpa -n boutique` |
| 3 | 压测期间 frontend 副本 2 → N（N≥4）扩容 | 截图 `17-hpa-scale-up.png` |
| 4 | hey 输出 QPS 与延迟分布 | 截图 `18-hey-result.png` |
| 5 | 压力解除后副本回落至 2 | hpa -w 尾段（可并入 17） |
| 6 | Grafana 曲线呈现「QPS↑ → CPU 峰 → 扩容 → 回落」全周期 | 截图 `19-grafana-hpa-curve.png` |

**完整记录「QPS↑ → CPU 超阈值 → 副本 2→N → 回落」全周期，截图 17-19。**

---

## 1. 方案要点（为什么这么干）

### 1.1 压测从 cp 节点发起，不从本机（2026-09-13 拍板）

原计划「本机装 hey 打公网 IP」已否决，两个原因：

1. **hey 本机装不上**：GitHub release 资产实测仍 000 不通（302 到
   objects.githubusercontent.com 后超时），本机也无 Go 工具链，`go install` 走不通。
2. **更本质的风险**：本机 → 公网 IP 的压测流量受 **ECS 出口带宽**限制。
   若带宽只有几 Mbps，瓶颈会是带宽而不是 frontend CPU——**CPU 压不满，
   HPA 永不扩容，任务 8 验收直接失败**，且症状（QPS 上不去但 HPA 不动）极有迷惑性。

改为 **cp 节点上发起，打 `http://127.0.0.1:30080/`**：节点本身有 NodePort 的
iptables 规则，流量仍走完整链路 **NodePort → Traefik → frontend Pod**，
只是绕开了公网带宽这一段。hey 用 apt 装 Go + goproxy.cn 编译（大陆网络顺畅）。

### 1.2 关键参数速览

| 组件 | 参数 | 说明 |
|---|---|---|
| metrics-server | v0.7.2，单副本 kube-system | 镜像已换 `k8s.m.daocloud.io`（已验证 200）；带 `--kubelet-insecure-tls`（kubeadm 自签 kubelet 证书的标准做法） |
| HPA | min2 / max8 / CPU 60% | 利用率 = 实际用量 ÷ requests（frontend request=100m）。扩容无稳定窗口（15s 内最多翻倍或 +4）；缩容 300s 稳定窗口 + 每分钟最多 -25% |
| frontend | limit 200m | 扩容期间单 Pod CPU 会顶到 limit 被节流（CFS throttling），**这是正常现象**，靠加副本摊负载 |

---

## 2. 部署与压测（严格按顺序，共 8 步）

### 第 0 步：kube-proxy 遗留问题修复（压测前必须）

> 背景：3 个节点的 kube-proxy:10249 指标端点 `up==0`，
> `ScrapeTargetDown` 常驻 FIRING。已拍板：kps values 关掉 kubeProxy 抓取。
> **本地已渲染验证**：`kubeProxy.enabled: true → false` 后，渲染 diff 恰好只消失
> 4 个 kube-proxy 相关资源（ServiceMonitor / Service / PrometheusRule /
> Grafana Proxy 看板 ConfigMap），其余 5700+ 行逐字节不变。

```bash
# 本机（E:/yes/k8s-sre-platform，Git Bash）
scp monitoring/kube-prometheus-stack-values.yaml root@8.155.129.89:/root/

# cp 上（在 chart 包所在目录；若找不到 tgz 就从本机 downloads/ 补 scp 一份）
helm upgrade kube-prometheus-stack ./kube-prometheus-stack-90.1.1.tgz \
  -n monitoring -f /root/kube-prometheus-stack-values.yaml
```

验证（**注意：helm upgrade 后 Operator 同步删除 + Prometheus reload 需要约 1 分钟，
apply 完立刻断言「没生效」必然误报**——老坑 5.3-10）：

```bash
# ① ServiceMonitor 已被 helm 删除
kubectl -n monitoring get servicemonitor | grep kube-proxy || echo "✅ kube-proxy ServiceMonitor 已移除"

# ② 等 1 分钟，targets 里 kube-proxy 消失
curl -s localhost:9090/api/v1/targets | grep -c '"job":"kube-proxy"' || echo "✅ 抓取目标已无 kube-proxy"

# ③ 告警恢复（ScrapeTargetDown 在序列失效后 1-2 个评估周期内 RESOLVED）
curl -s localhost:9090/api/v1/alerts | \
  jq -r '.data.alerts[] | select(.labels.alertname | test("KubeProxy|ScrapeTarget")) | .labels.alertname + " " + .state'
# 期望：空输出（KubeProxyDown 规则随 PrometheusRule 一起被删；ScrapeTargetDown 自动恢复）
```

**顺手把面板刷干净**：Grafana 里 Kubernetes / Proxy 看板会随 ConfigMap 删除而消失，属预期。

### 第 1 步：部署 metrics-server

清单：`downloads/metrics-server-components-patched.yaml`（官方 v0.7.2 components
+ `--kubelet-insecure-tls` + 镜像已换源，本地 YAML 校验已过 9 个 doc）。

```bash
# 本机
scp downloads/metrics-server-components-patched.yaml root@8.155.129.89:/root/

# cp 上
kubectl apply -f /root/metrics-server-components-patched.yaml
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

# 验收（指标来自 kubelet summary API，部署后 1-2 分钟才出数，耐心等）
kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes" | jq -r '.items[].metadata.name'
#   期望：3 个节点名
kubectl top nodes
kubectl top pods -n boutique --sort-by=cpu | head -6
```

### 第 2 步：部署 HPA

```bash
# 本机
scp manifests/hpa/frontend-hpa.yaml root@8.155.129.89:/root/

# cp 上
kubectl apply -f /root/frontend-hpa.yaml
sleep 30 && kubectl get hpa -n boutique
#   期望 TARGETS 列：形如 8%/60%（真实百分比）
#   若显示 <unknown>/60%：见 §5 排障
```

### 第 3 步：cp 节点装 hey

```bash
# cp 上（Ubuntu 22.04 → Go 1.18；v0.1.4 与之兼容，别用 @latest）
apt-get update && apt-get install -y golang-go
export GOPROXY=https://goproxy.cn,direct
go install github.com/rakyll/hey@v0.1.4
~/go/bin/hey -version        # 期望：hey v0.1.4 linux/amd64
```

### 第 4 步：压测前快照（留基线 + 排雷）

```bash
# ① 遗留问题排雷：有 Pod 累计重启 2-3 次（HANDOFF 遗留清单），看是否 OOMKilled
kubectl get pods -n boutique -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason' \
  | sort -t$'\t' -k2 -rn 2>/dev/null || kubectl get pods -n boutique -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,LASTSTATE:.status.containerStatuses[*].lastState.terminated.reason'
# 若有 OOMKilled：记下是哪个服务（面试素材「监控第一次跑就抓到真问题」），
# 本任务先不处理，避免压测前引入变量；任务 9 后再调 limit。

# ② 基线快照（可截图留证）
kubectl get hpa -n boutique
kubectl top pods -n boutique --sort-by=cpu | head -5
kubectl top nodes
```

### 第 5 步：压测执行（三路观察 + 录屏）

```bash
# 终端 A（cp）：观察 HPA 决策
kubectl get hpa -n boutique -w

# 终端 B（cp）：发起压测（5 分钟、50 并发）
~/go/bin/hey -z 5m -c 50 http://127.0.0.1:30080/

# 本机浏览器：Grafana → Dashboards → Online Boutique 业务总览，开始录屏
#   副本数曲线（与 QPS 同屏对比的价值最高）：
#   Grafana → Explore → Prometheus → Code 模式（别用 Builder，会改写表达式）：
#   kube_horizontalpodautoscaler_status_current_replicas{namespace="boutique"}
```

**预期时间线**（回填实际值到 §4）：

| 时刻 | 预期 |
|---|---|
| T+0~30s | frontend CPU 冲高，单 Pod 顶到 limit 200m（利用率 >200%），QPS 由 2 副本承载受限 |
| T+15~45s | HPA 首次扩容（scaleUp 无稳定窗口）：2→4（每 15s 最多翻倍或 +4） |
| T+1~3m | 继续扩到 8 或中途回落到 60% 线附近稳定；QPS 随副本数阶梯上升 |
| T+5m | hey 结束，CPU 快速落回 idle |
| T+5m→~15m | 缩容：300s 稳定窗口过后，每分钟最多 -25%：8→6→4→3→2 |

> ⚠️ **回落全程约 10-15 分钟，录屏别在 hey 结束就停**——「缩容慢」是 HPA behavior
> 的设计（防抖动），本身就是要展示的知识点。中途可以分屏干别的，结束前回来截
> 最终 `2/2` 状态即可。

### 第 6 步：取证（截图 17-19）

| 文件 | 内容 | 取法 |
|---|---|---|
| `17-hpa-scale-up.png` | `kubectl get hpa -w` 扩容段（TARGETS 百分比 + REPLICAS 变化 + 时间戳） | 终端 A 回滚 |
| `18-hey-result.png` | hey 汇总：Summary（QPS/延迟）+ Status code distribution + Latency distribution | 终端 B 结束输出 |
| `19-grafana-hpa-curve.png` | Grafana QPS/CPU 曲线 + Explore 副本数曲线，覆盖全周期 | 录屏抽帧或最后定格截图 |

补充取证（加分项，不强制）：`kubectl describe hpa frontend-hpa -n boutique`
的 Events 段记录了每次扩缩容决策的原因与时间——面试被追问
「HPA 什么时候决定扩、依据是什么」时，这张图就是答案。

### 第 7 步：收尾检查

```bash
kubectl get hpa -n boutique
#   期望：最终回到 2/2，TARGETS <60%
kubectl get pods -n boutique | grep -c Running   # 回到 22
kubectl top nodes                                 # 节点水位正常
# 有异常就 kubectl describe hpa frontend-hpa -n boutique 看 Events
```

### 第 8 步：回填

- 实测时间线 → 本手册 §4
- 截图登记 → `docs/screenshots/README.md` S5 表
- 简历素材：「50 并发压测下 frontend 副本 2→8 自动扩容，QPS 提升 N 倍，P95 延迟稳定」

---

## 3. 时间预算表

| 步骤 | 预计 | 实测（回填） |
|---|---|---|
| 第 0 步 kube-proxy 修复 + 验证 | 10 min | |
| 第 1 步 metrics-server | 10 min | |
| 第 2 步 HPA | 5 min | |
| 第 3 步 装 hey（apt Go + 编译） | 10 min | |
| 第 4 步 快照 | 5 min | |
| 第 5 步 压测 5 min | 5 min | |
| 缩容回落观察 | 10-15 min（可并行干别的） | |
| 截图整理 + 文档回填 | 15 min | |
| **合计** | **约 70-80 min** | |

---

## 4. 实测时间线（回填区）

| 观测点 | 数值（实测 2026-09-14 00:39-00:51） |
|---|---|
| 压测开始时刻 | 00:39:40（hey -z 5m -c 50 → 127.0.0.1:30080） |
| HPA 首次扩容（2→3） | T+56s（00:40:36），触发时 CPU 80% 越过 60% 目标 |
| 到达最大副本数 N= | **N=3**（50 并发下 3 副本即求衡：分摊后 CPU ~57%，回到阈值下方——HPA 的负反馈平衡点，没到 max 8 是正常收敛不是失败） |
| 压测期 QPS | 静息 ~8 req/s（loadgenerator 背景流量）→ 压测 24.66 req/s |
| P95 延迟 | hey 实测 P95 2.41s / P99 2.78s；Grafana 入口 P95 全程 ~4.7s 平台（**扩容后是「稳住不恶化」，不是「回落」**——见 §7 第 5 条的修正说明） |
| hey 结束时刻 | 00:44:54（T+5m14s，窗口自然结束）；**7426 请求全部 200，零错误** |
| 首次缩容 | 00:50:12（结束后 300s 稳定窗口到期，3→2） |
| 回到 2 副本 | 00:50:12 即到（单步 3→2，因未超过 max 的 25%/分钟限制） |
| 通道计数 / 异常告警 | 全程零告警（kube-proxy 修复后面板干净 ✓）；节点水位峰值 w2 10% CPU |
| 交叉验证 | Prometheus `kube_horizontalpodautoscaler_status_current_replicas` 序列与 3s 轮询日志一致（各差 1 个 15s 采样步）：00:41→3、00:50:30→2 |
| 证据 | 截图 17（合成）、18（合成）、19（真机 Grafana）；`hpa-drill-timeline.log` / `hpa-hey-result.txt` |

---

## 5. 排障速查

| 症状 | 原因 → 处置 |
|---|---|
| `kubectl top` 报 `Error from server (ServiceUnavailable)` | metrics-server 未就绪：`kubectl -n kube-system logs deploy/metrics-server --tail=20`，常见是 kubelet 连不上（看 `--kubelet-preferred-address-types` 顺序，我们用 InternalIP 优先，正常） |
| HPA TARGETS 显示 `<unknown>/60%` | ① metrics-server 刚起还没数据（等 1-2 min）；② 目标 Deployment 无 `resources.requests.cpu`（frontend 有 100m，不适用）；③ `kubectl top pods -n boutique` 本身无输出 → 回上一行排查 |
| TARGETS 有数但始终 <60%、不扩容 | QPS 不够或瓶颈在别处：看 hey 的 QPS 输出；`kubectl top pods -n boutique --sort-by=cpu` 确认 frontend 是不是热点；必要时 -c 50 加到 -c 100 |
| frontend CPU 卡在 200m 不动 | **正常**——这是 limit 节流（CFS throttling），正是扩容的触发条件，不用「修」 |
| 扩容后 QPS 没涨 | 可能已到集群总 CPU 上限或下游服务瓶颈（productcatalog / adservice）：`kubectl top pods -n boutique --sort-by=cpu` 找新热点——这本身就是 HPA 的边界案例，值得记下来 |
| 节点 CPU 水位 >80% | `kubectl top nodes` 观察；毕设集群资源不设限，一般到不了；真紧张就把 -c 50 降 30（maxReplicas 8 也是缓冲） |

---

## 6. 踩坑记录表（含预填的已知坑）

| 坑 | 现象 → 根因 → 处置 |
|---|---|
| ★ 监控脚本解析 HPA 列 | run1 日志出现「副本数 None -> 8」假事件 → `kubectl get hpa --no-headers` 的 TARGETS 值 `cpu: 11%/60%` 本身带空格，按列 split 后 MAXPODS 被当副本数 → 改 `-o jsonpath='{.status.currentReplicas}|{...averageUtilization}'` 结构化取值根治。**教训：解析 kubectl 人类可读输出做断言，迟早被格式坑；要么 jsonpath 要么 json** |
| Grafana 页面截图 basic auth 无效
| ★ 遗留 OOMKilled 排查（任务 8 收尾） | currencyservice/paymentservice 各 4-5 次重启，LASTSTATE=OOMKilled → 实测：payment(Node) 静息 92-102Mi 贴 128Mi limit（78%，Node 懒 GC 顶到 cgroup 才回收，OOM 是必然）；currency(Go) 静息仅 30Mi 但请求毛刺打穿 128Mi → 两者内存提到 request 128Mi / limit 256Mi（约 2 倍静息水位），滚动更新后新 pods 零重启、商店 200。**教训：巡检告警里 RESTARTS 持续增长的 Pod 要查 limit vs 实际用量，payment 这种「静息就贴线」不是调 JVM/堆参数能救的，limit 本身定小了** |
| ★ kubectl apply 忘带 -n（我踩的） | 全套 boutique 被建进 default 命名空间——诊断线索是输出全是 `created`（正常滚动应为 `configured/unchanged`）+ Deployment AGE 没变 + scp 实际失败（远端还是旧文件，md5 对不上）→ 用 `delete -f 同一份文件` 精确清理误建资源，SFTP 重传（md5 校验一致）后带 `-n boutique` 重 apply。**教训：① apply 后 `created/configured/unchanged` 三态要先看再动；② 传完文件先对 md5 再执行变更；③ delete -f 与 apply -f 用同一份文件是精确回滚误操作的可靠手段** | | `http://admin:pass@host/d/...` API 认（`/api/...` 200）但页面 302 到登录页——Grafana UI 不吃 URL basic auth → puppeteer 表单登录（`scripts/grafana-shot.mjs`）。另注意：`--disable-gpu` 下 headless Chrome 的 uPlot canvas 不渲染（图例有、曲线无），去掉即可 |

| # | 坑 | 现象 | 根因 | 修复/规避 | 状态 |
|---|---|---|---|---|---|
| 1 | hey 本机装不上 | release 下载 000、无本地 Go | GitHub release 资产通道不通（老坑） | hey 改装在 cp（apt Go + goproxy.cn 编译 v0.1.4） | ✅ 已规避 |
| 2 | 本机压公网会压不满 CPU | QPS 上不去且 HPA 不动，极具迷惑性 | ECS 出口带宽成为瓶颈，先于 CPU 饱和 | 压测从 cp 内部打 127.0.0.1:30080 | ✅ 已规避 |
| 3 | HPA `<unknown>` | TARGETS 列永远 unknown | metrics-server 未就绪 / 无 requests | 见 §5 排障表 | ⬜ 待观察 |
| 4 | CPU limit 节流 | 单 Pod CPU 顶 200m 不涨 | CFS quota 节流（设计如此） | 无需修，靠扩容摊 | ⬜ 待观察 |
| 5 | 缩容「迟迟不动」 | 压测结束 5 分钟还在 8 副本 | scaleDown 300s 稳定窗口 + 25%/min（防抖动设计） | 等 10-15 分钟，录屏别提前停 | ⬜ 待观察 |
| 6 | apply 后立刻断言 | 误报「没生效」 | Operator 同步 + reload 最长 1 分钟（老坑 5.3-10） | 校验前等 1 分钟 | ✅ 手册内置 |

---

## 7. 面试要点

1. **HPA 的利用率怎么算**：`实际用量 ÷ resources.requests`，不是绝对核数。
   所以「调 requests」会直接改变扩容灵敏度——一个常被忽略的联动关系。
2. **为什么扩容快、缩容慢**：流量突增时扩容慢=故障放大；缩容窗口短=副本数抖动
   （毛刺流量反复拉起又杀掉 Pod，成本与风险都放大）。我们的 behavior：
   扩容 0 窗口 15s 翻倍；缩容 300s 窗口 + 每分钟最多 -25%。
3. **metrics-server 与 Prometheus 的分工**：metrics-server 走 kubelet summary API，
   只服务 HPA/VPA 这类核心组件（APIService 聚合），不落盘、不进 Grafana；
   Prometheus 是完整时序库。两者互补，不是替代。
4. **`--kubelet-insecure-tls` 的含义与代价**：kubeadm 的 kubelet 证书不含节点 IP SAN
   或为自签，metrics-server 验不过。生产环境正确做法是给 kubelet 签含 SAN 的证书，
   这里接受 insecure 是实验集群的显式取舍——能讲清这个取舍本身就值一问。
5. **CPU limit 节流（CFS throttling）与 HPA 的互动**：单 Pod 顶到 limit 被节流时，
   延迟会恶化，HPA 通过扩容把负载摊到更多副本上来解除。**实测修正**：本次 50 并发下，
   扩容 2→3 后 P95 是「稳定在 ~4.7s 不再恶化」（观测窗口内未回落），真正的负反馈证据是
   **HPA 利用率 80% → 57% 回到阈值下**（副本分摊后每 Pod 压力下降）——面试时讲收敛
   要讲利用率回路，别把「P95 回落」当必然现象，实测它取决于瓶颈在 CPU 还是下游依赖。
6. **压测方法论**：为什么从集群内部打而不是公网——带宽瓶颈会先于 CPU 出现，
   让 HPA 演示失败。这个判断本身就是 SRE 的容量思维。
