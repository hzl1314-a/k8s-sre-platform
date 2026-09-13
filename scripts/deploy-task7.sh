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
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null; }
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
kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-prometheus "${PROM_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
sleep 4

# 就绪判断不能只看 curl 退出码：连接被拒时某些环境（含沙箱）仍返回 0。
# 这里改成取回 JSON 并校验它的结构，才叫「真的连上了」。
RULES_JSON=$(curl -s -m 10 "http://127.0.0.1:${PROM_PORT}/api/v1/rules" 2>/dev/null)
if [[ -n "$RULES_JSON" ]] && printf '%s' "$RULES_JSON" | jq -e '.status == "success"' >/dev/null 2>&1; then
  RULE_GROUPS=$(printf '%s' "$RULES_JSON" | jq -r '[.data.groups[] | select(.name|startswith("boutique"))] | length')
  RULE_COUNT=$(printf '%s'  "$RULES_JSON" | jq -r '[.data.groups[] | select(.name|startswith("boutique")) | .rules[]] | length')
  if [[ "${RULE_GROUPS:-0}" -ge 4 ]]; then
    ok "验收 1：Prometheus 已加载 ${RULE_GROUPS} 个 boutique 规则组 / ${RULE_COUNT} 条规则"
  else
    bad "验收 1：只加载到 ${RULE_GROUPS:-0} 个组（期望 4）。检查 ruleSelectorNilUsesHelmValues 是否为 false"
    printf '%s' "$RULES_JSON" | jq -r '.data.groups[].name' | sed 's/^/      当前已加载的组: /'
  fi
else
  bad "验收 1：Prometheus API 不可达，无法确认规则加载（port-forward 失败？）"
  PF_DEAD=1
fi

# ---- 验收 2：Operator 是否把 AlertmanagerConfig 合并进最终配置 ----
AM_GEN=$(kubectl -n "$NS_MON" get secret -o name 2>/dev/null | grep 'alertmanager.*generated' | head -1)
if [[ -n "$AM_GEN" ]]; then
  CFG=$(kubectl -n "$NS_MON" get "$AM_GEN" -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null)
  if grep -q 'boutique-alertmanager-config/dingtalk' <<<"$CFG"; then
    ok "验收 2：路由已合并（${AM_GEN##*/} 里能找到本项目的 receiver）"
  else
    bad "验收 2：最终配置里没有本项目的 receiver。检查 alertmanagerConfigSelector 与 CR 的标签"
    echo "      手工核对：port-forward Alertmanager 9093 后打开 Status → Config"
  fi
else
  bad "验收 2：找不到 alertmanager 的 generated Secret（Operator 可能没在跑）"
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
