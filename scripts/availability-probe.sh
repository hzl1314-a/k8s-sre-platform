#!/usr/bin/env bash
# =============================================================================
# availability-probe.sh — 服务可用性连续探测
#
# 用途：故障演练期间以固定频率请求入口地址，记录「时间戳 + HTTP 状态码 + 耗时」，
#       用连续数据证明「节点宕机期间服务未中断」——这是演练留证的核心材料。
#
# 用法：
#   bash scripts/availability-probe.sh http://<入口IP>:30080/            # 每秒 1 次，持续到 Ctrl+C
#   bash scripts/availability-probe.sh http://<IP>:30080/ -i 0.5 -o probe.log
#   bash scripts/availability-probe.sh http://<IP>:30080/ -d 600         # 持续 600 秒
#
# 输出格式（每行一条，便于后续 grep/awk 统计）：
#   2026-09-12T16:00:01+08:00  200  0.021
#
# 演练结束后统计：
#   awk '{print $2}' probe.log | sort | uniq -c          # 状态码分布
#   grep -c ' 200 ' probe.log                            # 200 次数
#   grep -v ' 200 ' probe.log                            # 所有非 200 记录（异常时刻）
# =============================================================================

set -uo pipefail

URL="${1:-}"
INTERVAL=1
DURATION=0
OUTPUT="probe.log"

usage() {
  sed -n '2,20p' "$0"
  exit 1
}

[[ -z "$URL" ]] && usage
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -d|--duration) DURATION="$2"; shift 2 ;;
    -o|--output)   OUTPUT="$2";   shift 2 ;;
    -h|--help)     usage ;;
    *) echo "未知参数: $1" >&2; usage ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "[错误] 未找到 curl。" >&2
  exit 1
fi

echo "=============================================="
echo " 可用性探测"
echo "----------------------------------------------"
echo " 目标   : ${URL}"
echo " 间隔   : ${INTERVAL}s"
echo " 时长   : $([[ $DURATION -eq 0 ]] && echo '不限（Ctrl+C 停止）' || echo "${DURATION}s")"
echo " 输出   : ${OUTPUT}"
echo "=============================================="
echo " 提示：请保持本窗口运行；演练期间不要关闭。"
echo

START_TS=$(date +%s)
TOTAL=0
OK=0
BAD=0

# -d 是「持续秒数」，这里换算成请求次数，用计数控制循环。
# 不用 wall clock 判断的原因：不同平台 sleep 精度不同（Windows/MSYS 下每次约多 0.1~0.3s），
# 用时间判断会少跑若干次，而演练要求的是「稳定每秒一次」的连续证据。
MAX_COUNT=0
if [[ $DURATION -gt 0 ]]; then
  MAX_COUNT=$(awk -v d="$DURATION" -v i="$INTERVAL" 'BEGIN{printf "%d", (d/i)+0.5}')
fi

cleanup() {
  local end_ts elapsed
  end_ts=$(date +%s)
  elapsed=$((end_ts - START_TS))
  echo
  echo "=============================================="
  echo " 探测结束"
  echo "----------------------------------------------"
  echo " 总请求数 : ${TOTAL}"
  echo " 200 响应 : ${OK}"
  if [[ $TOTAL -gt 0 ]]; then
    awk -v ok="$OK" -v total="$TOTAL" 'BEGIN{printf " 可用率   : %.2f%%\n", ok/total*100}'
  fi
  echo " 非 200   : ${BAD}"
  echo " 持续时间 : ${elapsed}s"
  echo " 数据文件 : ${OUTPUT}"
  echo "=============================================="
  if [[ $BAD -gt 0 ]]; then
    echo " 异常记录（前 20 条）："
    grep -v ' 200 ' "$OUTPUT" | head -20 || true
  fi
  exit 0
}
trap cleanup INT TERM

: > "$OUTPUT"

while true; do
  if [[ $MAX_COUNT -gt 0 && $TOTAL -ge $MAX_COUNT ]]; then
    break
  fi

  ts=$(date +%Y-%m-%dT%H:%M:%S%:z)
  # -o /dev/null 丢弃正文；-w 只取状态码与总耗时；--max-time 防止演练期间挂死。
  # 用 awk 按字段取值而不是 read 切分：curl 在 Windows 下输出的字段数可能多于预期，
  # read 会把多余字段全塞进最后一个变量，导致耗时字段被污染。
  raw=$(curl -s -o /dev/null \
              --max-time 5 \
              -w '%{http_code} %{time_total}' \
              "$URL" 2>/dev/null || echo "000 0")
  code=$(printf '%s' "$raw" | awk '{print $1}')
  time_total=$(printf '%s' "$raw" | awk '{print $2}')
  [[ -z "$code" ]] && code="000"
  [[ -z "$time_total" ]] && time_total="0"

  TOTAL=$((TOTAL + 1))
  if [[ "$code" == "200" ]]; then
    OK=$((OK + 1))
  else
    BAD=$((BAD + 1))
  fi

  printf '%s\t%s\t%s\n' "$ts" "$code" "$time_total" >> "$OUTPUT"

  # 终端实时回显：异常行标红提示，正常行用点号滚动
  if [[ "$code" == "200" ]]; then
    printf '.'
  else
    printf '\n[%s] 异常状态码 %s (耗时 %ss)\n' "$ts" "$code" "$time_total"
  fi

  sleep "$INTERVAL"
done

cleanup
