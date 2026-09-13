#!/usr/bin/env bash
# =============================================================================
# alert-drill.sh —— 任务 7 告警链路端到端演练（触发 → 触达 → 恢复）
#
# 这个脚本解决的问题：告警验收要的是**精确时间线**（故障到触达多少秒），
# 而这些数字要写进简历和 README。靠手工看表掐秒既不准、也说不清取证过程。
#
# 它自动完成：
#   1. 前置检查（依赖、监控栈、业务副本）
#   2. 通过 port-forward 连上 Prometheus / Alertmanager API
#   3. 注入故障（把 frontend 副本缩到 0）
#   4. 轮询并记录：Pending 时刻、Firing 时刻、Alertmanager 收到时刻
#   5. 记录 Alertmanager 各通道的**发送计数增量**（证明邮件与钉钉真的发出去了）
#   6. 恢复副本，等待并记录 Resolved 时刻
#   7. 输出时间线表 + 关键 KPI（故障→触达秒数）
#
# 用法（在 k8s-cp 上执行）：
#   bash ~/alert-drill.sh
#   bash ~/alert-drill.sh --hold 180 --out task7-drill.log
#   bash ~/alert-drill.sh --alert IngressHighErrorRate       # 换一条告警演练
#
# 为什么必须在 k8s-cp（Linux）上跑，不要在本机 Windows 上跑：
#   ① NodePort 在每个节点都监听，cp 上访问 127.0.0.1:30080 与外部走同一条
#      kube-proxy 转发链路，可用性结论一致；
#   ② Windows Git Bash 下每次 curl 启动开销 2~3 秒，脚本会反复 curl，
#      轮询精度会碎掉（这个坑在故障演练文档里已记录）。
#
# 手工补充项（脚本无法代劳）：
#   * 邮箱里那封告警邮件的**到达时间**（右键 → 显示原始邮件，看 Date 头）
#   * 钉钉消息的发送时间戳
#   两处填进脚本输出末尾的「手工填写」表，就是截图 13-16 的对应证据。
#
# 退出码：0 全部符合预期；1 依赖缺失；2 未在预期时间内观测到告警/恢复
# =============================================================================

set -uo pipefail

# ---------------------------- 可调参数 ---------------------------------------
NS_APP="boutique"
DEPLOY="frontend"
ALERT_NAME="DeploymentReplicasUnavailable"
NS_MON="monitoring"
PROM_SVC="kube-prometheus-stack-prometheus"
AM_SVC="kube-prometheus-stack-alertmanager"
PROM_PORT=19090
AM_PORT=19093
HOLD=120              # 注入故障后保持多少秒（留出邮件/钉钉到达与截图的时间）
TIMEOUT_FIRING=300    # 等待告警 Firing 的上限
TIMEOUT_RESOLVED=300  # 等待告警 Resolved 的上限
OUT="alert-drill.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alert) ALERT_NAME="$2";   shift 2 ;;
    --hold)  HOLD="$2";         shift 2 ;;
    --out)   OUT="$2";          shift 2 ;;
    -h|--help)
      sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------- 工具函数 ---------------------------------------
ts()   { date +%Y-%m-%dT%H:%M:%S%:z; }
now()  { date +%s; }

log() {
  # log <事件名> <补充说明>
  printf '%s\t%s\t%s\n' "$(ts)" "$1" "${2:-}" >> "$OUT"
}

secs() { echo $(( $1 - $2 )); }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[错误] 缺少命令 $1。" >&2
    case "$1" in
      jq) echo "       安装：sudo apt-get install -y jq" >&2 ;;
      *)  echo "       请先安装后重试。" >&2 ;;
    esac
    exit 1
  fi
}

# 记录 Alertmanager 各通道累计发送/失败数（用于算增量）
notif_snapshot() {
  curl -s -m 10 "http://127.0.0.1:${PROM_PORT}/api/v1/query" \
    --data-urlencode 'query=sum by (integration) (alertmanager_notifications_total)' \
  | jq -r '.data.result[]? | "\(.metric.integration) \(.value[1])"' | sort
}

# 查某个告警当前状态：firing / pending / absent
alert_state() {
  curl -s -m 10 "http://127.0.0.1:${PROM_PORT}/api/v1/alerts" \
  | jq -r --arg a "$ALERT_NAME" '
      [.data.alerts[]? | select(.labels.alertname == $a) | .state] | first // "absent"'
}

# Alertmanager 是否已收到该告警
am_has_alert() {
  curl -s -m 10 "http://127.0.0.1:${AM_PORT}/api/v2/alerts" \
  | jq -r --arg a "$ALERT_NAME" \
      '[.[] | select(.labels.alertname == $a)] | length'
}

cleanup() {
  local rc=$?
  echo
  echo "—— 收尾 ——"
  # 关键安全动作：任何异常退出（含 Ctrl+C）都必须把副本恢复，否则集群一直少一半容量
  local cur
  cur=$(kubectl -n "$NS_APP" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [[ "${cur:-0}" == "0" ]]; then
    echo "检测到 $DEPLOY 副本为 0，自动恢复为 2"
    kubectl -n "$NS_APP" scale deploy/"$DEPLOY" --replicas=2
    log "auto-restore" "异常退出后自动恢复副本为 2"
  fi
  [[ -n "${PF_PROM_PID:-}" ]] && kill "$PF_PROM_PID" 2>/dev/null
  [[ -n "${PF_AM_PID:-}"   ]] && kill "$PF_AM_PID"   2>/dev/null
  exit "$rc"
}
trap cleanup INT TERM EXIT

# ---------------------------- 0. 前置检查 -----------------------------------
need kubectl
need curl
need jq

echo "=============================================================="
echo " 任务 7 告警链路演练"
echo "--------------------------------------------------------------"
echo " 目标告警 : ${ALERT_NAME}"
echo " 故障方式 : ${NS_APP}/${DEPLOY} 副本 scale 到 0，保持 ${HOLD}s 后恢复为 2"
echo " 日志文件 : ${OUT}"
echo "=============================================================="
echo

: > "$OUT"
log "start" "drill begin, alert=${ALERT_NAME}, hold=${HOLD}s"

echo "[1/7] 前置检查"
kubectl get ns "$NS_APP" >/dev/null 2>&1 || { echo "[错误] 命名空间 $NS_APP 不存在" >&2; exit 1; }
kubectl -n "$NS_APP" get deploy "$DEPLOY" >/dev/null 2>&1 || { echo "[错误] Deployment $NS_APP/$DEPLOY 不存在" >&2; exit 1; }

ORIG_REPLICAS=$(kubectl -n "$NS_APP" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}')
echo "      $DEPLOY 当前副本数 = ${ORIG_REPLICAS}"
if [[ "${ORIG_REPLICAS:-0}" -lt 2 ]]; then
  echo "      ⚠️ 副本数 < 2，恢复阶段将设回 2。演练前建议先确认基线。"
fi

echo "      检查监控栈 Pod..."
kubectl -n "$NS_MON" get deploy "$PROM_SVC"   >/dev/null 2>&1 \
  || echo "      ⚠️ 未找到 deploy/$PROM_SVC（Prometheus 可能由 Operator 以 StatefulSet 管理，继续）"
for kw in alertmanager prometheus-webhook-dingtalk; do
  if kubectl -n "$NS_MON" get pods -o name 2>/dev/null | grep -q "$kw"; then
    echo "      ✓ 发现 $kw"
  else
    echo "      ✗ 未发现 $kw —— 钉钉通道可能还没部署（见 docs/alerting.md）"
  fi
done
log "preflight" "orig_replicas=${ORIG_REPLICAS}"

# ---------------------------- 1. 打通 API -----------------------------------
echo
echo "[2/7] 建立 port-forward（Prometheus :${PROM_PORT}, Alertmanager :${AM_PORT}）"
kubectl -n "$NS_MON" port-forward "svc/${PROM_SVC}" "${PROM_PORT}:9090" >/dev/null 2>&1 &
PF_PROM_PID=$!
kubectl -n "$NS_MON" port-forward "svc/${AM_SVC}"   "${AM_PORT}:9093"   >/dev/null 2>&1 &
PF_AM_PID=$!
sleep 4

if ! curl -s -m 8 "http://127.0.0.1:${PROM_PORT}/-/ready" >/dev/null; then
  echo "[错误] Prometheus API 不可达。检查 svc/${PROM_SVC} 是否存在：" >&2
  kubectl -n "$NS_MON" get svc | sed 's/^/        /' >&2
  exit 1
fi
echo "      ✓ Prometheus 就绪"
curl -s -m 8 "http://127.0.0.1:${AM_PORT}/-/ready" >/dev/null && echo "      ✓ Alertmanager 就绪" \
  || echo "      ⚠️ Alertmanager API 不可达（不影响告警发送，只影响本脚本的采集）"

echo "      演练前告警状态: $(alert_state)"

# 记录基线计数
BASE_TOTAL=$(notif_snapshot)
echo "      演练前各通道累计发送数:"
printf '%s\n' "$BASE_TOTAL" | sed 's/^/        /' | grep . || echo "        （无数据，可能还没发过通知）"

# ---------------------------- 2. 注入故障 -----------------------------------
echo
echo "[3/7] 注入故障：scale ${DEPLOY} → 0"
T_FAULT=$(now)
log "fault-injected" "scale ${NS_APP}/${DEPLOY} to 0"
kubectl -n "$NS_APP" scale deploy/"$DEPLOY" --replicas=0 | sed 's/^/      /'

# ---------------------------- 3. 等 Firing ----------------------------------
echo
echo "[4/7] 轮询告警状态（Pending → Firing，上限 ${TIMEOUT_FIRING}s）"
echo "      提示：此时可以打开 Grafana 看板、留意邮箱与钉钉"
T_PENDING=""; T_FIRING=""; T_AM_RECV=""
DEADLINE=$(( $(now) + TIMEOUT_FIRING ))
while [[ $(now) -lt $DEADLINE ]]; do
  st=$(alert_state)
  case "$st" in
    pending)
      if [[ -z "$T_PENDING" ]]; then
        T_PENDING=$(now)
        log "alert-pending" "state=pending (+$(secs "$T_PENDING" "$T_FAULT")s)"
        echo "      [$(ts)] Pending  (+$(secs "$T_PENDING" "$T_FAULT")s 后)"
      fi
      ;;
    firing)
      T_FIRING=$(now)
      log "alert-firing" "state=firing (+$(secs "$T_FIRING" "$T_FAULT")s)"
      echo "      [$(ts)] ★ Firing  (+$(secs "$T_FIRING" "$T_FAULT")s 后)"
      break
      ;;
  esac
  sleep 3
done

if [[ -z "$T_FIRING" ]]; then
  echo "      ✗ ${TIMEOUT_FIRING}s 内未观测到 Firing。"
  echo "        排查方向：① 规则是否被加载（Prometheus UI → Rules 搜 ${ALERT_NAME}）"
  echo "                  ② 规则文件是否带 release 标签 / ruleSelectorNilUsesHelmValues 是否为 false"
  echo "                  ③ 表达式在 Prometheus 里直接查是否有结果"
  log "alert-firing" "TIMEOUT after ${TIMEOUT_FIRING}s"
  exit 2
fi

# Alertmanager 是否已收到（证明 Prometheus → Alertmanager 这一跳通了）
for _ in $(seq 1 20); do
  if [[ "$(am_has_alert)" != "0" ]]; then
    T_AM_RECV=$(now)
    log "alertmanager-received" "+$(secs "$T_AM_RECV" "$T_FAULT")s"
    echo "      [$(ts)] Alertmanager 已收到该告警 (+$(secs "$T_AM_RECV" "$T_FAULT")s 后)"
    break
  fi
  sleep 2
done

echo
echo "      >>> 请现在核对邮箱与钉钉，记录到达时间（脚本结束时填写）<<<"
echo "      保持故障 ${HOLD}s，为通知到达与截图留时间..."
sleep "$HOLD"

# ---------------------------- 4. 恢复 ---------------------------------------
echo
echo "[5/7] 恢复：scale ${DEPLOY} → 2"
T_RESTORE=$(now)
log "fault-cleared" "scale ${NS_APP}/${DEPLOY} back to 2"
kubectl -n "$NS_APP" scale deploy/"$DEPLOY" --replicas=2 | sed 's/^/      /'

echo
echo "[6/7] 等待告警 Resolved（上限 ${TIMEOUT_RESOLVED}s）"
T_RESOLVED=""
DEADLINE=$(( $(now) + TIMEOUT_RESOLVED ))
while [[ $(now) -lt $DEADLINE ]]; do
  st=$(alert_state)
  if [[ "$st" == "absent" || "$st" == "inactive" ]]; then
    T_RESOLVED=$(now)
    log "alert-resolved" "state=${st} (+$(secs "$T_RESOLVED" "$T_RESTORE")s after clear)"
    echo "      [$(ts)] ★ Resolved (+$(secs "$T_RESOLVED" "$T_RESTORE")s 后)"
    break
  fi
  sleep 3
done
[[ -z "$T_RESOLVED" ]] && { echo "      ⚠️ 未在 ${TIMEOUT_RESOLVED}s 内看到恢复（副本可能还没 Ready）"; log "alert-resolved" "TIMEOUT"; }

# ---------------------------- 5. 通道发送增量 --------------------------------
echo
echo "[7/7] 各通道发送计数增量（证明两个通道都真的发出去了）"
AFTER_TOTAL=$(notif_snapshot)
{
  echo
  echo "== 通道发送计数增量 =="
  echo "（来自 alertmanager_notifications_total，按 integration 分组）"
  echo "演练前："
  printf '%s\n' "$BASE_TOTAL" | sed 's/^/  /' | grep . || echo "  （空）"
  echo "演练后："
  printf '%s\n' "$AFTER_TOTAL" | sed 's/^/  /' | grep . || echo "  （空）"
} | tee -a "$OUT"

# ---------------------------- 6. 汇报 ---------------------------------------
echo
echo "=============================================================="
echo " 演练时间线（全部时间戳见 ${OUT}）"
echo "--------------------------------------------------------------"
printf " 故障注入        : %s\n" "$(date -d "@${T_FAULT}" +%H:%M:%S 2>/dev/null || echo "$T_FAULT")"
[[ -n "$T_PENDING"  ]] && printf " 告警 Pending    : +%ss\n" "$(secs "$T_PENDING" "$T_FAULT")"
printf " 告警 Firing     : +%ss\n" "$(secs "$T_FIRING" "$T_FAULT")"
[[ -n "$T_AM_RECV"  ]] && printf " Alertmanager 收到: +%ss\n" "$(secs "$T_AM_RECV" "$T_FAULT")"
printf " 故障恢复        : +%ss\n" "$(secs "$T_RESTORE" "$T_FAULT")"
[[ -n "$T_RESOLVED" ]] && printf " 告警 Resolved   : +%ss（距恢复 %ss）\n" "$(secs "$T_RESOLVED" "$T_FAULT")" "$(secs "$T_RESOLVED" "$T_RESTORE")"
echo "--------------------------------------------------------------"
echo " ★ 验收 KPI：故障 → Prometheus Firing = $(secs "$T_FIRING" "$T_FAULT") 秒"
echo "   注意：Firing 之后还要经过 Alertmanager 的 groupWait（critical 路由配的是 5s）"
echo "         才真正发出，所以「故障 → 收件人收到」通常比上面这个数字多 5~15 秒。"
echo "         验收标准是「≤ 120 秒」，只要邮件/钉钉到达时间减 T_FAULT ≤ 120 即通过。"
echo "=============================================================="
echo
echo " —— 手工填写（脚本无法代劳，填完就是 README/简历的数字来源）——"
echo "   邮箱告警到达时间   : ______  （→ 距故障 ______ 秒）"
echo "   钉钉告警到达时间   : ______  （→ 距故障 ______ 秒）"
echo "   邮箱恢复通知时间   : ______"
echo "   钉钉恢复通知时间   : ______"
echo
echo " 截图对应（docs/screenshots/README.md S4 段）："
echo "   13-alert-rule-fired.png  Prometheus → Alerts 页面，${ALERT_NAME} 为 FIRING"
echo "   14-alert-email.png       邮箱里的告警邮件（含时间）"
echo "   15-alert-dingtalk.png    钉钉机器人的告警消息（含时间）"
echo "   16-alert-recovered.png   恢复通知（邮件或钉钉任一即可）"
echo "=============================================================="
