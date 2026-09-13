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

## 2. 部署（严格按顺序，共 6 步）

> **最快路径**：本节第 0 步做完后，后面 1~5 步可以用一条命令代替——
> `bash ~/deploy-task7.sh`（脚本会逐步执行并**当场验收 4 项**，失败会指出查什么）。
> 下面仍然把每一步写清楚，因为它们是你排障时的定位依据；
> 出问题时不要跳过原理去瞎试。

### ⚠️ 首次部署前必做：修正 Alertmanager 的命名空间匹配策略

**不做这一步，后面所有工作都会「看起来成功、实际一条通知都发不出去」。**

Prometheus Operator 的 `alertmanagerConfigMatcherStrategy.type` **默认值是 `OnNamespace`**
（CRD 里写死的 `default: OnNamespace`）。它的作用是在生成配置时，给 AlertmanagerConfig 里的
**每一条路由**追加一个 `namespace = <该 AlertmanagerConfig 所在命名空间>` 的匹配条件
（源码：`pkg/alertmanager/amcfg.go` 的 `namespaceEnforcer.processRoute`）。

我们的 AlertmanagerConfig 在 `monitoring`，而业务告警的 `namespace` 是 `boutique`
→ 追加的 `namespace = monitoring` 让业务告警**一条都匹配不上我们的路由**
→ 全部落到 chart 默认根路由的 `null` 接收器上被静默丢弃。

**实测症状（2026-09-13 演练）**：告警在 Prometheus 里正常 FIRING、Alertmanager 也收到了，
**但邮件与钉钉一条都不发**；反而 `monitoring` 命名空间的 `InfoInhibitor` 噪声告警被发了邮件
（因为它恰好是 `namespace=monitoring`）——这个「奇怪的噪声」其实正是定位问题的线索。

修复（values 已配好，只需执行 upgrade）：

```bash
# 本机：把改好的 values 传上去
scp monitoring/kube-prometheus-stack-values.yaml root@<cp公网IP>:~/

# cp 上：upgrade（chart 包在 cp 上已有，见 downloads/README.md 的 helm 安装说明）
helm upgrade kube-prometheus-stack ~/kube-prometheus-stack-90.1.1.tgz \
  -n monitoring -f ~/kube-prometheus-stack-values.yaml

# 验证：Alertmanager 对象上出现了这个字段
kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager \
  -o jsonpath='{.spec.alertmanagerConfigMatcherStrategy.type}{"\n"}'
# 期望输出：OnNamespaceExceptForAlertmanagerNamespace
```

> **为什么选 `OnNamespaceExceptForAlertmanagerNamespace` 而不是 `None`**（面试可讲）：
> 我们的 AlertmanagerConfig 恰好住在 Alertmanager 自己的命名空间（`monitoring`），
> 这个策略的语义正是「放在我身边的配置 = 集群级策略」，所以本项目的路由覆盖全集群，
> 同时**保留**了「其它命名空间的 AlertmanagerConfig 仍受命名空间限制」这层默认保护。
> 选 `None` 能用，但等于把保护全关了，没有理由。
>
> 三种取值对比：`OnNamespace`（默认，只管自己命名空间）｜
> `OnNamespaceExceptForAlertmanagerNamespace`（本项目的选择）｜`None`（完全不加限制）。


### 第 0 步：先在本机验证两个凭据（强烈建议，能省一整轮返工）

**为什么值得单独做**：凭据是唯一「不是代码、只能靠试」的东西。
如果在集群里才发现写错，你会同时面对「告警没触发 / 路由没配对 / 钉钉配置错了」
三个可能性，排查成本高得多。而这两样**在本地就能验完**：

```bash
# ① 钉钉：按官方「加签」算法算签名并真发一条消息
#    返回 {"errcode":0,"errmsg":"ok"} 即说明 webhook + secret 这一对是对的
python3 - <<'PY'
import base64, hashlib, hmac, json, time, urllib.parse, urllib.request
WEBHOOK = "<你的 webhook 完整地址>"
SECRET  = "<你的加签密钥>"
ts = str(round(time.time() * 1000))
sign = urllib.parse.quote_plus(base64.b64encode(
    hmac.new(SECRET.encode(), "{}\n{}".format(ts, SECRET).encode(),
             hashlib.sha256).digest()))
req = urllib.request.Request(
    "{}&timestamp={}&sign={}".format(WEBHOOK, ts, sign),
    data=json.dumps({"msgtype": "text",
                     "text": {"content": "Prometheus 告警通道自测：收到即说明凭据正确"}}).encode(),
    headers={"Content-Type": "application/json"}, method="POST")
print(urllib.request.urlopen(req, timeout=20).read().decode())
PY

# ② QQ 邮箱：只测 SMTP 登录（不发信也能证明授权码有效）
python3 - <<'PY'
import smtplib, ssl
s = smtplib.SMTP_SSL("smtp.qq.com", 465, timeout=25, context=ssl.create_default_context())
s.login("<你的QQ邮箱>", "<SMTP授权码>")     # 失败会抛异常，内容里就写着原因
print("登录成功 → 授权码有效"); s.quit()
PY
```

> 其他机器人配置错误也会在这一步暴露，而且是**可读的错误码**：
> `310000` = 签名校验失败（secret 不对，或机器人安全设置不是「加签」）；
> `300001` / `keywords not in content` = 机器人设的是「关键词」模式但消息里没有那个词。

---

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

### 第 3.5 步（可选）：把 1~3 步交给脚本

上面三步手工做完全没问题，但步骤多、每步都要自己核对，容易漏。
`scripts/deploy-task7.sh` 把它们固化下来，并**当场验收 4 项**：

```bash
# 本机：把清单、钉钉配置、脚本送上 cp
ssh root@<cp公网IP> 'mkdir -p ~/task7'
scp manifests/alerts/dingtalk-webhook.yaml \
    manifests/alerts/boutique-alert-rules.yaml \
    manifests/alerts/alertmanager-config.yaml root@<cp公网IP>:~/task7/
scp downloads/secrets/dingtalk-config.yml root@<cp公网IP>:~/dingtalk-config.yml
scp scripts/deploy-task7.sh scripts/alert-drill.sh scripts/diag-task7.sh root@<cp公网IP>:~/

# cp 上：一条命令
bash ~/deploy-task7.sh
#   凭证用交互式输入（read -s，不回显、不进 shell 历史）
#   幂等，可重复执行；已存在的东西不会被重复创建
```

> ⚠️ **scp 之前先做一次行尾符自检**（2026-09-13 实测踩过，症状极具误导性）：
>
> ```bash
> grep -lU $'\r' scripts/*.sh \
>   && echo "↑ 上面这些是 CRLF，先修：sed -i 's/\r$//' <文件>" \
>   || echo "所有脚本均为 LF ✓"
> ```
>
> 本机是 Windows，某个工具（用 python 以文本模式改写文件）可能把脚本写成 CRLF。
> Git Bash 完全容忍 CRLF、本地 `bash -n` 也全过，但文件到 Linux 后 bash 在**解析阶段**就崩：
>
> ```
> /root/diag-task7.sh: line 18: $'\r': command not found
> : invalid option nameline 19: set: pipefail
> line 152: syntax error near unexpected token `$'in\r''
> ```
>
> **它不是从第一行报错、错误信息也完全不像行尾符问题**，很容易误判成脚本写坏了。
> 注意 `.gitattributes` 只在 git add/checkout 时规范化，**挡不住别的工具往工作区写 CRLF**
> ——而 scp 传的正是工作区那份文件，所以这个自检不能省。


脚本会打印 `通过 N 项，失败 M 项`。四项验收分别是：
① 规则被 Prometheus 加载了 ② Operator 把路由合并进最终配置了
③ 转发组件 Pod 在跑 ④ Prometheus 认到了 Alertmanager。

> 这个脚本本身被**用桩命令压测过**：成功路径与失败路径都跑通，
> 并且因此在交付前抓到一个 bug —— 变量名 `GROUPS` 撞上了 **bash 的内建变量**
> （它保存当前用户的组 ID），赋值后展开时被 shell 覆盖成一个莫名其妙的大数字，
> 会让验收结果报出假数据。改名为 `RULE_GROUPS` 后正常
> （同类要避开的还有 `SECONDS` / `RANDOM` / `UID` / `LINENO` / `PIPESTATUS` / `REPLY`）。
> 教训：**给别人用的脚本，自己先拿桩数据跑一遍**——这类 bug 手工 review 是看不出来的。

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

**演练执行时间：** 2026-09-13 21:04:38（Asia/Shanghai，cp 节点时区）
**脚本版本：** 采样版 `alert-drill.sh`（投递时刻用计数器采样，见 §4.0）
**结论：两通道投递均为 T+74s，远优于 120s 验收线 —— 本组数字可直接写简历。**

| 时刻 | 事件 | 距故障 | 证据 |
|---|---|---|---|
| T+0s（21:04:38） | `kubectl scale deploy/frontend --replicas=0` | — | `alert-drill.log` |
| T+9s（21:04:47） | 告警状态变为 Pending | **+9s** | `alert-drill.log` |
| T+70s（21:05:48） | 告警状态变为 **Firing** | **+70s** | `alert-drill.log` |
| T+70s（21:05:48） | Alertmanager 收到告警 | **+70s** | `alert-drill.log` |
| **T+74s（21:05:52）** | **邮件投递** | **+74s** ✅ | `[8/8]` 计数器采样 |
| **T+74s（21:05:52）** | **钉钉投递** | **+74s** ✅ | 同上 |
| T+220s（21:08:18） | 执行恢复（`--replicas=2`） | +220s | `alert-drill.log` |
| T+222s（21:08:20） | 恢复通知投递（邮件 + 钉钉各一条） | **+222s** | `[8/8]` 计数器采样 |
| T+250s（21:08:48） | 告警 Resolved | +250s（距恢复 30s） | `alert-drill.log` |

> 时间分解（面试被追问时直接用）：+70s 里含规则 `for: 1m` + 求值周期，
> +70s → +74s 是 Alertmanager 的 `groupWait: 5s` + 采样精度 ±2s。
> 恢复通知在副本恢复后 2 秒即发出，闭环同样快。

### 通道投递计数（证明两通道都真的发了）

| integration | 演练前累计 | 演练后累计 | 增量 |
|---|---|---|---|
| `email` | 21 | 23 | **+2** ✅ |
| `webhook`（钉钉经此发出） | 4 | 6 | **+2** ✅ |

> 这两格是**最硬的证据**：它证明的不是「Prometheus 显示已触发」，
> 而是「Alertmanager 真的把通知交付到了两个 integration」。
>
> **两个通道都是 +2**（告警 1 条 + 恢复 1 条），这才是正常形态。
> 早先有一次只读到 +1，是脚本的取数竞态（见 §4.3 第 1 条），不是通道故障。

### 4.0 把投递时刻精确到秒：一条只读命令

**收件人界面不能当秒级证据**——这是实测踩到的，不是推测：

- 邮箱客户端只把时间显示到**分钟**（`20:40`），没有秒；
- 钉钉桌面客户端同样**只到分钟**（实测两条消息显示 `20:40` / `20:43`）。

那为什么不用 Alertmanager 的日志行？——**首次投递成功是 Debug 级别，默认不打印**
（源码 `notify/retry_stage.go`：`if i <= 1 { l.Debug("Notify success", ...) } else { l.Info(...) }`，
健康投递走 Debug 分支，`logLevel=info` 下 grep 整段日志零命中，2026-09-13 真机上已踩）。

所以脚本改成**自己采样 Alertmanager 的 `/metrics`**：演练期间每 2 秒直连它的端口
取 `alertmanager_notifications_total`，记录每个通道第一次自增的时刻。
精度 = 采样间隔（2s），且**与日志级别无关**。采样落在 `alert-drill.log.samples`。
一条只读命令就能复算（**不注入故障、不改集群任何状态**）：

```bash
bash ~/alert-drill.sh --report
# 想回填别的场次：bash ~/alert-drill.sh --report --out <日志文件>
```

输出（2026-09-13 21:04 那场的真实输出）：

```
 时间基准 : 2026-09-13T21:04:38+08:00
 采样文件 : alert-drill.log.samples
      时刻    通道   距故障 事件
      21:05:52 email    +74      告警投递
      21:08:20 email    +222     恢复投递
      21:05:52 webhook  +74      告警投递
      21:08:20 webhook  +222     恢复投递
```

取 `email` 与 `webhook` 各自 **「告警投递」** 那一行的 `+Ns`，就是
「故障 → 该通道投递成功」的秒数（验收线 ≤120s），直接填进上表。
采样文件会一直留着，随时可重算；但它由演练期间的后台采样产生，
**没跑过演练就没有**（会明确提示重跑）。

### 4.1 每个数字从哪里取（可复现，别凭印象填）

演练脚本已经把这些都写进 `alert-drill.log` 了。逐项对应：

| 要记录的东西 | 取值来源 | 命令 / 方法 |
|---|---|---|
| 故障注入时刻（**基准点**） | `alert-drill.log` | `grep fault-injected alert-drill.log` |
| Pending 时刻 | `alert-drill.log` | `grep alert-pending alert-drill.log`（括号里已给出「距故障 N 秒」） |
| Firing 时刻 | `alert-drill.log` | `grep alert-firing alert-drill.log` |
| Alertmanager 收到时刻 | `alert-drill.log` | `grep alertmanager-received alert-drill.log` |
| 恢复操作时刻 | `alert-drill.log` | `grep fault-cleared alert-drill.log` |
| Resolved 时刻 | `alert-drill.log` | `grep alert-resolved alert-drill.log` |
| 各通道发送计数 | `alert-drill.log` / 脚本结尾 | `grep -A 30 '通道发送计数增量' alert-drill.log` |
| **邮件 / 钉钉投递时刻（权威）** | Alertmanager `/metrics` 采样 | `bash ~/alert-drill.sh --report`（见 4.0）。演练期间每 2s 采样 `alertmanager_notifications_total`，记录首次自增时刻 |
| 邮箱到达时刻（二次确认） | 邮箱 | 右键邮件 → 「显示原始邮件」→ `Date:` 头（**有秒**）。列表里的时间只到分钟 |
| 钉钉到达时刻（二次确认） | 钉钉 | 悬停消息看发送时间。⚠️ **只到分钟**（实测 20:40 / 20:43），不能用来算秒级 KPI |

算「距故障多少秒」：

```bash
# 三个时刻的时间戳都在 log 里，直接照抄脚本算好的 "距故障 +Ns" 即可；
# 若想自己核一遍（GNU date）：
echo $(( $(date -d '2026-09-13T17:24:53+08:00' +%s) - $(date -d '2026-09-13T17:24:11+08:00' +%s) ))
```

> **记录纪律**：只写实测值，不写推测值。运维岗面试最忌讳的就是
> 「大概一分多钟吧」——能被追问到秒的数字，比一个漂亮的区间更有说服力。
> 如果某一项确实没取到，就写「未取到」并注明原因，不要凑数。

### 4.2 截图与数字的对应关系（面试时能自证）

| 截图 | 里面能看到的数字 | 自证什么 |
|---|---|---|
| `13-alert-rule-fired.png` | Prometheus Alerts 页面的 FIRING 状态 | 告警确实触发了 |
| `14-alert-email.png` | 邮件时间戳 | 邮件到达时刻 ↔ 与 `alert-drill.log` 的 T_FAULT 相减 = 触达秒数 |
| `15-alert-dingtalk.png` | 钉钉消息时间戳 | 同上（第二条独立链路） |
| `16-alert-recovered.png` | 恢复通知时间戳 | 闭环成立 |

> 建议把 `alert-drill.log` 里那几行时间线**一起截进 14/15 的图里**（同一个画面内），
> 这样「90 秒」不是靠嘴说，而是图里就有「故障注入时刻」和「邮件到达时刻」两个锚点。

### 4.3 三个「看起来像故障」的正常现象（本次演练全部遇到）

第一次看到输出时，下面三条都很容易被误判成「通道坏了」。记下来能省一整轮排查：

| 现象 | 为什么不是故障 |
|---|---|
| **计数只 +1**（`email 17→18`、`webhook 0→1`），但邮箱和钉钉里各躺着 **2 条**消息 | **取数竞态**：Alertmanager 是「先标 Resolved、再**异步**投递恢复通知」。脚本旧版一检出 Resolved 就立刻取数，恢复那条还没发出去。新版改成「等两通道都出现增量 + 再等 15s 落定」，正常一次演练应各 **+2** |
| 钉钉/邮箱的时间只有分钟（`20:40`），看不出秒 | 收件人客户端就是只显示到分钟。要看秒级时刻，用 4.0 的 `--report` |
| **RESOLVED 卡片正文仍写着**「可用副本数为 0，用户请求将全部失败」 | Alertmanager 固有行为：通知里的 `annotations` 是**告警触发那次求值的快照**，恢复通知会原样带上。卡片标题与状态行（`[RESOLVED]` / `Alerts Resolved`）是状态自适应的——**看标题，不要看正文描述**。kube-prometheus 自带的官方规则行为完全一致 |

> 另：本次演练前 `email` 累计已经是 **17** 条，说明收口路由在把未分类告警
> （`severity` 不是 critical/warning 的那批）灌进邮箱。已加
> `severity = none → receiver discard` 收口（§6 第 5 条）。
> `severity=info` 的告警仍会进邮箱，这是**有意保留**的（它们属于「值得知道」且量小）。

---

## 5. 排障：按链路分段定位

告警链路有 4 段，**任何一段断掉都表现为「收不到消息」**。按顺序往下走，不要跳：

```
Prometheus(规则求值) → Alertmanager(路由发送) → 转发组件(格式+加签) → 钉钉/邮箱
        ①                    ②                      ③                  ④
```

### 先跑取证脚本，再动手查

```bash
scp scripts/diag-task7.sh root@<cp公网IP>:~/
ssh root@<cp公网IP> 'bash ~/diag-task7.sh'
```

它只读取证、不改任何东西，一次跑完 7 段并给出结论指向哪一段：

| 段 | 看什么 | 能直接回答的问题 |
|---|---|---|
| 2/7 | Alertmanager 的**生效配置**（`/api/v2/status`） | 我们的路由到底进没进去？receiver 实际叫什么？chart 的 inhibit_rules 还在不在？ |
| 3/7 | `notifications_total` **与** `notifications_failed_total` | 是「没发」还是「发了但失败」？失败原因是什么？ |
| 4/7 | 转发组件自测（直接 POST 一条） | 转发组件→钉钉这一段本身通不通？errcode 是多少？ |
| 5/7 | 两个组件的日志错误行 | 有没有网络/认证/拒收的痕迹 |
| 6/7 | Prometheus 规则加载情况 | 规则到底加载了没 |
| 7/7 | **端到端注入**（绕过 Prometheus 直接灌一条 critical 告警） | 路由+通道整体通不通？告警有没有被抑制（`inhibitedBy`）？ |

> **7/7 是信息量最大的一步**：它把「Prometheus 侧的问题」和「Alertmanager 侧的问题」
> 一刀切开。注入后两个通道都收到 → 说明路由与通道都是好的，问题在 Prometheus 的标签/规则侧；
> 只有邮件到 → 问题就在钉钉那条路由或接收器上。
> 注意它**会真的发出邮件与钉钉消息**，跑之前先确认这是你想要的。

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
| 5 | `monitoring/kube-prometheus-stack-values.yaml` 里写着 `infoInhibitor: false`、`watchdog: false`、`KubeMemoryOvercommit: false`、`KubeCPUOvercommit: false`、`CPUThrottlingHigh: false` | 这 5 个键在 chart 90.1.1 的 `defaultRules.rules` 里**根本不存在**（该段只接受规则文件名键），helm 不报错、静默忽略 | 删掉这 5 行；改为在路由层丢弃不该通知的告警（见下一条）。`CPUThrottlingHigh` 特意保留（任务 8 压测的有力证据） |
| 6 | 根路由是「收口通道」（所有未匹配告警都发邮件），导致 chart 自带的 `severity=none` 元告警（InfoInhibitor）也进了收件箱 | 见 §7 踩坑表第 7 条 | 增加 `severity = none → receiver discard` 路由；**不删规则**，因为 `general.rules` 里还住着 TargetDown |
| 7 | 未提及 Operator 的 `alertmanagerConfigMatcherStrategy` 默认值 | 默认 `OnNamespace` 会给 AlertmanagerConfig 里**每条路由**追加 `namespace = <配置所在命名空间>`；配置在 monitoring 而告警在 boutique → **一条通知都发不出去**（告警却在 Prometheus 里正常 FIRING） | `monitoring/kube-prometheus-stack-values.yaml` 里设 `alertmanagerConfigMatcherStrategy.type: OnNamespaceExceptForAlertmanagerNamespace`，并 `helm upgrade`。**这是首次部署前必做的一步**，见 §2 开头的说明块 |

---

## 7. 踩坑记录（执行中补充）

> 面试素材。写法：现象（原文报错）→ 排查 → 根因 → 解决。

| # | 现象 | 排查过程 | 根因 | 解决 |
|---|---|---|---|---|
| 1 | `Error: chart "prometheus-webhook-dingtalk" not found in prometheus-community index` | ① `grep -i dingtalk` 仓库 index.yaml → 无任何命中；② GitHub API 列 `helm-charts/charts` 目录 → 该 chart 不在列表中；③ 探历史 release 资产 URL → 404 | prometheus-community 已下架该 chart；但上游**软件**仓库仍在维护（`timonwong/prometheus-webhook-dingtalk`，最新 v2.1.0） | 不再依赖 chart，改为自维护 Deployment/Service 清单，镜像走 `docker.1ms.run/timonwong/prometheus-webhook-dingtalk:v2.1.0`（已用 `scripts/check-images.sh` 走完整 token 流程验证 HTTP 200） |
| 2 | 看板/告警里 `sum by (service)` 查不出数据，但 Prometheus 里明明有这个指标 | 直接查指标原始标签 → 发现服务名在 `exported_service` 上 | Prometheus 抓取时注入的目标标签 `service` 与指标自带标签同名，`honor_labels=false` 时指标自身的标签被加 `exported_` 前缀 | 所有引用处改用 `exported_service`；这是**静默失效**（不报错、只返回空），已写进规则文件头部警示 |
| 3 | apply 的自定义资源「成功」但字段不生效 | 用集群真实 CRD 逐字段比对 | CRD 是结构化 schema，未知字段**不报错、直接裁剪** | 写 `scripts/validate-crd-fields.py`，上云前用 `kubectl get crd ... -o yaml` 导出的 CRD 校验清单 |
| 4 | 部署脚本的验收项报出一个莫名其妙的大数字（如「已加载 197121 个规则组」） | 用桩命令跑脚本、`bash -x` 打印实际赋值，发现该变量被 shell 改写 | 变量名 `GROUPS` 撞上了 **bash 内建变量**（保存当前用户的组 ID），赋值后展开时被 shell 覆盖 | 改名 `RULE_GROUPS`；同类要避开 `SECONDS`/`RANDOM`/`UID`/`LINENO`/`PIPESTATUS`/`REPLY`。教训：**给别人的脚本要先拿桩数据自己跑一遍** |
| 5 | 「连上了没」判断不可靠：连接失败时 curl 仍可能返回 0，于是验收项误报为通过 | 故意让目标不可达，观察脚本判定结果 | 只看 curl 退出码不等于拿到了正确响应 | 就绪判断改为**校验返回内容的结构**（取回 JSON 后 `jq -e '.status == "success"'`），而不是只看退出码 |
| 6 | 邮件配置里的 `headers.Subject` | 与 CRD 的 `description` 对照 | 该字段 schema 跨 Operator 版本不一致，且其值是默认行为 | 直接删掉，见 §6 第 3 条 |
| 7 | 演练后邮箱里收到一封 `[FIRING:1] InfoInhibitor … severity=none` 的噪声邮件，真正该看的 `DeploymentReplicasUnavailable` 反而不显眼 | ① 查 chart 的 values：`defaultRules.rules` 段里**没有** `infoInhibitor` 键（只有规则文件名键）→ values 里那行 `infoInhibitor: false` 是死配置；② `grep -rl InfoInhibitor` 定位到它在 `general.rules` 里，与 **TargetDown** 同住一个文件；③ 读 chart 默认 `alertmanager.config`：它原先把 Watchdog 路由到 `null`，InfoInhibitor 则靠 inhibit_rules 压住——但**单独触发时没有别的告警能当抑制源**，于是落到我们的收口路由被发了邮件 | 两个原因叠加：**死配置没把规则关掉** + **收口路由把 `severity=none` 也收进来了** | 删掉死配置；路由层加 `severity = none → receiver discard`。**不删规则文件**：`general.rules` 里还有 TargetDown，关整组会误伤 |
| 8 | `deploy-task7.sh` 的验收 1、2 报失败，但随后告警实际正常触发、邮件也到了 | 对时间线：脚本在 `kubectl apply` 后只等 5 秒就断言 | **链路存在异步延迟**——Prometheus 发现「规则文件新增」要等 Operator 写文件 + config-reloader 触发 reload + Prometheus 重读，官方预期**最长 1 分钟**；Operator 生成 Alertmanager 配置并写 Secret 也要几秒。apply 完立刻断言必然误报 | 验收项改成**轮询等待**（规则最多等 90 秒）；验收 2 不再「猜 Secret 名 + grep receiver 前缀」，改为直接读 Alertmanager 的 `/api/v2/status` 拿**生效配置**，不依赖任何命名约定。另写 `scripts/diag-task7.sh` 一次取全链路证据 |
| 9 | **告警在 Prometheus 里正常 FIRING、Alertmanager 也收到了，但邮件与钉钉一条都不发**；同时邮箱里却躺着一封 `monitoring` 命名空间的 InfoInhibitor 噪声邮件 | ① 读 chart 的 values 与 CRD，确认 `alertmanagerConfigMatcherStrategy` 默认是 `OnNamespace`；② 读 Operator 源码 `pkg/alertmanager/amcfg.go`，`namespaceEnforcer.processRoute` 明确写着「Routes created from AlertmanagerConfig resources should only match alerts that come from the same namespace」并 `append` 了一个 `namespace=<crKey.Namespace>` 匹配条件；③ 关键旁证：**唯一收到的那封邮件恰好是 `namespace=monitoring` 的告警**，与「只有 monitoring 的告警能匹配我们的路由」完全吻合 | AlertmanagerConfig 与业务告警**不在同一个命名空间**（配置在 monitoring、告警在 boutique），而 Operator 默认会把路由限制在配置所在的命名空间 → 业务告警全部落到 chart 默认根路由的 `null` 接收器上被静默丢弃 | 在 values 里设 `alertmanagerConfigMatcherStrategy.type: OnNamespaceExceptForAlertmanagerNamespace` → `helm upgrade`。本项目**保留**默认保护（不用 `None`）：因为我们的配置住在 Alertmanager 自己的命名空间，该策略的语义正是「放在我身边的配置 = 集群级策略」 |
| 10 | 诊断脚本在 ECS 上一执行就崩：`line 18: $'\r': command not found` / `invalid option nameline 19: set: pipefail` / `syntax error near unexpected token \`$'in\r'\`` | 本地 `bash -n` 全过、Git Bash 也能跑 → 说明不是语法问题；用 `grep -qU $'\r'` 检查工作区文件，发现**只有这一个脚本是 CRLF** | 该文件被某个工具（python 以文本模式改写）写成了 CRLF。Windows 侧一切正常，Linux 的 bash 在**解析阶段**就拒绝。**报错不从第一行开始、且完全不像行尾符问题**，极易误判 | `sed -i 's/\r$//' scripts/diag-task7.sh`；`.gitattributes` 已强制 LF 但**只在 add/checkout 时生效、挡不住工作区被写坏**，所以 scp 前加一次 `grep -lU $'\r' scripts/*.sh` 自检（已写进 §3.5） |
| 11 | `deploy-task7.sh` 的验收 2 连续 6 次「取不到 Alertmanager 的生效配置」，但手动 curl 一切正常 | 核对 Alertmanager 的 OpenAPI 规范（`api/v2/openapi.yaml`） | **`/api/v2/status` 里根本没有 `configYAML` 字段**（写它会静默拿到 `null`，不报错）；正确路径是 **`.config.original`**（返回原始配置字符串） | 改成 `.config.original`；并加了一条兜底：万一 API 再变，就直接 `exec` 进容器读配置文件，路径从容器自己的 `--config.file` 参数里取（不写死路径）。教训：**读第三方 API 前先核对它的 OpenAPI 规范**，别按记忆写字段名 |
| 12 | 演练脚本报「通道计数只 +1」，看着像**只有一个通道发出去了**，但邮箱与钉钉里各有 2 条 | 脚本输出与收件箱对时间 → 计数是在检出 Resolved 后**立刻**取的，恢复通知稍后才投递 | **取数竞态**：Alertmanager「先标 Resolved、再异步投递恢复通知」 | 脚本改为先轮询等 `email` 与 `webhook` 都出现增量、再多等 15s 取终值；并**直接打印增量与逐通道判定**（旧版只打「前/后」两张快照要人自己相减——这正是误读的来源） |
| 13 | 收件人界面给出的时间**只到分钟**，算不出「故障 → 触达」的秒数；一度以为钉钉会把 <5 分钟的消息合并进同一时间分隔 | 换了一张钉钉桌面客户端的完整截图：两条消息各有独立时间标签（`20:40` / `20:43`），说明「合并」的说法不成立，之前那张图里显示的是**消息组的时间标签**，被误读了 | 收件人客户端的设计如此（邮箱/钉钉都只到分钟）；而 Alertmanager 的 **「首次投递成功」又恰好是 Debug 级别**（`notify/retry_stage.go`），默认日志里根本没有 | 脚本改为**自己采样 Alertmanager `/metrics`**（每 2s 直连取 `alertmanager_notifications_total`，记录首次自增时刻），精度 ±2s、与日志级别无关；`--report` 复用采样文件 |
| 14 | 收尾路径 `trap … EXIT` 里用 `${cur:-0}` 判副本数——`kubectl` 读取失败时 `cur` 为空、被当成 `0`，脚本会在**本来正常的集群上执行 scale，把副本数改成 2** | 用桩命令让 `kubectl get deploy` 返回空，观察收尾动作 | `${var:-0}` 把「读失败」和「真的是 0」混为一谈。收尾是**失败后也会执行**的路径，基于读失败做变更比不动作更糟 | ① 判定改成 `[[ "$cur" == "0" ]]`（**确实读到 0** 才恢复）；② 恢复目标不再写死 2，改用读到的**演练前真实副本数**（`RESTORE_REPLICAS`），读不到才退回 2 并显式告警 |

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
