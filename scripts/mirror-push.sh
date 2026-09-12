#!/usr/bin/env bash
# =============================================================================
# mirror-push.sh — 镜像中转脚本（本机 → 阿里云 ACR）
#
# 用途：大陆 ECS 无法直连 gcr.io / registry.k8s.io。本机配好代理后拉取上游镜像，
#       重新打 tag 为 ACR 地址并推送，集群侧再从 ACR 拉取。
#
# 前置条件：
#   1. 本机已安装 Docker Desktop，且已配置代理（Settings → Resources → Proxies）
#      → http://127.0.0.1:7897
#   2. 已登录 ACR：docker login registry.cn-shenzhen.aliyuncs.com
#   3. bash 环境（Windows 下用 Git Bash 运行）
#
# 用法：
#   bash scripts/mirror-push.sh                 # 推送全部镜像
#   bash scripts/mirror-push.sh --dry-run       # 只打印计划，不实际执行
#   bash scripts/mirror-push.sh --only frontend # 只处理单个服务（可重复指定）
#   bash scripts/mirror-push.sh --version v0.10.0
#
# 注意：脚本不会自动 docker login。ACR 凭据请自行登录，避免密码写入仓库。
# =============================================================================

set -euo pipefail

# ----------------------------- 配置区（按需修改）-----------------------------

# ACR 地址必须与 ECS 同地域，否则跨地域拉取慢且计费。
# 深圳: registry.cn-shenzhen.aliyuncs.com   杭州: registry.cn-hangzhou.aliyuncs.com
# 北京: registry.cn-beijing.aliyuncs.com    上海: registry.cn-shanghai.aliyuncs.com
ACR_REGISTRY="${ACR_REGISTRY:-registry.cn-shenzhen.aliyuncs.com}"
ACR_NAMESPACE="${ACR_NAMESPACE:-zhenlin}"

# Online Boutique 上游仓库与版本
UPSTREAM_REPO="gcr.io/google-samples/microservices-demo"
BOUTIQUE_VERSION="${BOUTIQUE_VERSION:-v0.10.0}"

# Online Boutique 的 11 个微服务（tag 统一跟随 BOUTIQUE_VERSION）
SERVICES=(
  frontend cartservice productcatalogservice currencyservice paymentservice
  shippingservice emailservice checkoutservice recommendationservice
  adservice loadgenerator
)

# 上游为 docker.io 的附加依赖镜像（tag 固定）
EXTRA_IMAGES=(
  "redis:docker.io/library/redis:alpine"
)

# ------------------------------- 参数解析 -----------------------------------

DRY_RUN=0
ONLY_FILTER=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --only)     ONLY_FILTER+=("$2"); shift 2 ;;
    --version)  BOUTIQUE_VERSION="$2"; shift 2 ;;
    --registry) ACR_REGISTRY="$2"; shift 2 ;;
    --namespace) ACR_NAMESPACE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

# 参数解析完成后统一构建镜像清单，元素格式为「服务名:上游完整镜像地址」
IMAGES=()
for svc in "${SERVICES[@]}"; do
  IMAGES+=("${svc}:${UPSTREAM_REPO}/${svc}:${BOUTIQUE_VERSION}")
done
for extra in "${EXTRA_IMAGES[@]}"; do
  IMAGES+=("$extra")
done

# ------------------------------- 前置检查 -----------------------------------

echo "=============================================="
echo " 镜像中转：上游 → 阿里云 ACR"
echo "=============================================="
echo " ACR 仓库   : ${ACR_REGISTRY}/${ACR_NAMESPACE}"
echo " 业务版本   : ${BOUTIQUE_VERSION}"
echo " 镜像数量   : ${#IMAGES[@]}"
echo " 模式       : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN（不实际执行）' || echo '实际执行')"
echo "=============================================="
echo

# DRY-RUN 只做计划推演，不依赖 Docker 环境
if [[ $DRY_RUN -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[错误] 未找到 docker 命令。请确认 Docker Desktop 已安装且已加入 PATH。" >&2
    echo "       若刚安装 Docker Desktop，请重新打开终端（PATH 需刷新）。" >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "[错误] Docker 守护进程未运行。请先启动 Docker Desktop。" >&2
    exit 1
  fi
fi

# ------------------------------- 主流程 -------------------------------------

SUCCEED=0
FAILED=0
FAILED_LIST=()

should_process() {
  local name="$1"
  [[ ${#ONLY_FILTER[@]} -eq 0 ]] && return 0
  local f
  for f in "${ONLY_FILTER[@]}"; do
    [[ "$f" == "$name" ]] && return 0
  done
  return 1
}

for entry in "${IMAGES[@]}"; do
  name="${entry%%:*}"
  src="${entry#*:}"
  # 上游 tag 形如 v0.10.0 / alpine，直接复用为目标仓库的 tag
  tag="${src##*:}"
  dst="${ACR_REGISTRY}/${ACR_NAMESPACE}/${name}:${tag}"

  should_process "$name" || continue

  echo "----------------------------------------------"
  echo "[${name}]"
  echo "  上游: ${src}"
  echo "  目标: ${dst}"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  动作: docker pull → docker tag → docker push（已跳过）"
    continue
  fi

  if ! docker pull "$src"; then
    echo "  [失败] 拉取失败。排查：(1) Docker Desktop 代理是否开启 (2) 该镜像 tag 是否存在"
    FAILED=$((FAILED + 1)); FAILED_LIST+=("$src"); continue
  fi

  docker tag "$src" "$dst" || { FAILED=$((FAILED+1)); FAILED_LIST+=("$src"); continue; }

  if ! docker push "$dst"; then
    echo "  [失败] 推送失败。排查：(1) 是否已 docker login ${ACR_REGISTRY} (2) 命名空间 ${ACR_NAMESPACE} 是否存在 (3) 仓库是否设为私有"
    FAILED=$((FAILED + 1)); FAILED_LIST+=("$dst"); continue
  fi

  echo "  [成功]"
  SUCCEED=$((SUCCEED + 1))
done

# ------------------------------- 汇总 ---------------------------------------

echo
echo "=============================================="
echo " 完成：成功 ${SUCCEED} 个，失败 ${FAILED} 个"
if [[ $FAILED -gt 0 ]]; then
  echo " 失败清单："
  for f in "${FAILED_LIST[@]}"; do echo "   - $f"; done
fi
echo "=============================================="
echo
echo "下一步：替换部署清单中的镜像地址"
echo "  sed -i 's|gcr.io/google-samples/microservices-demo|${ACR_REGISTRY}/${ACR_NAMESPACE}|g' kubernetes-manifests.yaml"
echo "  sed -i 's|redis:alpine|${ACR_REGISTRY}/${ACR_NAMESPACE}/redis:alpine|g' kubernetes-manifests.yaml"
echo

[[ $FAILED -eq 0 ]]
