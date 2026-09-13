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
#   收件人界面不能当秒级证据：邮箱只显示到**分钟**，钉钉桌面客户端也只到分钟。
#   那用 Alertmanager 日志行不行？——**首次投递成功是 Debug 级别，默认不打印**：
#     // notify/retry_stage.go
#     if i <= 1 { l.Debug("Notify success", ...) } else { l.Info("Notify success") }
#   健康投递走 Debug 分支，logLevel=info（默认）下 grep 整段日志零命中
#   —— 2026-09-13 在真机上就是这么翻车的，别再用日志取证（除非把 logLevel 调 debug）。
#   本脚本改用**自己采样 Alertmanager 的 /metrics**：演练期间每 2 秒直连它的端口取
#   alertmanager_notifications_total，记录每个通道第一次自增的时刻。精度 = 采样间隔，
#   与日志级别无关。采样落在 ${OUT}.samples，--report 也读它。
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
SAMPLE_PID=""         # 投递时刻采样进程（后台），收尾时杀掉
SAMPLE_INTERVAL=2     # 采样间隔（秒）＝ 投递时刻的时间精度

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

SAMPLES="${OUT}.samples"   # 投递时刻采样文件（与日志同目录，--report 复用它）

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

# --------------------- 投递时刻采样（不依赖日志级别） -------------------------
# 收件人界面为什么不能用：邮箱只显示到分钟；钉钉桌面客户端也只到分钟。
# 日志为什么不能用：见文件头——「首次投递成功」是 Debug 级别，默认不打印。
# 结论：自己采样 Alertmanager 的 /metrics（直连它的端口，不经 Prometheus 抓取间隔）。
sample_once() {
  local t
  t=$(now)
  curl -s -m 3 "http://127.0.0.1:${AM_PORT}/metrics" 2>/dev/null \
    | sed -n 's/^alertmanager_notifications_total{integration="\([^"]*\)"} \([0-9.eE+]*\).*/\1 \2/p' \
    | while read -r k v; do printf '%s\t%s\t%s\n' "$t" "$k" "$v" >> "$SAMPLES"; done
}

start_sampling() {
  : > "$SAMPLES"
  ( while :; do sample_once; sleep "$SAMPLE_INTERVAL"; done ) &
  SAMPLE_PID=$!
}

# 某通道的基线值（该通道的第一条样本 = 故障发生之前）
samples_base() {
  awk -F'\t' -v k="$1" '$2==k {print $3; exit}' "$SAMPLES" 2>/dev/null
}

# 基线之后第一次自增的时刻；$3 = epoch 下限（含），用于区分「告警」与「恢复」两次投递
samples_first_bump() {
  awk -F'\t' -v k="$1" -v b="$2" -v a="$3" \
    '$2==k && $3+0 > b+0 && $1+0 >= a+0 {print $1; exit}' "$SAMPLES" 2>/dev/null
}

# 打印投递时间线：时刻 / 通道 / 距故障 / 事件
# 参数：<故障 epoch> [<恢复 epoch>]
print_delivery_timeline() {
  local t0="$1" tr="${2:-}" ch b t1 t2 found=0
  if [[ ! -s "$SAMPLES" ]]; then
    echo "      （没有采样数据：${SAMPLES} 不存在或为空）"
    echo "      采样是演练期间后台进行的，请重跑一次 bash ~/alert-drill.sh"
    return 0
  fi
  printf "      %-9s %-8s %-8s %s\n" "时刻" "通道" "距故障" "事件"
  for ch in email webhook; do
    b=$(samples_base "$ch")
    [[ -z "$b" ]] && continue
    t1=$(samples_first_bump "$ch" "$b" "$t0")
    if [[ -n "$t1" ]]; then
      printf "      %-9s %-8s +%-7s 告警投递\n" "$(date -d "@$t1" +%H:%M:%S)" "$ch" "$(( t1 - t0 ))"
      found=1
    fi
    if [[ -n "$tr" ]]; then
      t2=$(samples_first_bump "$ch" "$b" "$tr")
      if [[ -n "$t2" ]]; then
        printf "      %-9s %-8s +%-7s 恢复投递\n" "$(date -d "@$t2" +%H:%M:%S)" "$ch" "$(( t2 - t0 ))"
        found=1
      fi
    fi
  done
  (( found == 0 )) && echo "      （这两个通道在本窗口内都没有观测到计数器自增）"
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
  [[ -n "${SAMPLE_PID:-}"  ]] && kill "$SAMPLE_PID"  2>/dev/null
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
  # 恢复时刻也取出来：有了它才能把「告警投递」与「恢复投递」两次增量分开
  TR_H=$(awk -F'\t' '$2=="fault-cleared" {print $1}' "$OUT" 2>/dev/null | tail -1)
  TR=""
  [[ -n "$TR_H" ]] && TR=$(date -d "$TR_H" +%s 2>/dev/null)
  echo "=============================================================="
  echo " 任务 7 投递时间线回填（--report，只读，不注入故障）"
  echo "--------------------------------------------------------------"
  echo " 时间基准 : ${T_FAULT_H}"
  echo "            （来自 ${OUT} 的 fault-injected 记录）"
  echo "=============================================================="
  echo " 采样文件 : ${SAMPLES}"
  echo "=============================================================="
  echo
  print_delivery_timeline "$T0" "$TR"
  echo
  echo " 取 email / webhook 各自「告警投递」行的 +Ns，即为"
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

# 启动后台采样：投递时刻的唯一证据来源（见文件头，不用日志是因为日志级别不对）
start_sampling
echo "      已启动投递时刻采样：每 ${SAMPLE_INTERVAL}s 直连 Alertmanager /metrics → ${SAMPLES}"

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
echo "[8/8] 精确投递时刻（计数器采样，精度 ±${SAMPLE_INTERVAL}s —— 回填文档就用这个）"
print_delivery_timeline "$T_FAULT" "${T_RESTORE:-}"
echo "      说明：这是 Alertmanager 把通知交出去的时刻，收件人侧通常再晚 1~5 秒。"
echo "            机制：演练期间每 ${SAMPLE_INTERVAL}s 采样 alertmanager_notifications_total，"
echo "            记下每个通道第一次自增的时刻。"
echo "            不用日志取证的原因：「首次投递成功」是 Debug 级别、默认不打印"
echo "            （源码 notify/retry_stage.go；2026-09-13 真机踩过，见脚本头注释）。"

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
echo "   采样文件留在 ${SAMPLES}，随时可只读重算（不注入故障）："
echo "     bash ~/alert-drill.sh --report"
echo
echo "   收件人侧二次确认（可选，不算 KPI）："
echo "     · 邮箱：右键邮件 → 显示原始邮件 → Date 头（有秒）"
echo "     · 钉钉：悬停消息看发送时间"
echo "       ⚠️ 两个界面都**只到分钟**（实测：钉钉桌面客户端显示 20:40 / 20:43），"
echo "          所以不要用界面时间算「故障 → 触达」的秒数，那是秒级 KPI"
echo "          （2026-09-13 修正：此前写的「钉钉会合并 5 分钟内的消息」不成立，
echo            那张图里显示的是消息组的时间标签，不是每条消息各自的时间）"
echo
echo " 截图对应（docs/screenshots/README.md S4 段）："
echo "   13-alert-rule-fired.png  Prometheus → Alerts 页面，${ALERT_NAME} 为 FIRING"
echo "   14-alert-email.png       邮箱里的告警邮件（含时间）"
echo "   15-alert-dingtalk.png    钉钉机器人的告警消息（含时间）"
echo "   16-alert-recovered.png   恢复通知（邮件或钉钉任一即可）"
echo "=============================================================="
