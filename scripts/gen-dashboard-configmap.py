"""把 Grafana 看板 JSON 包装成带 grafana_dashboard 标签的 ConfigMap。

为什么要有这个脚本（而不是手写 ConfigMap YAML）：
  ConfigMap 里嵌一大段 JSON 时，手写 YAML 的多行缩进极易出错，
  而且 JSON 一改就得手工重新缩进一遍。这里让 PyYAML 负责序列化，
  保证「JSON 是唯一事实来源，ConfigMap 是产物」。

用法:
  python scripts/gen-dashboard-configmap.py \
      --json  manifests/monitoring/boutique-overview-dashboard.json \
      --out   manifests/monitoring/boutique-overview-dashboard.yaml \
      --name  boutique-overview-dashboard \
      --key   boutique-overview-dashboard.json
"""
import argparse
import json
import os
import sys

import yaml

LABEL_KEY = "grafana_dashboard"
LABEL_VALUE = "1"


def _literal_str_representer(dumper, data):
    """让多行字符串用 `|` 块标量输出，保持 ConfigMap 可读。"""
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


yaml.add_representer(str, _literal_str_representer, Dumper=yaml.SafeDumper)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", required=True, help="看板 JSON 路径")
    ap.add_argument("--out", required=True, help="输出 ConfigMap YAML 路径")
    ap.add_argument("--name", default="boutique-overview-dashboard")
    ap.add_argument("--namespace", default="monitoring")
    ap.add_argument("--key", default=None, help="ConfigMap 里的文件名，默认取 JSON 的文件名")
    args = ap.parse_args()

    with open(args.json, encoding="utf-8") as f:
        raw = f.read()

    # 先做一次序列化/反序列化，既校验 JSON 合法性，也顺便统一格式
    dashboard = json.loads(raw)
    pretty = json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n"

    key = args.key or os.path.basename(args.json)
    cm = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": args.name,
            "namespace": args.namespace,
            "labels": {
                LABEL_KEY: LABEL_VALUE,
                "app.kubernetes.io/part-of": "k8s-sre-platform",
            },
            "annotations": {
                "note": (
                    "本文件由 scripts/gen-dashboard-configmap.py 生成，"
                    "请勿手工编辑；改 grafana 看板请改同名 .json 再重新生成"
                )
            },
        },
        "data": {key: pretty},
    }

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        yaml.safe_dump(cm, f, sort_keys=False, allow_unicode=True, width=10**6)

    panels = dashboard.get("panels", [])
    print("已生成 %s" % args.out)
    print("  看板标题 : %s" % dashboard.get("title"))
    print("  看板 uid : %s" % dashboard.get("uid"))
    print("  面板数量 : %d  (%s)" % (len(panels), ", ".join(p.get("type", "?") for p in panels)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
