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

## 重新获取（代理不可用时）

本机代理：`http://127.0.0.1:7897`

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
