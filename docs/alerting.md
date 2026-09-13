# S4 告警双通道手册（任务 7）

> 覆盖实施计划**任务 7**，对应规格文档 S4 阶段。
> 目标：告警「配置正确」且「真的能送到人手上」——邮件 + 钉钉双通道，
> 从故障发生到收件人收到通知 **≤ 2 分钟**。
>
> **使用方式：** 命令按顺序执行，每条标注了「为什么」和「验收标准」。
> 执行中的报错记到文末「踩坑记录」表——那是面试素材。
>
> 与 `setup-cluster.md`（S1）分工一致：云上操作与截图由你执行，配置文件由 AI 产出。

---

## 0. 本阶段验收标准（先明确「做完」长什么样）

| # | 验收项 | 判定依据 | 留证 |
|---|---|---|---|
| 1 | 4 条业务告警规则被 Prometheus 加载 | Prometheus UI → Rules 能看到 `boutique.*` 三个组 | 截图 `13` |
| 2 | 告警能在 Prometheus 里变为 FIRING | `DeploymentReplicasUnavailable` 状态由 Pending → Firing | 截图 `13` |
| 3 | **邮件**收到告警，且故障→触达 ≤ 120 秒 | 邮箱里的告警邮件（含时间） | 截图 `14` |
| 4 | **钉钉**收到告警，且故障→触达 ≤ 120 秒 | 钉钉群机器人消息（含时间） | 截图 `15` |
| 5 | 恢复通知同样到达（闭环） | 恢复邮件 / 钉钉任一 | 截图 `16` |

> 第 3、4 条的**秒数**直接写进简历 bullet，所以时间必须可信、可复现——
> 这正是 `scripts/alert-drill.sh` 存在的意义（自动记录时间线，不靠掐表）。

---

## 1. 前置：两个凭据（只有你能拿）

### 1.1 QQ 邮箱 SMTP 授权码

1. 登录 QQ 邮箱网页版 → 设置 → 账户
2. 找到「IMAP/SMTP 服务」，点开启 → 按提示用手机发短信验证
3. 复制生成的**授权码**（形如一串小写字母）

> ⚠️ **必须是授权码，不是 QQ 登录密码**。这两个东西混用是最常见的失败原因，
> 现象是 Alertmanager 日志报 `535 Authentication failed`。
>
> ⚠️ **改 QQ 密码会让授权码失效**。所以「某天突然收不到告警邮件了」，
> 第一件要查的就是授权码是否还有效。

### 1.2 钉钉机器人 Webhook + 加签密钥

1. 钉钉群 → 群设置 → 智能群助手 → 添加机器人 → **自定义**（通过 Webhook 接入自定义服务）
2. 安全设置选 **加签**
3. 复制两样东西：
   - **Webhook 地址**：`https://oapi.dingtalk.com/robot/send?access_token=....`
   - **加签密钥**：`SEC` 开头的一长串

> ⚠️ **安全设置决定配置怎么写**，二选一不要混：
> - 选「加签」→ 配置里必须填 `secret`
> - 选「自定义关键词」→ 配置里**不要**填 `secret`，而是把关键词设成消息里一定会出现的词
>   （如 `告警`），否则钉钉返回 `errcode 310000`（签名校验失败/关键词不匹配）直接拒收。

---

## 2. 部署（严格按顺序，共 5 步）

### 第 1 步：邮箱授权码进 Secret

```bash
kubectl -n monitoring create secret generic alertmanager-email-secret \
  --from-literal=password='<你的QQ邮箱SMTP授权码>'
```

**为什么**：授权码是凭据，不能写进 `alertmanager-config.yaml`（那要进 git）。
路由配置只引用 Secret 的名字，配置文件本身可以安全入库。

**验收**：

```bash
kubectl -n monitoring get secret alertmanager-email-secret
# 输出里 DATA 应为 1
```

---

### 第 2 步：部署钉钉转发组件

Alertmanager 不认识钉钉的 JSON 格式与加签算法，中间需要一个转换器。

```bash
# 2.1 造配置（含 token 与加签 secret，**不要提交仓库**）
cp manifests/alerts/dingtalk-webhook-config.example.yml ~/dingtalk-config.yml
vim ~/dingtalk-config.yml        # 填 access_token 与 secret（两处 REPLACE/SEC_REPLACE）

# 2.2 存成 Secret
kubectl -n monitoring create secret generic dingtalk-webhook-config \
  --from-file=config.yml=$HOME/dingtalk-config.yml

# 2.3 起服务（Deployment + Service + PDB）
kubectl apply -f manifests/alerts/dingtalk-webhook.yaml
kubectl -n monitoring rollout status deploy/prometheus-webhook-dingtalk
```

> ⚠️ **不要用 `helm install prometheus-community/prometheus-webhook-dingtalk`**。
> 该 chart 已从 prometheus-community 仓库下架（实测：index.yaml 里没有它、
> charts 目录里没有它、历史 release 资产 404）。照抄旧教程必然报
> `Error: chart "prometheus-webhook-dingtalk" not found`。
> 本项目改为自维护清单，反而少一个 helm repo 依赖、版本更可控。
> 详见 §6 踩坑记录第 1 条。

> ⚠️ **不要给它加 ServiceMonitor**：该组件 v2.1.0 **不暴露 `/metrics`**
> （已核对上游源码，注册的路由只有 `/dingtalk`、`/-/healthy`、`/-/ready`）。
> 挂了会得到一个永久失败的抓取目标（`up=0`），反过来触发我们自己的
> `ScrapeTargetDown` 规则——自造误报。

**验收**：

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-webhook-dingtalk
# 期望：2 个 Pod 都 Running（READY 1/1）

# ★ 单独验证钉钉链路（重要：先证明这一段通，再往下走）
kubectl -n monitoring port-forward svc/prometheus-webhook-dingtalk 18060:8060 &
NOW=$(date -Iseconds); LATER=$(date -Iseconds -d '+5 min')
curl -s -X POST http://127.0.0.1:18060/dingtalk/webhook1/send \
  -H 'Content-Type: application/json' -d "{
    \"version\":\"4\",\"status\":\"firing\",\"receiver\":\"dingtalk\",
    \"groupLabels\":{\"alertname\":\"链路自测\"},
    \"commonLabels\":{\"alertname\":\"链路自测\",\"severity\":\"critical\"},
    \"commonAnnotations\":{\"summary\":\"这是一条钉钉链路自测消息，收到即说明转发组件与机器人配置正确\"},
    \"externalURL\":\"http://example.com\",
    \"alerts\":[{\"status\":\"firing\",
      \"labels\":{\"alertname\":\"链路自测\",\"severity\":\"critical\"},
      \"annotations\":{\"summary\":\"钉钉链路自测\"},
      \"startsAt\":\"$NOW\",\"endsAt\":\"$LATER\",
      \"generatorURL\":\"http://example.com\",\"fingerprint\":\"selftest\"}]}"
# 期望：钉钉群立刻收到消息。终端返回 body 里应有 "errcode":0
```

> 这一步的价值：把「钉钉通道」与「Prometheus 告警链路」**解耦验证**。
> 如果跳过它，等到演练失败时你分不清是告警没触发、路由没配对、还是钉钉配置错了。

---

### 第 3 步：应用告警规则与路由

```bash
# 3.1 上云前先本地校验字段（防 CRD 静默裁剪，见 §3）
python3 scripts/validate-crd-fields.py \
  --crd <(kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o yaml) \
  --manifest manifests/alerts/alertmanager-config.yaml

# 3.2 服务端 dry-run（最权威的一步，会真的用集群 CRD 校验）
kubectl apply --dry-run=server -f manifests/alerts/boutique-alert-rules.yaml
kubectl apply --dry-run=server -f manifests/alerts/alertmanager-config.yaml

# 3.3 正式应用
kubectl apply -f manifests/alerts/boutique-alert-rules.yaml
kubectl apply -f manifests/alerts/alertmanager-config.yaml
```

**验收（4 项，缺一不可）**：

```bash
# ① 规则被 Prometheus 加载了吗？
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules \
  | jq -r '.data.groups[] | select(.name|startswith("boutique")) | "\(.name): \(.rules|length) 条"'
# 期望（一共 7 条）：
#   boutique.node.rules: 2 条
#   boutique.pod.rules: 2 条
#   boutique.ingress.rules: 2 条
#   boutique.scrape.rules: 2 条
#   若为空：说明 ruleSelectorNilUsesHelmValues 没设成 false，规则被静默忽略

# ② Operator 把 AlertmanagerConfig 合并进最终配置了吗？（最关键的一项）
#    最终配置存在一个自动生成的 Secret 里，名字规律是 alertmanager-<Alertmanager CR 名>-generated。
#    不要凭猜写死名字，先查一下：
kubectl -n monitoring get secret | grep alertmanager
#   找到形如 alertmanager-kube-prometheus-stack-alertmanager-generated 的那个，再展开：
AM_GEN=$(kubectl -n monitoring get secret -o name | grep 'alertmanager.*generated' | head -1)
kubectl -n monitoring get "$AM_GEN" -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -60
# 期望看到 receiver 名带前缀，形如：
#   monitoring/boutique-alertmanager-config/email
#   monitoring/boutique-alertmanager-config/dingtalk
#   （Operator 会加 <命名空间>/<配置名>/ 前缀避免跨配置重名，配置内部写短名即可）
#
#   更省事的方式：Alertmanager UI → Status → Config，直接看渲染后的最终配置
#   （不用猜 Secret 名，推荐截图留证时用这个）

# ③ Alertmanager 的最终配置语法是否被接受？
kubectl -n monitoring logs deploy/kube-prometheus-stack-alertmanager | tail -30
# 期望：没有 "Loading configuration file failed" 之类报错

# ④ Prometheus 是否已把 Alertmanager 当成接收方？
curl -s localhost:9090/api/v1/alertmanagers | jq -r '.data.activeAlertmanagers[].url'
```

---

### 第 4 步：触发演练（自动记录时间线）

```bash
scp scripts/alert-drill.sh root@<k8s-cp公网IP>:~/
ssh root@<k8s-cp公网IP>
bash ~/alert-drill.sh --hold 150
```

脚本会自动：注入故障（`frontend` 副本 → 0）→ 轮询并记录 Pending / Firing /
Alertmanager 收到 / 恢复 各时刻 → 打印各通道发送计数增量 → 恢复副本 → 输出时间线表。

> 脚本内置**异常退出保护**：无论 Ctrl+C、超时还是报错退出，都会把 `frontend`
> 副本恢复成 2，不会因为演练中断而把集群留在「少一半容量」的状态。

**手工补两项**（脚本无法代劳，这是简历数字的来源）：

- 邮箱那封告警邮件的到达时间（右键 → 显示原始邮件，看 `Date` 头）
- 钉钉消息的发送时间（消息右下角时间戳，或钉钉群消息详情）

---

### 第 5 步：留证

按 `docs/screenshots/README.md` 的 S4 段采集 `13` ~ `16` 四张图，
并把时间线数字回填到 §4 的表格里。

---

## 3. 时间预算：哪条告警会触发、大概多少秒

这一步是**验收能不能过的关键**——不是所有规则都会在演练里触发。

### 谁会被触发

| 规则 | severity | 本次演练会触发吗 | 原因 |
|---|---|---|---|
| `DeploymentReplicasUnavailable` | critical | ✅ **会**，主验收对象 | `for: 1m`，故障后 1 分钟即 Firing |
| `IngressHighErrorRate` | critical | ❌ 通常不会 | 需要 `for: 5m` + 5 分钟速率窗口；本次只故障 150 秒 |
| `PodFrequentRestart` | warning | ❌ 不会 | 缩容不产生容器重启 |
| `NodeMemoryHigh` / `NodeNotReady` | warning/critical | ❌ 不会 | 与本次故障无关 |
| 默认规则集里的 `KubeDeploymentReplicasMismatch` | warning | ❌ 不会 | chart 默认 `for: 15m`，本次恢复得更快 |

> 想让 `IngressHighErrorRate` 也触发（证明多级告警都在工作），把 `--hold` 调到
> 400 秒以上即可。但留证会变复杂，建议单独再做一次，不要混在首批 4 张图里。

### 时间怎么算出来

| 环节 | 配置值 | 耗时 |
|---|---|---|
| 故障注入（`scale --replicas=0`） | — | T+0 |
| kube-state-metrics 采集到副本数归零 | `scrapeInterval: 15s` | T+0 ~ 15s |
| 规则求值，状态 Inactive → Pending | `evaluationInterval: 15s` | 累计 T+~30s |
| Pending → Firing（`for: 1m` 需持续满足） | 60s | 累计 T+~90s |
| Alertmanager 收到告警 | 立即 | 累计 T+~90s |
| groupWait 结束才真正发送（critical 子路由配 5s） | 5s | 累计 T+~95s |
| 邮件 SMTP 投递 / 钉钉 HTTP 往返 | 网络 | 累计 **T+95 ~ 110s** |

**结论：稳定落在 120 秒验收线内，但余量只有 10~25 秒。**

> 余量偏紧的三个来源，面试被追问时可以主动说：
> 1. `for: 1m` 是**业务要求**（避免指标抖动误报）与**响应速度**之间的取舍，
>    不是配置错误。要更快就把 `for` 调到 30s，代价是更容易误报。
> 2. `scrapeInterval/evaluationInterval` 都是 15s，最坏情况白等 30s。
>    生产环境可以给关键规则单独开更短的求值间隔。
> 3. 邮件通道本身的排队延迟不可控——这也是为什么要有钉钉这条**推**通道
>    做冗余：两条链路独立，哪条先到算哪条。

---

## 4. 时间线记录表（演练后回填）

**演练执行时间：** `待填`

| 时刻 | 事件 | 距故障 |
|---|---|---|
| T+0s | `kubectl scale deploy/frontend --replicas=0` | — |
| T+__s | 告警状态变为 Pending | __s |
| T+__s | 告警状态变为 **Firing** | __s |
| T+__s | Alertmanager 收到告警（`/api/v2/alerts` 可见） | __s |
| T+__s | **邮箱收到告警** | __s |
| T+__s | **钉钉收到告警** | __s |
| T+__s | 执行 `--replicas=2` 恢复 | __s |
| T+__s | 告警 Resolved | __s |
| T+__s | 收到恢复通知 | __s |

### 通道发送计数（脚本自动采集，证明两通道都真的发了）

| integration | 演练前累计 | 演练后累计 | 增量 |
|---|---|---|---|
| `email` | | | |
| `webhook`（钉钉经此发出） | | | |

> 这一格是**最硬的证据**：它证明的不是「Prometheus 显示已触发」，
> 而是「Alertmanager 真的把通知交付到了两个 integration」。

---

## 5. 排障：按链路分段定位

告警链路有 4 段，**任何一段断掉都表现为「收不到消息」**。按顺序往下走，不要跳：

```
Prometheus(规则求值) → Alertmanager(路由发送) → 转发组件(格式+加签) → 钉钉/邮箱
        ①                    ②                      ③                  ④
```

| 段 | 怎么查 | 典型症状 | 常见根因 |
|---|---|---|---|
| ① Prometheus | Prometheus UI → Alerts；`/api/v1/rules` | 规则列表里根本没有 `boutique.*` | `ruleSelectorNilUsesHelmValues` 不是 `false` → 规则被静默忽略 |
| ① Prometheus | 直接在 UI 里查规则表达式 | 表达式查出来是空的 | 指标名/标签写错（如把 `exported_service` 写成 `service`）；目标没被抓取 |
| ② Alertmanager | `kubectl -n monitoring logs deploy/kube-prometheus-stack-alertmanager` | 日志出现 `Loading configuration file failed` | 配置字段不被当前 Alertmanager 版本支持（如 `forceImplicitTLS` 需要 AM ≥ v0.31） |
| ② Alertmanager | 看 Operator 生成的 `alertmanager-*-generated` Secret（名字先用 `kubectl -n monitoring get secret \| grep alertmanager` 查） | 里面只有默认的 `null` receiver | AlertmanagerConfig 没被选中：`alertmanagerConfigSelector` 或 CR 的标签不对 |
| ② Alertmanager | UI → Status → Config | 有 receiver 但路由不匹配 | `matchers` 的 `severity` 值与规则里写的不一致 |
| ③ 转发组件 | `kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk` | `404` | URL 路径里的 target 名与配置里 `targets.<名>` 不一致 |
| ③ 转发组件 | 同上 | `errcode 310000` | 加签 secret 与机器人不匹配；或机器人安全设置是「关键词」却配了 `secret` |
| ④ 钉钉 | 用 §2 第 2 步的 curl 自测 | `errcode 300001` / `keywords not in content` | 机器人安全设置与消息内容不匹配 |
| ④ 邮箱 | `kubectl -n monitoring logs deploy/kube-prometheus-stack-alertmanager` | `535 Authentication failed` | 授权码错误或已失效（改过 QQ 密码） |
| ④ 邮箱 | 同上 | `530 Must issue a STARTTLS` / 握手超时 | 465 与 587 的选择问题，见 `alertmanager-config.yaml` 里的注释 |

### 不想等 Prometheus 求值？直接往 Alertmanager 灌一条测试告警

最快的路由验证方式（跳过 Prometheus，几秒见效）：

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &
NOW=$(date -Iseconds); LATER=$(date -Iseconds -d '+5 min')
curl -s -X POST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' -d "[{
  \"labels\":{\"alertname\":\"人工测试告警\",\"severity\":\"critical\",\"namespace\":\"boutique\"},
  \"annotations\":{\"summary\":\"人工灌入的测试告警，用于验证路由与通道\"},
  \"startsAt\":\"$NOW\",\"endsAt\":\"$LATER\"}]"
# 期望：约 5~10 秒后（critical 路由 groupWait 5s）邮件与钉钉同时收到
```

> 注意 `severity: critical` 才会走双通道；写成 `warning` 只会发邮件——
> 这本身就顺手验证了分级路由是对的。

---

## 6. 相对交接文档的修正（重要，别按旧版执行）

| # | 交接文档 / 旧计划怎么写的 | 实际情况 | 已改为 |
|---|---|---|---|
| 1 | `helm install prometheus-community/prometheus-webhook-dingtalk` | 该 chart **已下架**，命令必然失败 | 自维护清单 `manifests/alerts/dingtalk-webhook.yaml` |
| 2 | `IngressHighErrorRate` 的排查建议用 `sum by (service)` | 指标的服务名标签被改名成 `exported_service`，`sum by (service)` 只会得到空结果 | 改为 `sum by (exported_service)`，并在规则文件头部说明标签陷阱 |
| 3 | 邮箱 Config 里写了 `headers.Subject` | 该字段 schema 在 Operator 版本间变过（新版是 array、老版是 map），且设置的值就是 Alertmanager 默认行为，纯冗余 | 直接删掉该字段 |
| 4 | 未提及给转发组件挂 ServiceMonitor | 该组件不暴露 `/metrics`，挂了会造成永久 `up=0` | 不加 ServiceMonitor，改用 `alertmanager_notifications_failed_total` 从结果侧监控它 |

---

## 7. 踩坑记录（执行中补充）

> 面试素材。写法：现象（原文报错）→ 排查 → 根因 → 解决。

| # | 现象 | 排查过程 | 根因 | 解决 |
|---|---|---|---|---|
| 1 | `Error: chart "prometheus-webhook-dingtalk" not found in prometheus-community index` | ① `grep -i dingtalk` 仓库 index.yaml → 无任何命中；② GitHub API 列 `helm-charts/charts` 目录 → 该 chart 不在列表中；③ 探历史 release 资产 URL → 404 | prometheus-community 已下架该 chart；但上游**软件**仓库仍在维护（`timonwong/prometheus-webhook-dingtalk`，最新 v2.1.0） | 不再依赖 chart，改为自维护 Deployment/Service 清单，镜像走 `docker.1ms.run/timonwong/prometheus-webhook-dingtalk:v2.1.0`（已用 `scripts/check-images.sh` 走完整 token 流程验证 HTTP 200） |
| 2 | 看板/告警里 `sum by (service)` 查不出数据，但 Prometheus 里明明有这个指标 | 直接查指标原始标签 → 发现服务名在 `exported_service` 上 | Prometheus 抓取时注入的目标标签 `service` 与指标自带标签同名，`honor_labels=false` 时指标自身的标签被加 `exported_` 前缀 | 所有引用处改用 `exported_service`；这是**静默失效**（不报错、只返回空），已写进规则文件头部警示 |
| 3 | apply 的自定义资源「成功」但字段不生效 | 用集群真实 CRD 逐字段比对 | CRD 是结构化 schema，未知字段**不报错、直接裁剪** | 写 `scripts/validate-crd-fields.py`，上云前用 `kubectl get crd ... -o yaml` 导出的 CRD 校验清单 |
| 4 | | | | |

---

## 8. 面试要点自检（S4 完成后你应该能答出来）

1. **Prometheus 和 Alertmanager 为什么是两个组件？**
   Prometheus 只负责「求值判断」（无状态、可水平扩展）；Alertmanager 负责
   「去重、分组、抑制、静默、路由、发送重试」（有状态、需要持久化）。
   分开是为了让判断逻辑与通知策略各自独立演进——改通知对象不用动监控规则。

2. **为什么 critical 走双通道、warning 只走邮件？**
   告警治理的核心矛盾是「响应速度」vs「告警疲劳」。critical 要立刻把人叫醒，
   所以要推送到有声音提醒的钉钉；warning 是「需要知道但不用马上处理」，
   批量汇总进邮件即可。一刀切双通道的结果是所有人都开始无视告警。

3. **`groupWait` / `groupInterval` / `repeatInterval` 分别解决什么？**
   `groupWait`：首次通知前等多久攒同组告警（防一次故障刷几十条）；
   `groupInterval`：同组来了新告警时的追加间隔；
   `repeatInterval`：告警一直没恢复时的重复提醒间隔。

4. **怎么保证「监控自己挂了」时你还知道？**
   两层：① `ScrapeTargetDown` 盯抓取目标存活——exporter 挂了指标会
   **安静地消失**而不是报错，这是监控最危险的失效模式；
   ② `AlertmanagerNotificationFailures` 盯通知发送失败——告警发了但送不到人，
   是最难发现的一环。业内更彻底的方案是 deadman switch（一条永不停息的
   心跳告警，收不到反而说明管道断了），本项目把它列为可选升级项。

5. **告警从故障到到达 90 秒，这个时间能压缩吗？怎么压？**
   可以：缩短 `scrapeInterval`/`evaluationInterval`、把 `for` 从 1m 调到 30s、
   给关键路由配更短的 `groupWait`。但每一项都在拿**误报率**换**响应速度**——
   故障注入演练的价值就在于把这个取舍量化出来，而不是拍脑袋。
