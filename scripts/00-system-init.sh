#!/usr/bin/env bash
# =============================================================================
# 00-system-init.sh — 任务 1.3 系统初始化（每台 ECS 各执行一次）
#
# 用法（把 IP 换成你实际的内网 IP）：
#   # 在 k8s-cp 上
#   sudo bash 00-system-init.sh k8s-cp 172.16.0.11 172.16.0.12 172.16.0.13
#   # 在 k8s-w1 上
#   sudo bash 00-system-init.sh k8s-w1 172.16.0.11 172.16.0.12 172.16.0.13
#   # 在 k8s-w2 上
#   sudo bash 00-system-init.sh k8s-w2 172.16.0.11 172.16.0.12 172.16.0.13
#
# 参数：<本机主机名> <cp内网IP> <w1内网IP> <w2内网IP>
#
# 脚本是幂等的：重复执行不会产生重复内容，出错了改完重跑即可。
#
# 做完这 4 件事：
#   1. 设置主机名
#   2. 三台互写 /etc/hosts（用内网 IP）
#   3. 关闭 swap（K8s 硬性要求）
#   4. 安装并启用 chrony 时间同步（证书校验依赖节点时间一致）
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[信息]${NC} $*"; }
ok()    { echo -e "${GREEN}[完成]${NC} $*"; }
warn()  { echo -e "${YELLOW}[注意]${NC} $*"; }
fail()  { echo -e "${RED}[失败]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
  fail "请用 root 权限运行：sudo bash $0 <本机主机名> <cp内网IP> <w1内网IP> <w2内网IP>"
  exit 1
fi

MY_HOST="${1:-}"
CP_IP="${2:-}"
W1_IP="${3:-}"
W2_IP="${4:-}"

if [[ -z "$MY_HOST" || -z "$CP_IP" || -z "$W1_IP" || -z "$W2_IP" ]]; then
  fail "参数不完整。"
  echo
  echo "用法：sudo bash $0 <本机主机名> <cp内网IP> <w1内网IP> <w2内网IP>"
  echo "示例：sudo bash $0 k8s-w1 172.16.0.11 172.16.0.12 172.16.0.13"
  exit 1
fi

if [[ "$MY_HOST" != "k8s-cp" && "$MY_HOST" != "k8s-w1" && "$MY_HOST" != "k8s-w2" ]]; then
  fail "主机名必须是 k8s-cp / k8s-w1 / k8s-w2 之一，当前为：${MY_HOST}"
  exit 1
fi

echo "=============================================="
echo " 系统初始化"
echo "----------------------------------------------"
echo " 本机主机名 : ${MY_HOST}"
echo " cp 内网 IP : ${CP_IP}"
echo " w1 内网 IP : ${W1_IP}"
echo " w2 内网 IP : ${W2_IP}"
echo "=============================================="
echo

# ---------------------------------------------------------------------------
# 1. 主机名
# ---------------------------------------------------------------------------
info "步骤 1/4：设置主机名"
hostnamectl set-hostname "$MY_HOST"
ok "主机名已设为 ${MY_HOST}（当前会话的提示符要重新登录才会变，不影响正确性）"

# ---------------------------------------------------------------------------
# 2. /etc/hosts 三台互写
# 用内网 IP：集群内部通信全走内网，免流量费且低延迟
# ---------------------------------------------------------------------------
info "步骤 2/4：配置 /etc/hosts"

declare -A NODE_MAP=(
  ["k8s-cp"]="$CP_IP"
  ["k8s-w1"]="$W1_IP"
  ["k8s-w2"]="$W2_IP"
)

for name in k8s-cp k8s-w1 k8s-w2; do
  ip="${NODE_MAP[$name]}"

  # 幂等处理：先删掉这个主机名的旧记录（无论 IP 是什么），再写入正确的一条
  sed -i -E "/[[:space:]]${name}[[:space:]]*$/d" /etc/hosts

  # 顺带删掉可能残留的 IP 重复项
  sed -i -E "/^${ip}[[:space:]]/d" /etc/hosts

  echo -e "${ip}\t${name}" >> /etc/hosts
done

ok "/etc/hosts 已写入三条记录："
grep -E "k8s-(cp|w1|w2)" /etc/hosts | sed 's/^/       /'

# ---------------------------------------------------------------------------
# 3. 关闭 swap
# ---------------------------------------------------------------------------
info "步骤 3/4：关闭 swap"

swapoff -a
# 注释掉 fstab 里的 swap 行，防止重启后又被挂上
sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

if [[ "$(swapon --show | wc -l)" -eq 0 ]]; then
  ok "swap 已关闭，且 /etc/fstab 已注释（重启后不会恢复）"
else
  warn "swap 似乎仍在启用，请检查：swapon --show"
fi

# ---------------------------------------------------------------------------
# 4. 时间同步
# ---------------------------------------------------------------------------
info "步骤 4/4：安装并启用 chrony 时间同步"
# K8s 组件之间靠证书互相认证，节点时间偏差过大会直接导致 TLS 握手失败
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq chrony
systemctl enable --now chrony >/dev/null 2>&1

# 顺带装上后面要用的基础工具，省得来回 apt install
apt-get install -y -qq curl wget vim net-tools jq bash-completion >/dev/null 2>&1

ok "chrony 已启动并设为开机自启"

echo
echo "=============================================="
echo " 验收结果"
echo "----------------------------------------------"

# 主机名
echo " 1) 主机名 : $(hostname)"

# swap
SWAP_LINE="$(free -h | grep -i '^Swap:')"
echo " 2) ${SWAP_LINE}"
if echo "$SWAP_LINE" | grep -qE '0B|0B\s'; then
  echo "    -> swap 已关闭"
else
  echo -e "    ${YELLOW}-> 请确认 Total 是否为 0B${NC}"
fi

# 时间同步
if timedatectl | grep -q "synchronized: yes"; then
  echo " 3) 时间同步 : 已同步"
else
  echo " 3) 时间同步 : 尚未同步（chrony 刚启动需等 1-2 分钟，稍后重跑 timedatectl 确认）"
fi

# hosts 连通性（本机只 ping 其他节点，避免自己 ping 自己没意义）
echo " 4) hosts 连通性测试（对端节点）："
for name in k8s-cp k8s-w1 k8s-w2; do
  [[ "$name" == "$MY_HOST" ]] && continue
  if ping -c 1 -W 2 "$name" >/dev/null 2>&1; then
    echo -e "    ${GREEN}OK${NC}   ${name}"
  else
    echo -e "    ${RED}FAIL${NC} ${name} —— 检查安全组是否放行了内网网段全端口"
  fi
done

echo "=============================================="
echo
echo " 下一步：在另外两台机器上执行同样的命令（只改第一个参数）。"
echo " 三台都通过后，进行任务 2：bash 10-install-runtime.sh"
echo
