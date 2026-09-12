#!/usr/bin/env python3
"""
prepare-boutique-manifests.py — 把 Online Boutique 官方清单改造成本项目可用的版本

用法：
    python3 scripts/prepare-boutique-manifests.py \
        --input  downloads/kubernetes-manifests.yaml \
        --output manifests/boutique/kubernetes-manifests.yaml

依赖：PyYAML（pip install pyyaml）

做三件事，每一件都有明确理由：

1. 镜像地址替换
   gcr.io/google-samples/microservices-demo/*  →  gcr.m.daocloud.io/google-samples/microservices-demo/*
   redis:alpine                                →  docker.m.daocloud.io/library/redis:alpine
   理由：大陆 ECS 直连 gcr.io 不通（会 307 跳到 Google pkg.dev 然后超时），
        且实测 containerd 的 certs.d 镜像加速机制在本环境不生效（见 docs/setup-cluster.md），
        所以必须把地址写死在清单里。

2. 无状态服务副本数 → 2
   官方清单默认 1 副本。单副本意味着：worker 节点故障 = 该服务彻底中断，
   后面 S6 的故障演练会直接失败（Pod 无处可漂移）。
   ⚠️ 但有两类**故意不设 2**：
      - redis-cart：有状态服务，2 个副本会变成两个互不同步的独立实例（购物车数据不一致）。
        正确做法是 StatefulSet + 主从，超出本项目范围，保持 1 副本。
      - loadgenerator：压测工具，不是业务负载。它自己在产生流量，
        多副本会让压测基线翻倍，干扰 S5 的 HPA 测试，保持 1 副本。

3. 注入 Pod 反亲和（preferred 软反亲和）
   让同一服务的两个副本尽量落在不同节点上。
   ⚠️ 为什么是 preferred 而不是 required：
     只有 2 个 worker，required 的语义是「绝不允许两个副本同节点」。
      一旦某节点不可用，新 Pod 因为找不到满足 required 反亲和的节点而永远 Pending，
      可用副本数卡在 1 甚至 0 —— 反亲和从「可用性保护」变成了「可用性杀手」。
      preferred 能分散时分散，实在不行先跑起来，这才是务实的选择。
      （面试被问「反亲和为什么不用 required」，这就是标准答案。）

改造后的清单是**产物**，不要手工编辑——改这个脚本然后重跑。
"""

import argparse
import sys

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：pip install pyyaml")

# 需要 2 副本 + 反亲和的服务（无状态业务服务）
STATELESS_SERVICES = {
    "adservice",
    "cartservice",
    "checkoutservice",
    "currencyservice",
    "emailservice",
    "frontend",
    "paymentservice",
    "productcatalogservice",
    "recommendationservice",
    "shippingservice",
}

# 保持 1 副本、不加反亲和的（见文件头说明）
SINGLE_REPLICA = {
    "redis-cart": "有状态服务，多副本会导致数据不一致",
    "loadgenerator": "压测工具，多副本会干扰压测基线",
}

IMAGE_REPLACEMENTS = [
    ("gcr.io/google-samples/microservices-demo/",
     "gcr.m.daocloud.io/google-samples/microservices-demo/"),
    ("redis:alpine",
     "docker.m.daocloud.io/library/redis:alpine"),
]


def fix_image(image):
    """按需替换镜像地址，返回 (新地址, 是否改动)。"""
    if not image:
        return image, False
    for old, new in IMAGE_REPLACEMENTS:
        if image == old or image.startswith(old):
            return image.replace(old, new, 1), True
    return image, False


def build_antiaffinity(app_label):
    """构造 preferred 软反亲和，让同 app 的副本尽量分散到不同节点。"""
    return {
        "podAntiAffinity": {
            "preferredDuringSchedulingIgnoredDuringExecution": [
                {
                    "weight": 100,
                    "podAffinityTerm": {
                        "topologyKey": "kubernetes.io/hostname",
                        "labelSelector": {"matchLabels": {"app": app_label}},
                    },
                }
            ]
        }
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    with open(args.input, encoding="utf-8") as f:
        docs = [d for d in yaml.safe_load_all(f) if d]

    img_changed = 0
    scaled = []
    skipped = []

    for doc in docs:
        if doc.get("kind") != "Deployment":
            continue

        name = doc["metadata"]["name"]
        spec = doc["spec"]
        pod_spec = spec["template"]["spec"]

        # --- 镜像替换（覆盖普通容器与 initContainer）---
        containers = list(pod_spec.get("containers") or []) + \
                     list(pod_spec.get("initContainers") or [])
        for c in containers:
            new_img, changed = fix_image(c.get("image"))
            if changed:
                c["image"] = new_img
                img_changed += 1

        # --- 副本数与反亲和 ---
        if name in STATELESS_SERVICES:
            spec["replicas"] = 2
            app_label = doc["spec"]["template"]["metadata"].get("labels", {}).get("app", name)
            pod_spec["affinity"] = build_antiaffinity(app_label)
            scaled.append(name)
        else:
            spec["replicas"] = 1
            skipped.append(f"{name}（{SINGLE_REPLICA.get(name, '非业务负载')}）")

    with open(args.output, "w", encoding="utf-8") as f:
        yaml.safe_dump_all(
            docs, f,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,      # 保持字段原顺序，避免 diff 面目全非
            width=1000,
        )

    print(f"输入 : {args.input}")
    print(f"输出 : {args.output}")
    print(f"文档数: {len(docs)}")
    print(f"镜像替换: {img_changed} 处")
    print(f"设为 2 副本 + 反亲和 ({len(scaled)}): {', '.join(sorted(scaled))}")
    print(f"保持 1 副本 ({len(skipped)}): {'; '.join(skipped)}")


if __name__ == "__main__":
    main()
