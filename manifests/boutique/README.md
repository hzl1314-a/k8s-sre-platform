# Online Boutique 部署清单

本目录存放**已完成改造**的业务部署清单，S2 阶段（任务 4）产出。

## 文件

| 文件 | 说明 |
|---|---|
| `kubernetes-manifests.yaml` | 改造后的部署清单（35 个对象：12 Deployment + 12 Service + 11 ServiceAccount），**可直接 apply** |

> ⚠️ 这是**产物文件，不要手工编辑**。需要调整就改脚本然后重跑：
>
> ```bash
> python3 scripts/prepare-boutique-manifests.py \
>     --input  downloads/kubernetes-manifests.yaml \
>     --output manifests/boutique/kubernetes-manifests.yaml
> ```

## 做了三处改造（每处都有理由）

### 1. 镜像地址替换

| 原地址 | 新地址 |
|---|---|
| `gcr.io/google-samples/microservices-demo/*` | `gcr.m.daocloud.io/google-samples/microservices-demo/*` |
| `redis:alpine` | `docker.m.daocloud.io/library/redis:alpine` |

**为什么把地址写死在清单里**：大陆 ECS 直连 `gcr.io` 会 307 跳转到 Google `pkg.dev` 然后超时；
而且实测 **containerd 的 certs.d 镜像加速机制在本环境完全不生效**
（详见 `docs/setup-cluster.md` 3.2 节与踩坑记录第 3 条）。
既然镜像加速靠不住，就把地址固化进清单——行为可预测，不依赖运行时配置。

12 个镜像全部走过完整 token 流程验证，**在镜像站都有缓存（HTTP 200）**。

### 2. 副本数：10 个无状态服务设为 2

官方清单默认 1 副本。单副本意味着 **worker 节点故障 = 该服务彻底中断**，
S6 的故障演练会直接失败（Pod 无处可漂移）。

**但有两个故意保持 1 副本**：

| Deployment | 保持 1 的原因 |
|---|---|
| `redis-cart` | **有状态服务**。2 个副本会变成两个互不同步的独立实例（购物车数据不一致）。正确做法是 StatefulSet + 主从，超出本项目范围 |
| `loadgenerator` | **压测工具，不是业务负载**。它自己在产生流量，多副本会让压测基线翻倍，干扰 S5 的 HPA 测试 |

### 3. 注入 Pod 反亲和（preferred 软反亲和）

让同一服务的两个副本尽量落在不同节点：

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app: <服务名>
```

> ⚠️ **为什么用 `preferred` 而不是 `required`**（面试常被追问）
>
> 只有 2 个 worker，`required` 的语义是「绝不允许两个副本在同一节点」。
> 一旦某个节点不可用，新 Pod 会因为找不到满足 required 反亲和的节点而**永远 Pending**，
> 可用副本数卡在 1 甚至跌到 0——**反亲和从「可用性保护」变成了「可用性杀手」**。
>
> `preferred` 能分散时分散，实在不行先跑起来，这才是务实的选择。

## 资源占用（已核算）

| 指标 | 数值 | 说明 |
|---|---|---|
| 内存 requests 合计 | 约 2.2 Gi | 全部副本加总 |
| CPU requests 合计 | 约 3.2 Core | 两个 worker 共 8 Core，余量充足 |
| Pod 总数 | 22 | 10×2 + redis + loadgenerator |

`adservice` 是 Java 服务，limits 为 300Mi。现代 JVM 会自动感知容器内存限制
（`UseContainerSupport` 默认开启），堆大小约取 limit 的 1/4，**不会撑爆容器**。
若后续出现 OOMKilled，再显式加 `-Xmx` 参数（这本身也是个考点）。

## 部署

```bash
# 本机上传
scp manifests/boutique/kubernetes-manifests.yaml root@<cp公网IP>:~/

# cp 上部署
kubectl create ns boutique
kubectl apply -n boutique -f kubernetes-manifests.yaml
kubectl get pods -n boutique -w
```

## 验收（任务 4.5）

```bash
kubectl get pods -n boutique                 # 全部 Running
kubectl get pods -n boutique -o wide         # 看副本是否分散在两个 worker
```

把每个服务的两个副本的 NODE 列对比：**应尽量落在不同节点**
（软反亲和允许偶发同节点，只要不是全部挤在一个节点上即可）。
