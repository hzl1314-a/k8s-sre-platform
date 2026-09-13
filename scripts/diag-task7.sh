#!/usr/bin/env bash
# =============================================================================
# diag-task7.sh —— 任务 7 告警链路一次性取证（只读，不改任何东西）
#
# 用途：`deploy-task7.sh` 的验收 1 报「规则未加载」但演练里告警确实触发了、
#       或者演练里某个通道收不到消息时，用这个脚本把链路每一段的真实状态取出来。
#
# 设计原则：**不猜，取证**。这条链路有 4 段，任何一段断都表现为「收不到消息」：
#   Prometheus(规则) → Alertmanager(路由) → 转发组件(加签) → 钉钉/邮箱
#   本脚本逐段取证据，最后给出结论指向哪一段。
#
# 在 k8s-cp 上执行：
#   bash ~/diag-task7.sh
#   bash ~/diag-task7.sh > diag.log 2>&1     # 想存文件就重定向
#
# 只读操作，可以反复跑。不注入故障、不改副本、不改配置。
# =============================================================================

set -uo pipefail

NS_MON="monitoring"
NS_APP="boutique"
PROM_PORT=19090
AM_PORT=19093
FW_PORT=18060

ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; }
warn() { echo "  ⚠ $*"; }
sec()  { echo; echo "════ $* ════════════════════════════════════════"; }

# 读取 Alertmanager 的**生效配置**（合并后的最终配置）。
# ⚠️ `/api/v2/status` **没有** configYAML 字段（实测：写它会静默拿到 null）；
#    正确路径是 `.config.original`（返回完整原始配置字符串）。
# 兜底：直接进容器读配置文件，路径从容器自己的 --config.file 参数里取，不写死。
am_effective_config() {
  local cfg pod path
  cfg=$(curl -s -m 10 "http://127.0.0.1:${AM_PORT}/api/v2/status" 2>/dev/null \
        | jq -r '.config.original // empty' 2>/dev/null)
  if [[ -n "$cfg" ]]; then printf '%s' "$cfg"; return 0; fi

  pod=$(kubectl -n "$NS_MON" get pods -l app.kubernetes.io/name=alertmanager \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "$pod" ]] && return 1
  path=$(kubectl -n "$NS_MON" get pod "$pod" \
         -o jsonpath='{range .spec.containers[*].args[*]}{@}{"\n"}{end}' 2>/dev/null \
         | sed -n 's/^--config\.file=//p' | head -1)
  [[ -z "$path" ]] && path=/etc/alertmanager/config/alertmanager.yaml
  kubectl -n "$NS_MON" exec "$pod" -c alertmanager -- cat "$path" 2>/dev/null
}

command -v kubectl >/dev/null 2>&1 || { echo "[错误] 缺少 kubectl" >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "[错误] 缺少 jq：apt-get install -y jq" >&2; exit 1; }

PF_PIDS=()
cleanup() { for p in "${PF_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

echo "=============================================================="
echo " 任务 7 告警链路取证    $(date '+%Y-%m-%d %H:%M:%S%z')"
echo "=============================================================="

# ---------------------------------------------------------------------------
sec "1/7 组件存活"
# ---------------------------------------------------------------------------
kubectl -n "$NS_MON" get pods -o wide 2>/dev/null | awk 'NR==1 || /alertmanager|prometheus-webhook-dingtalk|prometheus-operator|prometheus-kube-prometheus-stack/' | sed 's/^/  /'

# ---------------------------------------------------------------------------
sec "2/7 Alertmanager 生效配置（合并结果）"
# ---------------------------------------------------------------------------
kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-alertmanager "${AM_PORT}:9093" >/dev/null 2>&1 &
PF_PIDS+=($!)
sleep 4

AMCFG=$(am_effective_config 2>/dev/null)

if [[ -z "$AMCFG" ]]; then
  bad "取不到 Alertmanager 的生效配置（port-forward 失败，或 API/容器都读不到）"
  echo "      手工替代方案：kubectl -n $NS_MON exec deploy/kube-prometheus-stack-alertmanager -c alertmanager -- \\"
  echo "                    cat /etc/alertmanager/config/alertmanager.yaml"
else
  echo "  ── receivers（看有没有我们项目的） ──"
  printf '%s' "$AMCFG" | grep -E '^- name:|^  - name:|^\s+- name:' | sed 's/^/    /' | head -20

  if printf '%s' "$AMCFG" | grep -q 'boutique-alertmanager-config'; then
    ok "生成配置里能找到 boutique-alertmanager-config → AlertmanagerConfig 已被合并"
  else
    bad "生成配置里找不到 boutique-alertmanager-config → 我们的路由没进去"
  fi

  # 判别 receiver 命名规则（不同 Operator 版本不一样，先看事实再谈对错）
  echo "  ── 我们 receiver 的实际名字（用于核对路由引用） ──"
  printf '%s' "$AMCFG" | grep -oE '[A-Za-z0-9/_-]*boutique-alertmanager-config[A-Za-z0-9/_-]*' | sort -u | sed 's/^/    /'

  echo "  ── route 段（截取 60 行） ──"
  printf '%s' "$AMCFG" | sed -n '/^route:/,/^receivers:/p' | head -60 | sed 's/^/    /'; echo

  echo "  ── inhibit_rules（chart 默认 4 条：critical→warning/info、warning→info、InfoInhibitor 相关 2 条） ──"
  # 每条抑制规则都恰好有一个 target_matchers，用它数「规则条数」最稳。
  # 注意别写成 `- target_matchers`：只有「没有 source_matchers」的那条规则才带前导 `- `，
  # 其余规则的 target_matchers 是缩进在 source_matchers 下面的，带前导减号会少数。
  # 用 grep -o | wc -l 而不是 grep -c：后者只数**行**，配置被压成一行时就会数错。
  INH=$(printf '%s' "$AMCFG" | grep -o 'target_matchers' | wc -l | tr -d ' ')
  echo "    抑制规则条数 = ${INH}（chart 默认应为 4）"
  if [[ "${INH:-0}" -lt 4 ]]; then
    warn "抑制规则比预期少 → Operator 合并时可能没带上 chart 的默认 inhibit_rules"
    warn "影响：critical 告警无法抑制同命名空间的 warning，告警风暴时噪声会翻倍"
  else
    ok "抑制规则已保留"
  fi
  printf '%s' "$AMCFG" | sed -n '/^inhibit_rules:/,/^route:/p' | head -40 | sed 's/^/    /'; echo

  # ★ 高频陷阱专查：Operator 的 alertmanagerConfigMatcherStrategy 默认值 OnNamespace
  #   会给 AlertmanagerConfig 里的**每条路由**追加 `namespace = <配置所在命名空间>`，
  #   导致「配置在 monitoring、告警在 boutique」时一条都匹配不上（现象：告警 FIRING 但不发通知）。
  echo "  ── 【高频陷阱】路由上有没有被追加 namespace 限制 ──"
  if printf '%s' "$AMCFG" | grep -qE 'namespace[[:space:]]*=[[:space:]]*=?"?monitoring"?'; then
    bad "检测到路由被追加了 namespace=\"monitoring\" 限制！"
    echo "      这意味着只有 monitoring 命名空间的告警会走我们的路由，"
    echo "      业务告警（namespace=boutique）会被丢到默认的 null 接收器 —— 一条通知都不会发。"
    echo "      修法（二选一，推荐前者）："
    echo "        · 在 kube-prometheus-stack values 里设"
    echo "            alertmanager.alertmanagerSpec.alertmanagerConfigMatcherStrategy.type:"
    echo "              OnNamespaceExceptForAlertmanagerNamespace"
    echo "          然后 helm upgrade（本项目已在 monitoring/kube-prometheus-stack-values.yaml 配好）"
    echo "        · 或者把 AlertmanagerConfig 挪到与告警相同的命名空间（本项目不采用：会变成单命名空间策略）"
  else
    ok "路由没有被追加 namespace 限制（匹配策略是 None 或 OnNamespaceExceptForAlertmanagerNamespace）"
  fi

fi

# ---------------------------------------------------------------------------
sec "3/7 通知发送计数（直接读 Alertmanager 自己的 /metrics，避开 Prometheus 采集延迟）"
# ---------------------------------------------------------------------------
METRICS=$(curl -s -m 10 "http://127.0.0.1:${AM_PORT}/metrics" 2>/dev/null)
if [[ -z "$METRICS" ]]; then
  bad "取不到 Alertmanager 指标"
else
  echo "  ── 成功/尝试发出（非 0 才有意义） ──"
  printf '%s' "$METRICS" | grep '^alertmanager_notifications_total' | grep -v ' 0$' | sed 's/^/    /'

  echo "  ── 发送失败（这是判断「发了但送不到」的关键） ──"
  FAILED=$(printf '%s' "$METRICS" | grep '^alertmanager_notifications_failed_total' | grep -v ' 0$')
  if [[ -n "$FAILED" ]]; then
    printf '%s\n' "$FAILED" | sed 's/^/    /'
    bad "存在发送失败 → 上面 reason 字段就是原因（send_error 多为网络/认证/被拒收）"
  else
    ok "没有发送失败记录"
  fi
fi

# ---------------------------------------------------------------------------
sec "4/7 转发组件自测（隔离验证「钉钉这一段」）"
# ---------------------------------------------------------------------------
kubectl -n "$NS_MON" port-forward svc/prometheus-webhook-dingtalk "${FW_PORT}:8060" >/dev/null 2>&1 &
PF_PIDS+=($!)
sleep 3

NOW=$(date -Iseconds); LATER=$(date -Iseconds -d '+5 min')
BODY=$(curl -s -m 15 -w '\n__HTTP__%{http_code}' -X POST \
  "http://127.0.0.1:${FW_PORT}/dingtalk/webhook1/send" \
  -H 'Content-Type: application/json' -d "{
  \"version\":\"4\",\"status\":\"firing\",\"receiver\":\"dingtalk\",
  \"groupLabels\":{\"alertname\":\"链路诊断\"},
  \"commonLabels\":{\"alertname\":\"链路诊断\",\"severity\":\"critical\"},
  \"commonAnnotations\":{\"summary\":\"diag-task7.sh 的自测消息，收到即说明转发组件与钉钉机器人配置正确\"},
  \"externalURL\":\"http://example.com\",
  \"alerts\":[{\"status\":\"firing\",
    \"labels\":{\"alertname\":\"链路诊断\",\"severity\":\"critical\"},
    \"annotations\":{\"summary\":\"链路诊断自测\"},
    \"startsAt\":\"${NOW}\",\"endsAt\":\"${LATER}\",
    \"generatorURL\":\"http://example.com\",\"fingerprint\":\"diag\"}]}" 2>/dev/null)

CODE=$(printf '%s' "$BODY" | sed -n 's/.*__HTTP__//p')
REPLY=$(printf '%s' "$BODY" | sed 's/__HTTP__.*//')
echo "    HTTP ${CODE:-<无响应>}"
echo "    body: ${REPLY:-<空>}"
case "${CODE:-}" in
  200)
    if printf '%s' "$REPLY" | grep -q '"errcode":0'; then
      ok "转发组件 → 钉钉 这一段是通的（钉钉群应已收到「链路诊断」消息）"
    else
      bad "转发组件回了 200 但钉钉拒绝了，看 body 里的 errcode（310000=签名不对或机器人安全设置不匹配）"
    fi ;;
  "")      bad "转发组件无响应（Pod 没起来 / port-forward 失败）" ;;
  404)     bad "转发组件返回 404：URL 里的 target 名与配置里 targets.<名> 不一致（都应为 webhook1）" ;;
  502|503|000) bad "连不上转发组件（${CODE}）：先确认 Pod 为 Running 且 Ready，再看第 5 段日志" ;;
  *)       bad "转发组件返回 ${CODE}，结合 body 与第 5 段日志判断" ;;
esac

# ---------------------------------------------------------------------------
sec "5/7 日志里的错误行"
# ---------------------------------------------------------------------------
echo "  ── 转发组件最近 40 行里含 error/denied/errcode 的 ──"
kubectl -n "$NS_MON" logs deploy/prometheus-webhook-dingtalk --tail=200 2>/dev/null \
  | grep -iE 'error|errcode|denied|refused|timeout|310000' | tail -20 | sed 's/^/    /' \
  || echo "    （无）"

echo "  ── Alertmanager 最近 200 行里含 error/notify 的 ──"
kubectl -n "$NS_MON" logs deploy/kube-prometheus-stack-alertmanager --tail=200 2>/dev/null \
  | grep -iE 'error|failed|notify|webhook' | tail -20 | sed 's/^/    /' \
  || echo "    （无）"

# ---------------------------------------------------------------------------
sec "6/7 Prometheus 侧：规则是否已加载"
# ---------------------------------------------------------------------------
kubectl -n "$NS_MON" port-forward svc/kube-prometheus-stack-prometheus "${PROM_PORT}:9090" >/dev/null 2>&1 &
PF_PIDS+=($!)
sleep 4

RULES=$(curl -s -m 10 "http://127.0.0.1:${PROM_PORT}/api/v1/rules" 2>/dev/null)
if printf '%s' "$RULES" | jq -e '.status == "success"' >/dev/null 2>&1; then
  printf '%s' "$RULES" | jq -r '[.data.groups[] | select(.name|startswith("boutique"))] | "  boutique 规则组数 = \(length)"' 2>/dev/null
  printf '%s' "$RULES" | jq -r '.data.groups[] | select(.name|startswith("boutique")) | "    \(.name): \(.rules|length) 条"' 2>/dev/null
  if printf '%s' "$RULES" | jq -e '[.data.groups[] | select(.name|startswith("boutique"))] | length >= 4' >/dev/null 2>&1; then
    ok "我们的规则已全部加载"
  else
    bad "规则未加载完 → 记忆点：Prometheus 发现规则文件**新增**最多要 1 分钟，刚 apply 完就查会误判"
  fi
else
  bad "Prometheus API 不可达"
fi

# ---------------------------------------------------------------------------
sec "7/7 端到端注入测试 ★ 会真的发出邮件与钉钉消息，请盯住手机与邮箱"
# ---------------------------------------------------------------------------
# 为什么要做这一步：它**绕过 Prometheus 的规则求值**，直接把一条告警灌给 Alertmanager，
# 从而把故障范围一刀切开：
#   · 注入后两个通道都到了 → 路由与通道都是好的，问题在 Prometheus 的标签/规则侧
#   · 只到了邮件         → 钉钉那条路由或接收器有问题（配合第 3 段的 failed 计数看原因）
#   · 一个都没到         → Alertmanager 与通道之间的环节断了（看第 3 段失败计数）
# 这是整份脚本信息量最大的一步，别跳过。
NOW=$(date -Iseconds); LATER=$(date -Iseconds -d '+15 min')
CODE=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${AM_PORT}/api/v2/alerts" -H 'Content-Type: application/json' -d "[{
    \"labels\":{\"alertname\":\"链路诊断注入\",\"severity\":\"critical\",\"namespace\":\"boutique\",\"instance\":\"diag\"},
    \"annotations\":{\"summary\":\"diag-task7.sh 注入的测试告警\",\"description\":\"收到即说明 Alertmanager → 通道 这一段是通的\"},
    \"startsAt\":\"${NOW}\",\"endsAt\":\"${LATER}\"}]" 2>/dev/null)
echo "  注入 API 返回：HTTP ${CODE:-<无响应>}"
if [[ "${CODE:-}" == "200" ]]; then
  echo "  等待 25 秒（critical 路由的 groupWait 是 5s，留足余量）…"
  sleep 25

  echo "  ── 该告警当前状态（重点看 inhibited / silenced，非 0 就说明被抑制了，不会通知） ──"
  curl -s -m 10 "http://127.0.0.1:${AM_PORT}/api/v2/alerts" 2>/dev/null \
    | jq -r '.[] | "    \(.labels.alertname)  severity=\(.labels.severity)  inhibitedBy=\(.status.inhibitedBy|length)  silencedBy=\(.status.silencedBy|length)"' 2>/dev/null

  echo "  ── 注入后的发送计数（非 0 才有意义） ──"
  curl -s -m 10 "http://127.0.0.1:${AM_PORT}/metrics" 2>/dev/null \
    | grep -E '^alertmanager_notifications_(total|failed_total)' | grep -v ' 0$' | sed 's/^/    /'; echo

  echo
  echo "  >>> 现在去看邮箱与钉钉："
  echo "      两个都收到 → 路由与通道正常，问题在 Prometheus 标签/规则侧"
  echo "      只有邮件   → 钉钉路由或接收器有问题（看上面的 failed 计数与 reason）"
  echo "      都没收到   → 看上面的 inhibited 与 failed 计数，再配合第 5 段日志"
else
  bad "注入失败（API 不可达或返回非 200）"
fi

echo
echo "=============================================================="
echo " 取证结束。把上面完整输出贴回给 AI 即可。"
echo " 最需要关注的 4 处："
echo "   · 第 2 段：receiver 的实际名字 + inhibit_rules 是否保留"
echo "   · 第 3 段：notifications_failed_total 有没有非 0（含 reason）"
echo "   · 第 4 段：转发组件自测的 HTTP 码与 errcode"
echo "   · 第 7 段：注入后 inhibitedBy 是否为 0、两个通道是否到达"
echo "=============================================================="
