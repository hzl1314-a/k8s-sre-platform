# Online Boutique 部署清单

本目录存放 **已完成镜像地址替换** 的业务部署清单，任务 4（S2 阶段）产出。

## 计划产出的文件

| 文件 | 来源 | 改动内容 |
|---|---|---|
| `kubernetes-manifests.yaml` | [GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo) `release/kubernetes-manifests.yaml` | 镜像地址替换为 ACR；每个 Deployment 加 `replicas: 2` |
| `antiaffinity-patch.yaml` | 本仓库生成 | 为所有 Deployment 注入 Pod 反亲和，避免同服务副本落在同一节点 |

## 镜像策略（先读，避免走弯路）

大陆 ECS 拉 `gcr.io` 完全不通。本项目采用**双保险**：

**第一优先：containerd 镜像加速**（S1 阶段已配好，见 `docs/setup-cluster.md` 2.2④）

`/etc/containerd/certs.d/gcr.io/hosts.toml` 已把 gcr.io 指向 `gcr.m.daocloud.io`，
所以集群侧可以直接拉原始地址的镜像，**不需要改任何 YAML**：

```bash
kubectl create ns boutique
kubectl apply -n boutique -f kubernetes-manifests.yaml
```

**兜底方案：ACR 中转**（镜像站拉不动时启用）

```bash
# 本机（走代理）批量中转
bash scripts/mirror-push.sh

# 替换清单里的镜像地址
sed -i 's|gcr.io/google-samples/microservices-demo|registry.cn-shenzhen.aliyuncs.com/zhenlin|g' kubernetes-manifests.yaml
sed -i 's|redis:alpine|registry.cn-shenzhen.aliyuncs.com/zhenlin/redis:alpine|g' kubernetes-manifests.yaml
```

> ACR 地址必须与 ECS **同地域**，否则拉取走公网、慢且计费。
> 深圳 ECS → `registry.cn-shenzhen.aliyuncs.com`。

## 副本与反亲和（任务 4.4）

Online Boutique 默认每个服务 **1 副本**。直接跑起来的话，集群节点故障 = 服务中断，
后面 S6 的故障演练会直接失败。

所以必须：

1. 所有 Deployment `replicas: 2`
2. 加 `podAntiAffinity`（**优先**软反亲和，而不是硬反亲和）

```yaml
# 反亲和写法（每个 Deployment 各加一段）
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:   # preferred 而非 required
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: <服务名>
```

> **为什么用 `preferred` 而不是 `required`**：
> 只有 2 个 worker，`required` 的语义是"绝不允许两个副本在同一节点"。
> 一旦某个节点不可用，新 Pod 就永远调度不上去（因为 required 反亲和找不到合法节点），
> 可用副本数卡在 1，甚至 0——**反亲和把可用性保护变成了可用性杀手**。
>
> 这是很多人踩过的坑。`preferred` 在能分散时分散，实在不行就先跑起来，这才是务实的选择。
> 面试如果被问"反亲和为什么不用 required"，这就是标准答案。

## 资源 requests / limits

Online Boutique 自带 resource 声明，但偏保守。任务 4 需要检查：

- **`requests.cpu` 必须存在**，否则 HPA 无法计算 CPU 利用率（会显示 `<unknown>/60%`）
- 两个 worker 各 4C8G，11 个服务 × 2 副本 = 22 个 Pod
- Java 服务（`adservice`）默认 JVM 参数按宿主机内存算堆大小，**必须显式设 `-Xmx`**，
  否则它会按 8G 宿主机分配堆，很快 OOMKilled——这是本步骤最可能踩的坑

## 验收（任务 4.5）

```bash
kubectl get pods -n boutique                                  # 全部 Running
kubectl get pods -n boutique -o wide                          # NODE 列分散在两个 worker 上
kubectl get pods -n boutique -o wide | awk '{print $1, $7}'   # 逐服务确认副本分布
```
