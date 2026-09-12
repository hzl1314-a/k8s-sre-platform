#!/usr/bin/env bash
# =============================================================================
# 校验镜像在候选镜像站上的可用性
#
# 为什么不只看 HTTP 401：
#   匿名请求 /v2/<repo>/manifests/<tag> 一律先返回 401（认证挑战），
#   它只证明镜像站活着，**不证明镜像存在**。必须走完
#   「取 token → 带 token 请求 manifest」才能看到真实的 200 / 404。
#
# 用法:
#   bash scripts/check-images.sh docker.1ms.run grafana/grafana:13.2.1-distroless
#   bash scripts/check-images.sh quay.m.daocloud.io calico/node:v3.28.0 tigera/operator:v1.34.0
#
# 注意: 本脚本只验证 manifest（秒级），不下载 layer。
#       真实下载速度请用: crictl pull <镜像站>/<repo>:<tag>
# =============================================================================
set -uo pipefail

ACCEPT="application/vnd.oci.image.index.v1+json,\
application/vnd.docker.distribution.manifest.list.v2+json,\
application/vnd.oci.image.manifest.v1+json,\
application/vnd.docker.distribution.manifest.v2+json"

if [[ $# -lt 2 ]]; then
  echo "用法: bash $0 <镜像站> <repo:tag> [repo:tag ...]" >&2
  echo "示例: bash $0 docker.1ms.run grafana/loki:3.6.11 grafana/promtail:3.5.1" >&2
  exit 1
fi

HOST="$1"; shift

# 某些网络环境下沙箱代理会干扰直连，这里清掉
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

probe() {
  local repo="$1" tag="$2"
  local hdr realm service token code

  hdr=$(curl -sS -m 15 -D - -o /dev/null -H "Accept: ${ACCEPT}" \
        "https://${HOST}/v2/${repo}/manifests/${tag}" 2>/dev/null | tr -d '\r')
  realm=$(printf '%s' "$hdr" | sed -nE 's/.*realm="([^"]+)".*/\1/p')
  service=$(printf '%s' "$hdr" | sed -nE 's/.*service="([^"]+)".*/\1/p')

  if [[ -z "$realm" ]]; then
    printf '  %-58s ✗ 无认证挑战（该站可能不支持此镜像）\n' "${HOST}/${repo}:${tag}"
    return
  fi
  case "$realm" in http*) ;; *) realm="https://${realm}" ;; esac

  token=$(curl -sS -m 20 "${realm}?service=${service}&scope=repository:${repo}:pull" 2>/dev/null \
          | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [[ -z "$token" ]]; then
    printf '  %-58s ✗ token 获取失败\n' "${HOST}/${repo}:${tag}"
    return
  fi

  code=$(curl -sS -m 25 -o /dev/null -w '%{http_code}' \
         -H "Authorization: Bearer ${token}" -H "Accept: ${ACCEPT}" \
         "https://${HOST}/v2/${repo}/manifests/${tag}" 2>/dev/null)
  printf '  %-58s HTTP %s\n' "${HOST}/${repo}:${tag}" "$code"
}

echo "=== ${HOST} 上的镜像可用性 ==="
for ref in "$@"; do
  probe "${ref%:*}" "${ref##*:}"
done
