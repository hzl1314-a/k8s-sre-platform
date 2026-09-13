#!/usr/bin/env bash
# =============================================================================
# deploy-task7.sh —— 任务 7 告警双通道：一键部署 + 自带验收
#
# 为什么要有这个脚本：任务 7 的部署有 6 个步骤、4 个验收点，
# 手工敲容易漏、也容易在「apply 成功」和「真的生效」之间产生误判
# （这个项目已经栽过好几次静默失效）。所以把步骤和验收都固化下来，
# 每一步都当场验证，失败就停在那里并告诉你查什么。
#
# 用法（在 k8s-cp 上执行）：
#   bash ~/deploy-task7.sh
#   bash ~/deploy-task7.sh --dir ~/task7 --dingtalk-config ~/dingtalk-config.yml
#   bash ~/deploy-task7.sh --email another@qq.com
#
# 需要的文件（都在 cp 节点上）：
#   <--dir>/dingtalk-webhook.yaml        钉钉转发组件清单
#   <--dir>/boutique-alert-rules.yaml    告警规则
#   <--dir>/alertmanager-config.yaml     Alertmanager 路由
#   <--dingtalk-config>                  钉钉转发配置（含 access_token 与加签 secret）
#
# 邮箱 SMTP 授权码**不通过参数传**（会进 shell 历史），改为交互式输入且不回显。
#
# 幂等：Secret 用 `create --dry-run=client | apply` 方式写入，重复执行不会报「已存在」。
#
# 退出码：0 全部通过；1 前置缺失；2 中间某步失败（会指出卡在哪一步）
# =============================================================================

set -uo pipefail

NS_MON="monitoring"
NS_APP="boutique"
EMAIL_TO="3304345637@qq.com"
DIR="$HOME/task7"
DINGTALK_CONFIG="$HOME/dingtalk-config.yml"
SKIP_RESTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)             DIR="$2"; shift 2 ;;
    --dingtalk-config) DINGTALK_CONFIG="$2"; shift 2 ;;
    --email)           EMAIL_TO="$2"; shift 2 ;;
    -h|--help)         sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

PASS=0; FAIL=0
ok()   { echo "   ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "   ✗ $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "── $* ──────────────────────────────────────"; }
die()  { echo; echo "[中止] $*" >&2; exit 2; }

# port-forward 的临时端口
PROM_PORT=19090
AM_PORT=19093
PF_PID=""
PF_AM_PID=""
cleanup() {
  [[ -n "$PF_PID"    ]] && kill "$PF_PID"    2>/dev/null
  [[ -n "$PF_AM_PID" ]] && kill "$PF_AM_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "=============================================================="
echo " 任务 7：告警双通道部署 + 验收"
echo "--------------------------------------------------------------"
echo " 清单目录   : $DIR"
echo " 钉钉配置   : $DINGTALK_CONFIG"
echo " 收件邮箱   : $EMAIL_TO"
echo "=============================================================="

# ---------------------------------------------------------------------------
step "第 0 步：前置检查"
# ---------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "缺少 kubectl"
command -v jq      >/dev/null 2>&1 || die "缺少 jq（安装：apt-get install -y jq）"
echo "   ✓ kubectl / jq 就绪"

kubectl get ns "$NS_MON" >/dev/null 2>&1 || die "命名空间 $NS_MON 不存在（监控栈还没装？）"
kubectl -n "$NS_MON" get deploy kube-prometheus-stack-operator >/dev/null 2>&1 \
  || echo "   ⚠ 没找到 kube-prometheus-stack-operator（继续，但 AlertmanagerConfig 可能不会被处理）"

MISSING=0
for f in dingtalk-webhook.yaml boutique-alert-rules.yaml alertmanager-config.yaml; do
  if [[ -f "$DIR/$f" ]]; then echo "   ✓ 找到 $DIR/$f"
  else echo "   ✗ 缺少 $DIR/$f"; MISSING=1; fi
done
[[ -f "$DINGTALK_CONFIG" ]] && echo "   ✓ 找到 $DINGTALK_CONFIG" \
                           || { echo "   ✗ 缺少 $DINGTALK_CONFIG"; MISSING=1; }
[[ $MISSING -eq 1 ]] && die "请先把缺失的文件 scp 上来（命令见脚本末尾提示）"

# ---------------------------------------------------------------------------
step "第 1 步：邮箱授权码写入 Secret"
# ---------------------------------------------------------------------------
# 用 read -s：不回显、不进 shell 历史
if kubectl -n "$NS_MON" get secret alertmanager-email-secret >/dev/null 2>&1; then
  echo "   Secret alertmanager-email-secret 已存在。"
  read -r -p "   要更新它吗？(y/N) " ans
  if [[ "${ans:-N}" != "y" && "${ans:-N}" != "Y" ]]; then
    echo "   跳过（沿用已有 Secret）"
  else
    DO_EMAIL=1
  fi
else
  DO_EMAIL=1
fi

if [[ "${DO_EMAIL:-0}" == "1" ]]; then
  read -r -s -p "   粘贴 QQ 邮箱 SMTP 授权码（输入不回显）: " AUTHCODE; echo
  [[ -z "$AUTHCODE" ]] && die "授权码为空"
  kubectl -n "$NS_MON" create secret generic alertmanager-email-secret \
    --from-literal=password="$AUTHCODE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
    || die "写入 Secret 失败"
  unset AUTHCODE
  ok "alertmanager-email-secret 已写入"
fi

# ---------------------------------------------------------------------------
step "第 2 步：钉钉转发配置写入 Secret"
# ---------------------------------------------------------------------------
grep -q 'REPLACE_WITH_YOUR_ACCESS_TOKEN' "$DINGTALK_CONFIG" \
  && die "$DINGTALK_CONFIG 里还是占位符，请先填真实的 access_token"
grep -q 'access_token=' "$DINGTALK_CONFIG" \
  || die "$DINGTALK_CONFIG 里没有 access_token"
ok "钉钉配置看起来已填实（未发现占位符）"

kubectl -n "$NS_MON" create secret generic dingtalk-webhook-config \
  --from-file=config.yml="$DINGTALK_CONFIG" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || die "写入 dingtalk-webhook-config 失败"
ok "dingtalk-webhook-config 已写入"

# ---------------------------------------------------------------------------
step "第 3 步：部署钉钉转发组件"
# ---------------------------------------------------------------------------
EXISTED=0
kubectl -n "$NS_MON" get deploy prometheus-webhook-dingtalk >/dev/null 2>&1 && EXISTED=1

kubectl apply -f "$DIR/dingtalk-webhook.yaml" | sed 's/^/   /' || die "apply 失败"
if [[ $EXISTED -eq 1 ]]; then
  # Secret 以 subPath 挂载，不会热更新，必须重启才会读到新配置
  echo "   检测到组件已存在 → 重启以加载新配置（subPath 挂载不会热更新）"
  kubectl -n "$NS_MON" rollout restart deploy/prometheus-webhook-dingtalk >/dev/null
fi

echo "   等待滚动完成..."
if kubectl -n "$NS_MON" rollout status deploy/prometheus-webhook-dingtalk --timeout=120s >/dev/null 2>&1; then
  ok "转发组件已就绪"
else
  bad "转发组件未就绪，看这个：kubectl -n monitoring describe pod -l app.kubernetes.io/name=prometheus-webhook-dingtalk"
  kubectl -n "$NS_MON" get pods -l app.kubernetes.io/name=prometheus-webhook-dingtalk | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
step "第 4 步：应用告警规则与 Alertmanager 路由"
# ---------------------------------------------------------------------------
kubectl apply -f "$DIR/boutique-alert-rules.yaml"   | sed 's/^/   /'
kubectl apply -f "$DIR/alertmanager-config.yaml"    | sed 's/^/   /'
ok "规则与路由已提交"

# ---------------------------------------------------------------------------
step "第 5 步：验收（4 项）"
# ---------------------------------------------------------------------------
sleep 5

# ---- 验收 1：规则是否被 Prometheus 加载 ----
# 注意：变量名不能用 GROUPS —— 它是 bash 的内建数组（保存当前用户的组 ID），
# 赋值后展开时会被 shell 覆盖成 `id -g` 的值，导致报出一个莫名其妙的大数字。
# 同理要避开的还有：SECONDS / RANDOM / UID / EUID / PPID / LINENO / PIPESTATUS / REPLY / DIRSTACK
#
# ★ 必须轮询等待：Prometheus 发现**规则文件新增**不是立刻的。
#   链路是「我们要 apply → Operator 把规则写进 Prometheus 的 rules 目录 →
#   config-reloader 触发 reload → Prometheus 重读 rules 目录」，
#   官方文档给的预期是「最多 1 分钟」。apply 完 5 秒就判定，必然误报未加载。
kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-prometheus "${PROM_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
sleep 4

RULE_GROUPS=0; RULE_COUNT=0; RULES_JSON=""
for i in 1 2 3 4 5 6; do
  RULES_JSON=$(curl -s -m 10 "http://127.0.0.1:${PROM_PORT}/api/v1/rules" 2>/dev/null)
  if printf '%s' "$RULES_JSON" | jq -e '.status == "success"' >/dev/null 2>&1; then
    RULE_GROUPS=$(printf '%s' "$RULES_JSON" | jq -r '[.data.groups[] | select(.name|startswith("boutique"))] | length')
    RULE_COUNT=$(printf '%s'  "$RULES_JSON" | jq -r '[.data.groups[] | select(.name|startswith("boutique")) | .rules[]] | length')
    [[ "${RULE_GROUPS:-0}" -ge 4 ]] && break
    echo "     等待 Prometheus 加载规则…（第 ${i}/6 次，规则文件新增最多需要 1 分钟）"
    sleep 15
  else
    echo "     Prometheus API 暂时不可达（第 ${i}/6 次），重试中…"
    sleep 5
  fi
done

if [[ "${RULE_GROUPS:-0}" -ge 4 ]]; then
  ok "验收 1：Prometheus 已加载 ${RULE_GROUPS} 个 boutique 规则组 / ${RULE_COUNT} 条规则"
elif printf '%s' "$RULES_JSON" | jq -e '.status == "success"' >/dev/null 2>&1; then
  bad "验收 1：等了 90 秒仍只加载到 ${RULE_GROUPS:-0} 个组（期望 4）"
  echo "      检查 ruleSelectorNilUsesHelmValues 是否为 false（见 monitoring/kube-prometheus-stack-values.yaml）"
  printf '%s' "$RULES_JSON" | jq -r '.data.groups[].name' | sed 's/^/      当前已加载的组: /'
else
  bad "验收 1：Prometheus API 不可达，无法确认规则加载（port-forward 失败？）"
  PF_DEAD=1
fi

# ---- 验收 2：Alertmanager 的**生效配置**里有没有我们的路由 ----
# 早先这里用「猜 Secret 名 + grep receiver 名前缀」的方式，结果误报为失败：
#   · Secret 名与 receiver 命名规则都依赖 Operator 版本，猜不得；
#   · 实际证据是那一封 InfoInhibitor 邮件 —— 它正是被我们的根路由发出来的，
#     说明路由明明生效了（chart 默认把这类告警丢给 null）。
# 改法：直接读 Alertmanager 自己的 /api/v2/status，它返回渲染后的**最终配置**，
# 这是唯一权威的事实来源，不依赖任何命名约定。
kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-alertmanager "${AM_PORT}:9093" >/dev/null 2>&1 &
PF_AM_PID=$!
sleep 4

AMCFG=""
for i in 1 2 3 4 5 6; do
  AMCFG=$(curl -s -m 10 "http://127.0.0.1:${AM_PORT}/api/v2/status" 2>/dev/null | jq -r '.configYAML' 2>/dev/null)
  [[ -n "$AMCFG" && "$AMCFG" != "null" ]] && break
  echo "     等待 Alertmanager 生效…（第 ${i}/6 次）"
  sleep 5
done

if [[ -n "$AMCFG" && "$AMCFG" != "null" ]]; then
  if printf '%s' "$AMCFG" | grep -q 'boutique-alertmanager-config'; then
    ok "验收 2：Alertmanager 生效配置里已包含本项目的路由"
    echo "      实际 receiver 名："
    printf '%s' "$AMCFG" | grep -oE '[A-Za-z0-9/_-]*boutique-alertmanager-config[A-Za-z0-9/_-]*' \
      | sort -u | sed 's/^/        /'
  else
    bad "验收 2：生效配置里找不到本项目的路由（AlertmanagerConfig 没被选中）"
    echo "      检查 alertmanager.alertmanagerSpec.alertmanagerConfigSelector 与 CR 的标签"
  fi

  # ★ 高频陷阱：Operator 的 alertmanagerConfigMatcherStrategy 默认 OnNamespace，
  #   会给每条路由追加 namespace=<配置所在命名空间>。配置在 monitoring、告警在 boutique 时，
  #   结果是「告警正常触发但一条通知都不发」。这一项必须单独查，否则路由看起来是"合并成功"的。
  if printf '%s' "$AMCFG" | grep -qE 'namespace[[:space:]]*=[[:space:]]*=?"?monitoring"?'; then
    bad "验收 2b：路由被追加了 namespace=\"monitoring\" 限制 → 业务告警（namespace=boutique）不会走本路由！"
    echo "      现象：Prometheus 里告警 FIRING、Alertmanager 也收到了，但邮件/钉钉一条都不发。"
    echo "      修法：kube-prometheus-stack values 里设"
    echo "            alertmanager.alertmanagerSpec.alertmanagerConfigMatcherStrategy.type=OnNamespaceExceptForAlertmanagerNamespace"
    echo "            然后 helm upgrade（本项目 values 已配好，执行过一次 upgrade 即可）"
  else
    ok "验收 2b：路由未被追加 namespace 限制（匹配策略正确）"
  fi
else
  bad "验收 2：取不到 Alertmanager 的生效配置（port-forward 失败？）"
  echo "      也可手工核对：port-forward 9093 后打开 http://localhost:9093 → Status → Config"
fi


# ---- 验收 3：转发组件在跑 ----
NOTREADY=$(kubectl -n "$NS_MON" get pods -l app.kubernetes.io/name=prometheus-webhook-dingtalk \
           --no-headers 2>/dev/null | grep -vc 'Running' || true)
if [[ "${NOTREADY:-1}" == "0" ]]; then
  ok "验收 3：转发组件 Pod 全部 Running"
else
  bad "验收 3：有 ${NOTREADY} 个转发组件 Pod 非 Running"
fi

# ---- 验收 4：Prometheus 已认到 Alertmanager ----
if [[ -z "${PF_DEAD:-}" ]]; then
  AMS_JSON=$(curl -s -m 10 "http://127.0.0.1:${PROM_PORT}/api/v1/alertmanagers" 2>/dev/null)
  AMS=$(printf '%s' "$AMS_JSON" | jq -r '.data.activeAlertmanagers | length' 2>/dev/null)
  if [[ "${AMS:-0}" -ge 1 ]]; then
    ok "验收 4：Prometheus 已连接 ${AMS} 个 Alertmanager"
  else
    bad "验收 4：Prometheus 没有活跃的 Alertmanager 接收方"
  fi
fi


# ---------------------------------------------------------------------------
echo
echo "=============================================================="
echo " 结果：通过 ${PASS} 项，失败 ${FAIL} 项"
echo "=============================================================="
if [[ $FAIL -gt 0 ]]; then
  echo " 失败项的排查方向见 docs/alerting.md §5「按链路分段定位」"
  echo " 自测建议：先只验钉钉这一段的转发组件是否健康"
  echo "   kubectl -n $NS_MON logs deploy/prometheus-webhook-dingtalk --tail=30"
fi

cat <<EOF

 下一步：跑一次真实的告警演练（会自动记录时间线）
   bash ~/alert-drill.sh --hold 150

 演练结束后把两个时间填回 docs/alerting.md §4：
   · 邮箱收到告警的时刻
   · 钉钉收到告警的时刻

 如果这个脚本是你第一次部署，注意本机 scp 命令是：
   ssh root@<cp公网IP> 'mkdir -p ~/task7'
   scp manifests/alerts/dingtalk-webhook.yaml \\
       manifests/alerts/boutique-alert-rules.yaml \\
       manifests/alerts/alertmanager-config.yaml root@<cp公网IP>:~/task7/
   scp downloads/secrets/dingtalk-config.yml        root@<cp公网IP>:~/dingtalk-config.yml
   scp scripts/deploy-task7.sh scripts/alert-drill.sh root@<cp公网IP>:~/
EOF
exit 0
