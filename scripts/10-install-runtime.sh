#!/usr/bin/env bash
# =============================================================================
# 10-install-runtime.sh — 任务 2 containerd 与 kubeadm 安装（每台 ECS 各执行一次）
#
# 用法：
#   sudo bash 10-install-runtime.sh
#
# 可选环境变量：
#   ALIYUN_MIRROR  阿里云专属镜像加速地址（docker.io 用，ECS 上走内网免流量）
#                  取法：容器镜像服务控制台 → 镜像工具 → 镜像加速器
#                  形如 https://xxxxxxx.mirror.aliyuncs.com
#                  不填则 docker.io 也走 DaoCloud 公共镜像站（能跑，但慢一些）
#   K8S_MINOR      Kubernetes 次版本号，默认 1.31
#
# 示例：
#   sudo ALIYUN_MIRROR="https://abc123.mirror.aliyuncs.com" bash 10-install-runtime.sh
#
# 脚本是幂等的，中途失败可修正后重跑。
#
# 做完这些：
#   1. 内核模块 overlay / br_netfilter + sysctl 转发参数
#   2. containerd（systemd cgroup 驱动 + certs.d 镜像加速）
#   3. kubeadm / kubelet / kubectl（阿里云源）并锁版本
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info() { echo -e "${BLUE}[信息]${NC} $*"; }
ok()   { echo -e "${GREEN}[完成]${NC} $*"; }
warn() { echo -e "${YELLOW}[注意]${NC} $*"; }
fail() { echo -e "${RED}[失败]${NC} $*"; }
step() { echo; echo -e "${BLUE}==== $* ====${NC}"; }

if [[ $EUID -ne 0 ]]; then
  fail "请用 root 权限运行：sudo bash $0"
  exit 1
fi

K8S_MINOR="${K8S_MINOR:-1.31}"
ALIYUN_MIRROR="${ALIYUN_MIRROR:-}"

echo "=============================================="
echo " containerd 与 kubeadm 安装"
echo "----------------------------------------------"
echo " 主机名        : $(hostname)"
echo " K8s 版本线    : v${K8S_MINOR}"
if [[ -n "$ALIYUN_MIRROR" ]]; then
  echo " 阿里云加速    : ${ALIYUN_MIRROR}"
else
  echo " 阿里云加速    : 未提供（docker.io 将走 DaoCloud 公共镜像）"
fi
echo "=============================================="

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. 内核前置
# ---------------------------------------------------------------------------
step "步骤 1/3：内核模块与 sysctl"

# overlay：containerd 的存储驱动，镜像分层靠它
# br_netfilter：让经过网桥的流量也能被 iptables 规则匹配（Service 转发必需）
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

if lsmod | grep -qE '^overlay' && lsmod | grep -qE '^br_netfilter'; then
  ok "内核模块已加载：overlay, br_netfilter"
else
  fail "内核模块加载失败，请检查：lsmod | grep -E 'overlay|br_netfilter'"
  exit 1
fi

# ip_forward：Pod 跨节点通信的基础
# bridge-nf-call-iptables：不设这一项，Service ClusterIP 会完全无法访问（经典坑）
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system >/dev/null 2>&1
ok "sysctl 参数已生效："
echo "       bridge-nf-call-iptables = $(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo "       ip_forward              = $(sysctl -n net.ipv4.ip_forward)"

# ---------------------------------------------------------------------------
# 2. containerd
# ---------------------------------------------------------------------------
step "步骤 2/3：containerd"

apt-get update -qq
apt-get install -y -qq containerd curl gnupg >/dev/null 2>&1

if ! command -v containerd >/dev/null 2>&1; then
  fail "containerd 安装失败"
  exit 1
fi

ok "containerd 已安装：$(containerd --version | awk '{print $3}')"

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# --- 关键点 1：cgroup 驱动必须与 kubelet 一致（都用 systemd）---
# 不一致的后果：节点永远停在 NotReady，kubelet 日志报
#   "misconfiguration: kubelet cgroup driver: cgroupfs is different from docker cgroup driver: systemd"
if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
  sed -i 's/^\(\s*\)SystemdCgroup = false/\1SystemdCgroup = true/' /etc/containerd/config.toml
  ok "cgroup 驱动已改为 systemd"
else
  ok "cgroup 驱动已是 systemd（或格式不同，请人工确认 grep SystemdCgroup /etc/containerd/config.toml）"
fi

# --- 关键点 2：启用 certs.d 按仓库配置镜像加速 ---
# 用 certs.d + hosts.toml 而不是旧式 registry.mirrors：
#   官方推荐、containerd 1.6/1.7 都支持、且不受 config.toml 版本（v2/v3）差异影响
if grep -q 'config_path = ""' /etc/containerd/config.toml; then
  sed -i 's|^\(\s*\)config_path = ""|\1config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
  ok "config_path 已设为 /etc/containerd/certs.d"
elif grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
  ok "config_path 已是 /etc/containerd/certs.d"
else
  warn "未能自动设置 config_path，请手工在 config.toml 的 registry 段下添加："
  warn '  config_path = "/etc/containerd/certs.d"'
fi

# 写各仓库的加速配置
mkdir -p /etc/containerd/certs.d/{docker.io,quay.io,gcr.io,registry.k8s.io,ghcr.io}

# docker.io：优先阿里云专属加速（ECS 内网直连，免流量、最快），DaoCloud 兜底
{
  echo 'server = "https://registry-1.docker.io"'
  echo
  if [[ -n "$ALIYUN_MIRROR" ]]; then
    echo "[host.\"${ALIYUN_MIRROR}\"]"
    echo '  capabilities = ["pull", "resolve"]'
    echo
  fi
  echo '[host."https://docker.m.daocloud.io"]'
  echo '  capabilities = ["pull", "resolve"]'
} > /etc/containerd/certs.d/docker.io/hosts.toml

# quay.io：Calico 全系镜像（大陆直连基本失败）
cat > /etc/containerd/certs.d/quay.io/hosts.toml <<'EOF'
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# gcr.io：Online Boutique 业务镜像
cat > /etc/containerd/certs.d/gcr.io/hosts.toml <<'EOF'
server = "https://gcr.io"

[host."https://gcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# registry.k8s.io：kubeadm 控制面镜像、metrics-server
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"

[host."https://k8s.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# ghcr.io：备用
cat > /etc/containerd/certs.d/ghcr.io/hosts.toml <<'EOF'
server = "https://ghcr.io"

[host."https://ghcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

ok "certs.d 加速配置已写入 5 个仓库"

systemctl restart containerd
systemctl enable containerd >/dev/null 2>&1

if systemctl is-active --quiet containerd; then
  ok "containerd 已重启并设为开机自启"
else
  fail "containerd 启动失败：journalctl -u containerd -n 50"
  exit 1
fi

# --- 实测加速是否真的生效（跳过这步，后面出问题会很被动）---
step "步骤 2b：验证镜像加速"
apt-get install -y -qq cri-tools >/dev/null 2>&1

if command -v crictl >/dev/null 2>&1; then
  echo " 正在测试拉取 registry.k8s.io/pause:3.10 ..."
  if crictl pull registry.k8s.io/pause:3.10 >/dev/null 2>&1; then
    ok "镜像加速生效（registry.k8s.io 已能拉取）"
  else
    warn "拉取失败。DaoCloud 是懒加载，缓存未命中时第一次可能超时，建议重试一次："
    warn "  crictl pull registry.k8s.io/pause:3.10"
    warn "仍失败则检查 hosts.toml 的 server 字段是否被误改成镜像站地址（应为原始仓库地址）"
  fi
else
  warn "cri-tools 安装失败，跳过镜像验证（不影响后续步骤）"
fi

# ---------------------------------------------------------------------------
# 3. kubeadm / kubelet / kubectl
# ---------------------------------------------------------------------------
step "步骤 3/3：kubeadm / kubelet / kubectl"

apt-get install -y -qq apt-transport-https ca-certificates >/dev/null 2>&1
mkdir -p /etc/apt/keyrings

# 阿里云新版 K8s 源：GPG key 在版本目录下的 Release.key
# 注意旧教程里的 kubernetes-new/apt/doc/apt-key.gpg 路径已失效（会 404）
KEY_URL="https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_MINOR}/deb/Release.key"
if curl -fsSL "$KEY_URL" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
  ok "GPG 公钥已导入"
else
  fail "下载 GPG 公钥失败：${KEY_URL}"
  fail "请检查网络，或改用官方源 pkgs.k8s.io"
  exit 1
fi

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq

# 先看看仓库里有哪些可用版本——这决定了后面 kubeadm init 要用哪个版本号
echo " 仓库中可用的 kubeadm 版本（前 5 个）："
apt-cache madison kubeadm 2>/dev/null | head -5 | sed 's/^/       /'

if ! apt-get install -y -qq kubelet kubeadm kubectl >/dev/null 2>&1; then
  fail "kubeadm/kubelet/kubectl 安装失败"
  fail "常见原因：源里没有 v${K8S_MINOR}，试试 K8S_MINOR=1.32 重跑"
  exit 1
fi

# 锁版本：防止 apt upgrade 把 K8s 组件升到不兼容的版本（生产必做）
apt-mark hold kubelet kubeadm kubectl >/dev/null 2>&1

ok "kubeadm / kubelet / kubectl 已安装并锁版本"

# ---------------------------------------------------------------------------
# 验收
# ---------------------------------------------------------------------------
echo
echo "=============================================="
echo " 验收结果"
echo "----------------------------------------------"

KV="$(kubeadm version -o short 2>/dev/null || echo '获取失败')"
echo " 1) kubeadm 版本 : ${KV}"
echo " 2) kubelet 版本 : $(kubelet --version 2>/dev/null | awk '{print $2}')"
echo " 3) kubectl 版本 : $(kubectl version --client 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' | head -1)"
echo " 4) containerd   : $(systemctl is-active containerd)"
echo " 5) cgroup 驱动  : $(grep -m1 'SystemdCgroup' /etc/containerd/config.toml | tr -d ' ')"
echo " 6) 内核模块     : $(lsmod | grep -cE '^overlay|^br_netfilter')/2 个已加载"
echo " 7) 版本锁定     : $(apt-mark showhold | tr '\n' ' ')"

echo "=============================================="
echo
echo " 提示：此时 kubelet 是 inactive (dead)，这是正常的——"
echo "      它要等 kubeadm init 写入配置后才会启动。"
echo
echo " 下一步：三台都跑通后，在 k8s-cp 上执行 kubeadm init（见 docs/setup-cluster.md 3.1）"
echo
