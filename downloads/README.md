# downloads — 预下载的外部清单

本目录存放**本机通过代理预先拉取**的上游清单文件。这些文件在大陆 ECS 上直接 `curl`
会失败或超时，所以在开发机下好再 `scp` 上传，是这条链路里最省事的做法。

> 本目录的 `*.yaml` 不入 Git（体积大且可重新获取），只保留本说明文件。

## 文件清单

| 文件 | 来源 | 版本 | 用途 |
|---|---|---|---|
| `tigera-operator.yaml` | `projectcalico/calico/manifests/tigera-operator.yaml` | v3.28.0 | Calico Operator 与 CRD（任务 3.2）。**已改镜像** → `quay.m.daocloud.io/tigera/operator:v1.34.0` |
| `calico-custom-resources.yaml` | `projectcalico/calico/manifests/custom-resources.yaml` | v3.28.0 | Calico Installation 配置（任务 3.2）。**已改镜像** → 新增 `spec.registry: quay.m.daocloud.io` |
| `tigera-operator.yaml.upstream-backup` | 上游原始文件 | v3.28.0 | 改动前的备份，便于回溯 |
| `kubernetes-manifests.yaml` | `GoogleCloudPlatform/microservices-demo/release/kubernetes-manifests.yaml` | v0.10.0 | Online Boutique 全部业务负载（任务 4）。**待改**：镜像前缀需替换 |
| `metrics-server-components.yaml` | `kubernetes-sigs/metrics-server` release asset | v0.7.2 | 原始版本，**未经修改**（任务 8） |
| `metrics-server-components-patched.yaml` | 本仓库基于 v0.7.2 生成 | v0.7.2 | 已追加 `--kubelet-insecure-tls`，自建集群直接可用（任务 8） |
| `helm-v3.16.3-linux-amd64.tar.gz` | Helm 官方 `get.helm.sh` | v3.16.3 | helm 客户端 Linux 版。**ECS 上没装 helm，必须手动装**（任务 5 起要用） |
| `traefik-41.5.0.tgz` | `traefik.github.io/charts` | chart 41.5.0 / Traefik v3.7.13 | Traefik 入口控制器（任务 5） |
| `traefik-index.yaml` | 同上 | — | chart 仓库索引，用于查可用版本与 tgz 真实地址 |

> **关于 traefik chart 的版本**：计划文档里写的 `28.0.0` 已过时（2026 年最新是 41.5.0）。
> chart 从 28 → 41 有**两处破坏性结构变化**，照抄老 values 会被静默忽略：
>
> | 配置 | chart 28.x | chart 41.x |
> |---|---|---|
> | Service 类型 | `service.type` | **`service.spec.type`** |
> | 日志 | `logs.general.level` / `logs.access.enabled` | **`log.level` / `accessLog.enabled`** |
>
> `manifests/ingress/traefik-values.yaml` 已按 41.5.0 修正。
> chart 的 tgz 地址是 `https://traefik.github.io/charts/traefik/traefik-<版本>.tgz`
> （注意中间多一层 `traefik/` 目录，少了会 404）。

## crds/ — 自定义资源的 schema（任务 7 起新增）

`scripts/validate-crd-fields.py` 需要 CRD 的 schema 才能校验清单字段。
**权威来源是集群上真实安装的那份**，不是上游 GitHub 的（上游可能比集群新或旧）：

```bash
mkdir -p downloads/crds
kubectl get crd alertmanagerconfigs.monitoring.coreos.com -o yaml > downloads/crds/alertmanagerconfigs.yaml
kubectl get crd prometheusrules.monitoring.coreos.com    -o yaml > downloads/crds/prometheusrules.yaml
kubectl get crd servicemonitors.monitoring.coreos.com    -o yaml > downloads/crds/servicemonitors.yaml
```

用法：

```bash
python3 scripts/validate-crd-fields.py \
  --crd downloads/crds/alertmanagerconfigs.yaml \
  --manifest manifests/alerts/alertmanager-config.yaml
```

> **为什么必须做这一步**：CRD 是结构化 schema，清单里的未知字段**不报错、直接裁剪**。
> `kubectl apply` 返回成功、`kubectl get` 也看得到对象，但字段就是没生效——
> 这是本项目最贵的一类坑（已在 Traefik `service.type`、Loki `retention_period` 上各栽一次）。
> 本目录不入 Git，重新导出即可。

> **上游示例 CRD 与集群 CRD 的差异（实测）**：从上游生成的示例 CRD 里
> `AlertmanagerConfig` 只有 `v1alpha1` 一个版本，且 `headers` 字段是
> `type: array`（`{key, value}` 列表），与部分教程里写的 `map[string]string` 不同。
> 所以校验一定要用集群自己那份，版本差异会直接决定字段能不能用。

## secrets/ — 含凭据的文件（绝对不入库）

`downloads/secrets/` 存放**含明文凭据**的文件，是本机 → ECS 的中转站。命中的忽略规则：
`downloads/*`（本目录整体忽略）与 `dingtalk-config.yml`（按文件名忽略，双保险）。

| 文件 | 用途 |
|---|---|
| `dingtalk-config.yml` | 钉钉转发组件的配置（含 `access_token` 与加签 `secret`），scp 到 cp 后作为 Secret 的内容源 |

核对某个文件确实被忽略：

```bash
git check-ignore -v downloads/secrets/dingtalk-config.yml
# 期望输出形如：.gitignore:8:downloads/*	downloads/secrets/dingtalk-config.yml
```

核对仓库里没有漏进去的明文凭据（在仓库根目录执行，应无输出）：

```bash
git grep -n -I 'SEC3' HEAD -- .          # 加签密钥前缀
git grep -n -I 'access_token=' HEAD -- . # 钉钉 token
git grep -n -I 'password=' HEAD -- .     # 邮箱授权码
```

> 部署完成后这些文件**不必长期保留**：集群里的 Secret 才是运行时的真身。
> 建议演练验收通过后就地删除，需要时按 `docs/alerting.md` 重新从钉钉/QQ 后台取。

## 为什么 Calico 清单要改镜像地址

大陆 ECS 直连 `quay.io` 不通。原本的计划是「containerd 配 certs.d 镜像加速，YAML 不用动」，
但**实测证明 containerd 2.2.1 完全忽略了 certs.d 配置**，即使删掉 hosts.toml 的 `server` 字段
也依然直接请求源站。所以改成显式地址。

已实测确认这些镜像在镜像站都有缓存（走完整 token 流程，全部 200）：

```
quay.m.daocloud.io/tigera/operator:v1.34.0
quay.m.daocloud.io/calico/node:v3.28.0
quay.m.daocloud.io/calico/cni:v3.28.0
quay.m.daocloud.io/calico/kube-controllers:v3.28.0
quay.m.daocloud.io/calico/typha:v3.28.0
quay.m.daocloud.io/calico/csi:v3.28.0
quay.m.daocloud.io/calico/node-driver-registrar:v3.28.0
quay.m.daocloud.io/calico/pod2daemon-flexvol:v3.28.0
```

改动内容（两处）：

```bash
# tigera-operator.yaml：Operator 自身镜像
sed -i 's|image: quay.io/tigera/operator:|image: quay.m.daocloud.io/tigera/operator:|' tigera-operator.yaml

# calico-custom-resources.yaml：Installation 的 spec 下新增一行
#   spec:
#     registry: quay.m.daocloud.io
```

> `spec.registry` 是 Calico Operator 的官方配置项，设了之后 Operator 拉取的所有
> `calico/*` 组件镜像都会自动带上这个前缀，不需要逐个改。

## 关于 metrics-server 的 patch

自建 kubeadm 集群的 kubelet 使用**自签名证书**，metrics-server 默认会校验 kubelet 服务端证书，
校验失败后 `kubectl top nodes` 会一直报：

```
Error from server (ServiceUnavailable): the server is currently unable to handle the request
```

或在 metrics-server 日志里看到：

```
x509: cannot validate certificate for 172.16.0.11 because it doesn't contain any IP SANs
```

给启动参数加 `--kubelet-insecure-tls` 即可跳过该验证。

> **面试提醒**：这**不是**推荐的生产做法。生产环境应给 kubelet 签发由集群 CA 认可的证书
> （通过 kubelet 的 `--tls-cert-file` / `--tls-private-key-file` 指向集群 CA 签发的证书）。
> 实验室环境下用 `--kubelet-insecure-tls` 是公认的务实取舍，但**你必须在面试时说得出
> 为什么它是权宜之计**，否则会显得只是抄教程。

生成方式（可复现）：

```bash
sed 's|^        - --metric-resolution=15s$|        - --metric-resolution=15s\n        - --kubelet-insecure-tls|' \
  metrics-server-components.yaml > metrics-server-components-patched.yaml
```

## 重新获取（境外资源怎么下）

> ⚠️ **出网通道已变化（2026-09-13 实测）**：下面这套「清代理变量 + 显式走
> `127.0.0.1:7897`」的写法**当前不再适用**——本地代理 7897 已不可用（连接被拒），
> 而**直连反而正常**：`github.com` / `api.github.com` / `get.helm.sh` /
> `prometheus-community.github.io` 均返回 200。
>
> 所以现在的写法是**不带 `-x`**：
>
> ```bash
> curl -sSL -o tigera-operator.yaml \
>   https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
> ```
>
> 注意 `raw.githubusercontent.com` 仍不稳定（实测返回 000）；需要读上游文件时，
> 改用 GitHub API 的内容接口取（会返回 base64），例如：
>
> ```bash
> curl -s "https://api.github.com/repos/<org>/<repo>/contents/<path>" \
>   | python3 -c "import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)['content']).decode())"
> ```
>
> 另外 **GitHub 的 release 资产下载不通**（会 302 到 `objects.githubusercontent.com`，
> 本机 curl 返回 000）。需要二进制时走非 GitHub 的官方源（如 helm 用 `get.helm.sh`）。
>
> 以下是旧写法，**仅在 7897 恢复可用时**才是对的：

```bash
PX="http://127.0.0.1:7897"

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  curl -x "$PX" -sSL -o tigera-operator.yaml \
  https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  curl -x "$PX" -sSL -o calico-custom-resources.yaml \
  https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  curl -x "$PX" -sSL -o kubernetes-manifests.yaml \
  https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/v0.10.0/release/kubernetes-manifests.yaml

env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
  curl -x "$PX" -sSL -o metrics-server-components.yaml \
  https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
```

> 加 `env -u http_proxy ...` 是为了清掉沙箱自带的代理变量——它会拦截 GitHub 并返回 502。
> 详见 `docs/setup-cluster.md` 的网络说明。

## 上传到 ECS

```bash
scp downloads/*.yaml root@<k8s-cp公网IP>:~/
```

`kubernetes-manifests.yaml` 只在上传后按需做镜像地址替换，见
`manifests/boutique/README.md`。
