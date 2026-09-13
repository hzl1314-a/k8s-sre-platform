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
#   5. 记录 Alertmanager 各通道的**投递计数增量**（证明邮件与钉钉真的发出去了）
#   6. 恢复副本，等待并记录 Resolved 时刻
#   7. 等恢复通知投递完成后取增量，逐通道判定「发了 / 没发」
#   8. 从 Alertmanager 日志抓出每个通道的**精确投递时刻**（秒级），并算「距故障 N 秒」
#   9. 输出时间线表 + 关键 KPI
#
# 用法（在 k8s-cp 上执行）：
#   bash ~/alert-drill.sh
#   bash ~/alert-drill.sh --hold 180 --out task7-drill.log
#   bash ~/alert-drill.sh --alert IngressHighErrorRate       # 换一条告警演练
#   bash ~/alert-drill.sh --report                           # 只回填投递时间线，不注入故障
#
# 为什么必须在 k8s-cp（Linux）上跑，不要在本机 Windows 上跑：
#   ① NodePort 在每个节点都监听，cp 上访问 127.0.0.1:30080 与外部走同一条
#      kube-proxy 转发链路，可用性结论一致；
#   ② Windows Git Bash 下每次 curl 启动开销 2~3 秒，脚本会反复 curl，
#      轮询精度会碎掉（这个坑在故障演练文档里已记录）。
#
# 关于「投递时刻」怎么取（这一步以前靠手工，现在脚本自动完成）：
#   Alertmanager 每成功投递一次通知都会打一行日志（ts 为 **UTC**）：
#     ts=... level=info component=dispatcher integration=email[0] msg="Notify success" ...
#   这是比翻邮箱 / 钉钉 UI 更可靠的证据，原因是收件人侧的两个坑：
#     · 邮箱客户端只把时间显示到「分钟」，没有秒；
#     · 钉钉会把间隔小于 5 分钟的消息合并到**同一个时间分隔**下，
#       于是 FIRING（20:02）与 RESOLVED（20:05）看起来像同一时刻发的。
#   脚本在 [8/8] 段直接把 integration × 时刻 × 距故障秒数打出来，用于回填文档。
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
TIMEOUT_NOTIFY=90     # 等待「恢复通知」投递完成的上限（见 [7/8] 段说明）
OUT="alert-drill.log"
REPORT=0              # --report：只回填投递时间线，不注入故障
RESTORE_REPLICAS=2    # 演练结束后要恢复到的副本数；[1/8] 段会按读取到的真实值覆盖
                      # （不要写死 2：万一基线是 3 副本，恢复成 2 就把集群改坏了）

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alert)  ALERT_NAME="$2";   shift 2 ;;
    --hold)   HOLD="$2";         shift 2 ;;
    --out)    OUT="$2";          shift 2 ;;
    --report) REPORT=1;          shift ;;
    -h|--help)
      # 打印文件顶部的注释块（遇到第一条非注释行就停）
      awk 'NR>1 && $0 !~ /^#/ {exit} NR>1 {print}' "$0"; exit 0 ;;
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

# 从快照里取某个 integration 的计数（不存在则为 0）
snap_get() {
  printf '%s\n' "$1" | awk -v k="$2" '$1==k {printf "%d", $2+0; f=1} END {if (!f) print 0}'
}

# ------------------------ Alertmanager 投递时间线 ----------------------------
# 为什么不信收件人界面（两个坑，本机实测）：
#   · 邮箱客户端的时间只精确到分钟；
#   · 钉钉会把间隔 <5 分钟的消息合并进同一个时间分隔，看起来像同一时刻发的。
# Alertmanager 自己的日志才有秒级/毫秒级证据（ts 为 UTC，换算成本机时区后打印）。
am_pod() {
  local p
  p=$(kubectl -n "$NS_MON" get pods -l app.kubernetes.io/name=alertmanager -o name 2>/dev/null | head -1)
  if [[ -z "$p" ]]; then
    # 兜底：Operator 生成的 Pod 名形如 alertmanager-<CR 名>-0
    p=$(kubectl -n "$NS_MON" get pods -o name 2>/dev/null | grep '/alertmanager-' | head -1)
  fi
  printf '%s' "$p"
}

# 取 [since, now] 窗口内的成功投递记录，输出 "integration <utc-ts>"，按时间排序
am_notify_success() {
  local since="$1" pod window lines
  pod=$(am_pod)
  [[ -z "$pod" ]] && return 0
  window=$(( $(now) - since + 60 ))
  lines=$(kubectl -n "$NS_MON" logs "$pod" --since="${window}s" --tail=-1 2>/dev/null) || return 0
  printf '%s\n' "$lines" \
    | grep 'Notify success' \
    | sed -n 's/.*ts=\([^ ]*\).*integration=\([a-zA-Z0-9_]*\).*/\2 \1/p' \
    | sort -k2
}

# 打印投递时间线：时刻 / 通道 / 距故障秒数
print_notify_timeline() {
  local t0="$1" rows ep skipped=0
  rows=$(am_notify_success "$t0")
  if [[ -z "$rows" ]]; then
    echo "      （未取到投递记录：日志可能已轮转，或该窗口内没有成功投递）"
    return 0
  fi
  echo "      时刻(CST)  通道      距故障"
  while read -r integ iso; do
    ep=$(date -d "$iso" +%s 2>/dev/null) || continue
    # 早于时间基准的记录属于上一场演练（--since 窗口的边界效应），跳过，免得算出负数
    if [[ $ep -lt $t0 ]]; then skipped=$(( skipped + 1 )); continue; fi
    printf "      %s   %-9s +%ss\n" "$(date -d "@$ep" +%H:%M:%S)" "$integ" "$(( ep - t0 ))"
  done <<<"$rows"
  [[ $skipped -gt 0 ]] && echo "      （已跳过 ${skipped} 条早于本次故障的记录，属上一场演练）"
  return 0
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

CLEANED=0
cleanup() {
  local rc=$?
  # TERM/INT trap 里调 exit 会再触发一次 EXIT trap，收尾会跑两遍
  # （表现为打印两段「—— 收尾 ——」）。用一个标志位挡住。
  [[ "$CLEANED" == "1" ]] && exit "$rc"
  CLEANED=1
  echo
  echo "—— 收尾 ——"
  # 关键安全动作：任何异常退出（含 Ctrl+C）都必须把副本恢复，否则集群一直少一半容量
  local cur
  cur=$(kubectl -n "$NS_APP" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  # ★ 只在**确实读到 0** 时才恢复。
  #   写成 ${cur:-0} 是个陷阱：kubectl 失败时 cur 为空 → 被当成 0 → 脚本会
  #   在一个本来正常的集群上做一次 scale，把副本数从真实值改成 2。
  #   对收尾这种「失败后仍会执行」的路径，宁可不动作，也不能基于读失败做变更。
  if [[ "$cur" == "0" ]]; then
    echo "检测到 $DEPLOY 副本为 0，自动恢复为 ${RESTORE_REPLICAS}"
    kubectl -n "$NS_APP" scale deploy/"$DEPLOY" --replicas="$RESTORE_REPLICAS"
    log "auto-restore" "异常退出后自动恢复副本为 ${RESTORE_REPLICAS}"
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

# ---------------------- --report：只回填投递时间线 ---------------------------
# 用途：一场演练已经做完（或忘了记数字）时，补录「故障 → 各通道投递」的精确秒数。
# 只读：从 $OUT 读出那次的故障注入时刻当基准，再去 Alertmanager 日志取投递记录，
# 不注入故障、不改集群任何状态。日志轮转后可能取不到，所以趁早跑。
if [[ "$REPORT" == "1" ]]; then
  T_FAULT_H=$(awk -F'\t' '$2=="fault-injected" {print $1}' "$OUT" 2>/dev/null | tail -1)
  if [[ -z "$T_FAULT_H" ]]; then
    echo "[错误] 在 ${OUT} 里找不到 fault-injected 记录，无法确定时间基准。" >&2
    echo "       指定别的日志：bash $0 --report --out <文件>" >&2
    exit 1
  fi
  T0=$(date -d "$T_FAULT_H" +%s 2>/dev/null) || { echo "[错误] 无法解析时间: ${T_FAULT_H}" >&2; exit 1; }
  echo "=============================================================="
  echo " 任务 7 投递时间线回填（--report，只读，不注入故障）"
  echo "--------------------------------------------------------------"
  echo " 时间基准 : ${T_FAULT_H}"
  echo "            （来自 ${OUT} 的 fault-injected 记录）"
  echo "=============================================================="
  echo
  print_notify_timeline "$T0"
  echo
  echo " 取 email / webhook 各自第一条的 +Ns，即为"
  echo " 「故障 → 该通道投递成功」的秒数（验收线 ≤120s）。"
  echo
  exit 0
fi

echo "=============================================================="
echo " 任务 7 告警链路演练"
echo "--------------------------------------------------------------"
echo " 目标告警 : ${ALERT_NAME}"
echo " 故障方式 : ${NS_APP}/${DEPLOY} 副本 scale 到 0，保持 ${HOLD}s 后恢复原副本数"
echo " 日志文件 : ${OUT}"
echo "=============================================================="
echo

: > "$OUT"
log "start" "drill begin, alert=${ALERT_NAME}, hold=${HOLD}s"

echo "[1/8] 前置检查"
kubectl get ns "$NS_APP" >/dev/null 2>&1 || { echo "[错误] 命名空间 $NS_APP 不存在" >&2; exit 1; }
kubectl -n "$NS_APP" get deploy "$DEPLOY" >/dev/null 2>&1 || { echo "[错误] Deployment $NS_APP/$DEPLOY 不存在" >&2; exit 1; }

ORIG_REPLICAS=$(kubectl -n "$NS_APP" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
echo "      $DEPLOY 当前副本数 = ${ORIG_REPLICAS:-<读取失败>}"
# 恢复目标取「演练前的真实值」，而不是写死 2。
# 读不到/读到非数字时退回 2，并明确提示，避免悄悄改坏基线。
if [[ "${ORIG_REPLICAS:-}" =~ ^[0-9]+$ ]] && (( ORIG_REPLICAS >= 1 )); then
  RESTORE_REPLICAS="$ORIG_REPLICAS"
else
  RESTORE_REPLICAS=2
  echo "      ⚠️ 副本数读取异常（'${ORIG_REPLICAS:-}'），恢复阶段按 2 处理；演练前建议先确认基线"
fi
echo "      （演练结束后将恢复为 ${RESTORE_REPLICAS} 副本）"

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
echo "[2/8] 建立 port-forward（Prometheus :${PROM_PORT}, Alertmanager :${AM_PORT}）"
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
echo "[3/8] 注入故障：scale ${DEPLOY} → 0"
T_FAULT=$(now)
log "fault-injected" "scale ${NS_APP}/${DEPLOY} to 0"
kubectl -n "$NS_APP" scale deploy/"$DEPLOY" --replicas=0 | sed 's/^/      /'

# ---------------------------- 3. 等 Firing ----------------------------------
echo
echo "[4/8] 轮询告警状态（Pending → Firing，上限 ${TIMEOUT_FIRING}s）"
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
echo "      >>> 现在去邮箱和钉钉截图留证（数字不用记，脚本结束会自动给出）<<<"
echo "      保持故障 ${HOLD}s，为通知到达与截图留时间..."
sleep "$HOLD"

# ---------------------------- 4. 恢复 ---------------------------------------
echo
echo "[5/8] 恢复：scale ${DEPLOY} → ${RESTORE_REPLICAS}"
T_RESTORE=$(now)
log "fault-cleared" "scale ${NS_APP}/${DEPLOY} back to ${RESTORE_REPLICAS}"
kubectl -n "$NS_APP" scale deploy/"$DEPLOY" --replicas="$RESTORE_REPLICAS" | sed 's/^/      /'

echo
echo "[6/8] 等待告警 Resolved（上限 ${TIMEOUT_RESOLVED}s）"
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

# ---------------------------- 5. 通道投递计数增量 ----------------------------
echo
echo "[7/8] 各通道投递计数（累计值 → 增量）"
# ★ 这里有个必须等的竞态：Alertmanager 是「先标记 Resolved、再异步投递恢复通知」。
#   如果一检出 Resolved 就立刻取计数，恢复那条还没发出去 —— 症状是计数只 +1，
#   看起来像「两个通道只发出去一条」（本机 2026-09-13 现场就是这么被误读的）。
#   所以先等两个通道都出现增量，再多留 15s 让恢复通知落定。
WAITED=0
while [[ $WAITED -lt $TIMEOUT_NOTIFY ]]; do
  AFTER_TOTAL=$(notif_snapshot)
  d_e=$(( $(snap_get "$AFTER_TOTAL" email)   - $(snap_get "$BASE_TOTAL" email)   ))
  d_w=$(( $(snap_get "$AFTER_TOTAL" webhook) - $(snap_get "$BASE_TOTAL" webhook) ))
  [[ $d_e -ge 1 && $d_w -ge 1 ]] && break
  sleep 5; WAITED=$(( WAITED + 5 ))
done
sleep 15
AFTER_TOTAL=$(notif_snapshot)

D_EMAIL=$((   $(snap_get "$AFTER_TOTAL" email)   - $(snap_get "$BASE_TOTAL" email)   ))
D_WEBHOOK=$(( $(snap_get "$AFTER_TOTAL" webhook) - $(snap_get "$BASE_TOTAL" webhook) ))

{
  echo
  echo "== 通道投递计数增量 =="
  echo "（alertmanager_notifications_total；本项目只用 email 与 webhook 两个通道，"
  echo "  正常一次演练各 +2：告警 1 条 + 恢复 1 条）"
  printf "  %-9s %s → %s   增量 +%s\n" \
    email   "$(snap_get "$BASE_TOTAL" email)"   "$(snap_get "$AFTER_TOTAL" email)"   "$D_EMAIL"
  printf "  %-9s %s → %s   增量 +%s\n" \
    webhook "$(snap_get "$BASE_TOTAL" webhook)" "$(snap_get "$AFTER_TOTAL" webhook)" "$D_WEBHOOK"
  echo
  echo "  判定："
  if [[ $D_EMAIL   -ge 1 ]]; then echo "    ✓ 邮件通道已投递（+${D_EMAIL}）"
  else echo "    ✗ 邮件通道 0 投递 → 查 Alertmanager 日志里 integration=email 的报错"; fi
  if [[ $D_WEBHOOK -ge 1 ]]; then echo "    ✓ 钉钉通道已投递（+${D_WEBHOOK}）"
  else echo "    ✗ 钉钉通道 0 投递 → kubectl -n monitoring logs deploy/prometheus-webhook-dingtalk --tail=50"; fi
  echo
  echo "  完整快照（演练前 / 演练后）"
  printf '%s\n' "$BASE_TOTAL"  | sed 's/^/    前 /' | grep . || echo "    前 （空）"
  printf '%s\n' "$AFTER_TOTAL" | sed 's/^/    后 /' | grep . || echo "    后 （空）"
} | tee -a "$OUT"

# ---------------------------- 6. 精确投递时刻 --------------------------------
echo
echo "[8/8] 精确投递时刻（Alertmanager 日志，秒级 —— 回填文档就用这个数字）"
print_notify_timeline "$T_FAULT"
echo "      说明：这是 Alertmanager 把通知交给邮件服务器 / 转发组件的时刻"
echo "            （日志 ts 为 UTC，已换算本机时区）。收件人侧通常再晚 1~5 秒。"
echo "            邮箱没有秒、钉钉会把 5 分钟内的消息合并成一个时间分隔，"
echo "            所以不要用它们的界面时间去填表格。"

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
echo " —— 回填 docs/alerting.md §4 的数字 ——"
echo "   权威来源：上面 [8/8] 段「精确投递时刻」"
echo "     · 故障 → 邮件投递 = email   第一条的 +Ns"
echo "     · 故障 → 钉钉投递 = webhook 第一条的 +Ns（验收线 ≤120s）"
echo "   若日志已轮转取不到，用只读回填模式（不注入故障）："
echo "     bash ~/alert-drill.sh --report"
echo
echo "   收件人侧二次确认（可选，不算 KPI）："
echo "     · 邮箱：右键邮件 → 显示原始邮件 → Date 头（有秒）"
echo "     · 钉钉：悬停消息看发送时间"
echo "       ⚠️ 间隔 <5 分钟的多条消息会被合并到同一个时间分隔下，"
echo "          看起来像同一时刻发的 —— 别据此判断投递时刻"
echo
echo " 截图对应（docs/screenshots/README.md S4 段）："
echo "   13-alert-rule-fired.png  Prometheus → Alerts 页面，${ALERT_NAME} 为 FIRING"
echo "   14-alert-email.png       邮箱里的告警邮件（含时间）"
echo "   15-alert-dingtalk.png    钉钉机器人的告警消息（含时间）"
echo "   16-alert-recovered.png   恢复通知（邮件或钉钉任一即可）"
echo "=============================================================="
